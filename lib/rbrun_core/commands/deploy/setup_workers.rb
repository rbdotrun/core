# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      class SetupWorkers
        CLOUD_INIT_TIMEOUT = 120

        def initialize(ctx:, master_private_ip:, kubeconfig_path:, on_step: nil)
          @ctx = ctx
          @master_private_ip = master_private_ip
          @kubeconfig_path = kubeconfig_path
          @on_step = on_step
        end

        def run
          cluster_token = retrieve_cluster_token
          workers = find_workers_to_setup
          return if workers.empty?

          setup_workers(workers, cluster_token)
        end

        private

          def retrieve_cluster_token
            @on_step&.call("Token", :in_progress)
            cmd = [ "sudo", "cat", "/var/lib/rancher/k3s/server/node-token" ].join(" ")
            token_result = @ctx.ssh_client.execute(cmd)
            @on_step&.call("Token", :done)
            token_result[:output].strip
          end

          def find_workers_to_setup
            worker_entries = @ctx.servers.to_a[1..]
            worker_entries.select do |server_key, _server_info|
              node_name = "#{@ctx.prefix}-#{server_key}"
              @ctx.new_servers.include?(server_key) || !node_in_cluster?(node_name)
            end
          end

          def setup_workers(workers, cluster_token)
            @on_step&.call("Workers", :in_progress)
            workers.each { |server_key, server_info| setup_worker(server_key, server_info, cluster_token) }
            @on_step&.call("Workers", :done)
          end

          def setup_worker(server_key, server_info, cluster_token)
            node_name = "#{@ctx.prefix}-#{server_key}"
            worker_ssh = build_worker_ssh(server_info[:ip])

            @on_step&.call(:"worker_#{server_key}", :in_progress, parent: "Workers")

            wait_for_worker_cloud_init(worker_ssh)
            network_info = discover_worker_network(worker_ssh)
            join_cluster(worker_ssh, node_name, network_info, cluster_token)
            wait_for_node_ready(node_name)

            @on_step&.call(:"worker_#{server_key}", :done, parent: "Workers")
          end

          def build_worker_ssh(worker_ip)
            Clients::Ssh.new(
              host: worker_ip,
              private_key: @ctx.ssh_private_key,
              user: Naming.default_user
            )
          end

          def wait_for_worker_cloud_init(ssh)
            Waiter.poll(max_attempts: CLOUD_INIT_TIMEOUT, interval: 5, message: "Worker cloud-init did not complete") do
              cmd = [ "test", "-f", "/var/lib/cloud/instance/boot-finished", "&&", "echo", "ready" ].join(" ")
              result = ssh.execute(cmd, raise_on_error: false)
              result[:output].include?("ready")
            end
          end

          def discover_worker_network(ssh)
            private_ip = discover_private_ip(ssh)
            interface = discover_interface(ssh, private_ip)
            { private_ip:, interface: }
          end

          def discover_private_ip(ssh)
            cmd = [
              "ip", "-4", "addr", "show",
              "|", "grep", "-v", "'cni\\|flannel\\|veth'",
              "|", "grep", "-oP", "'(?<=inet\\s)10\\.\\d+\\.\\d+\\.\\d+|172\\.(1[6-9]|2[0-9]|3[01])\\.\\d+\\.\\d+|192\\.168\\.\\d+\\.\\d+'",
              "|", "head", "-1"
            ].join(" ")
            exec = ssh.execute(cmd)
            exec[:output].strip
          end

          def discover_interface(ssh, private_ip)
            cmd = [
              "ip", "-4", "addr", "show",
              "|", "grep", "'#{private_ip}'", "-B2",
              "|", "grep", "-oP", "'(?<=: )[^:@]+(?=:)'"
            ].join(" ")
            exec = ssh.execute(cmd)
            exec[:output].strip.split("\n").last || "eth0"
          end

          def join_cluster(ssh, node_name, network_info, cluster_token)
            agent_args = build_agent_args(node_name, network_info)
            cmd = "curl -sfL https://get.k3s.io | K3S_URL=\"https://#{@master_private_ip}:6443\" K3S_TOKEN=\"#{cluster_token}\" sh -s - agent #{agent_args}"
            ssh.execute_with_retry(cmd, timeout: 300)
          end

          def build_agent_args(node_name, network_info)
            [
              "--node-ip=#{network_info[:private_ip]}",
              "--flannel-iface=#{network_info[:interface]}",
              "--node-name=#{node_name}"
            ].join(" ")
          end

          def node_in_cluster?(node_name)
            cmd = [
              "kubectl", "--kubeconfig=#{@kubeconfig_path}",
              "get", "node", node_name, "2>/dev/null"
            ].join(" ")
            result = @ctx.ssh_client.execute(cmd, raise_on_error: false)
            result[:exit_code].zero? && result[:output].include?("Ready")
          end

          def wait_for_node_ready(node_name, max_attempts: 30, interval: 5)
            Waiter.poll(max_attempts:, interval:, message: "Node #{node_name} not Ready after #{max_attempts * interval}s") do
              cmd = [
                "kubectl", "--kubeconfig=#{@kubeconfig_path}",
                "get", "node", node_name, "2>/dev/null"
              ].join(" ")
              result = @ctx.ssh_client.execute(cmd, raise_on_error: false)
              result[:output].include?("Ready")
            end
          end
      end
    end
  end
end
