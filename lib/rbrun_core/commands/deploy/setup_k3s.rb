# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      class SetupK3s
        include Stepable

        REGISTRY_PORT = 30_500
        CLUSTER_CIDR = "10.42.0.0/16"
        SERVICE_CIDR = "10.43.0.0/16"
        CLOUD_INIT_TIMEOUT = 120

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          wait_for_cloud_init!
          network = discover_network_info
          configure_k3s_registries!
          install_k3s!(network[:public_ip], network[:private_ip], network[:interface])
          setup_kubeconfig!(network[:private_ip])
          deploy_ingress_controller!
          setup_worker_nodes!(network[:private_ip]) if multi_server?
        end

        private

          def multi_server?
            @ctx.servers.any?
          end

          def wait_for_cloud_init!
            report_step(Step::Id::WAIT_CLOUD_INIT, Step::IN_PROGRESS)
            Waiter.poll(max_attempts: CLOUD_INIT_TIMEOUT, interval: 5, message: "Cloud-init did not complete") do
              result = @ctx.ssh_client.execute("test -f /var/lib/cloud/instance/boot-finished && echo ready", raise_on_error: false)
              result[:output].include?("ready")
            end
            report_step(Step::Id::WAIT_CLOUD_INIT, Step::DONE)
          end

          def discover_network_info
            report_step(Step::Id::DISCOVER_NETWORK, Step::IN_PROGRESS)
            public_ip = @ctx.server_ip

            # Find private IP (RFC1918), excluding virtual interfaces
            exec = @ctx.ssh_client.execute("ip addr show | grep -v 'cni\\|flannel\\|veth' | grep -E 'inet (10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)' | awk '{print $2}' | cut -d/ -f1 | head -1", raise_on_error: false)
            private_ip = exec[:output].strip
            private_ip = public_ip if private_ip.empty?

            # Find interface for the IP
            exec = @ctx.ssh_client.execute("ip addr show | grep 'inet #{private_ip}/' | awk '{print $NF}'", raise_on_error: false)
            interface = exec[:output].strip
            interface = "eth0" if interface.empty?

            report_step(Step::Id::DISCOVER_NETWORK, Step::DONE)
            { public_ip:, private_ip:, interface: }
          end

          def configure_k3s_registries!
            report_step(Step::Id::CONFIGURE_REGISTRIES, Step::IN_PROGRESS)
            registries_yaml = <<~YAML
            mirrors:
              "localhost:#{REGISTRY_PORT}":
                endpoint:
                  - "http://registry.default.svc.cluster.local:5000"
                  - "http://localhost:#{REGISTRY_PORT}"
          YAML
            @ctx.ssh_client.execute("sudo mkdir -p /etc/rancher/k3s")
            encoded = Base64.strict_encode64(registries_yaml)
            @ctx.ssh_client.execute("echo '#{encoded}' | base64 -d | sudo tee /etc/rancher/k3s/registries.yaml > /dev/null")
            report_step(Step::Id::CONFIGURE_REGISTRIES, Step::DONE)
          end

          def install_k3s!(public_ip, private_ip, interface)
            check = @ctx.ssh_client.execute("command -v kubectl && kubectl get nodes 2>/dev/null | grep -q Ready", raise_on_error: false)
            return if check[:exit_code].zero?

            report_step(Step::Id::INSTALL_K3S, Step::IN_PROGRESS)
            k3s_args = [
              "--disable=traefik",
              "--flannel-backend=wireguard-native",
              "--flannel-iface=#{interface}",
              "--bind-address=#{private_ip}", "--advertise-address=#{private_ip}",
              "--node-ip=#{private_ip}", "--node-external-ip=#{public_ip}",
              "--tls-san=#{private_ip}",
              "--write-kubeconfig-mode=644",
              "--cluster-cidr=#{CLUSTER_CIDR}", "--service-cidr=#{SERVICE_CIDR}"
            ].join(" ")

            @ctx.ssh_client.execute_with_retry("curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC=\"#{k3s_args}\" sh -", timeout: 300)

            Waiter.poll(max_attempts: 30, interval: 5, message: "K3s did not become ready") do
              exec = @ctx.ssh_client.execute("sudo kubectl get nodes", raise_on_error: false)
              exec[:exit_code].zero? && exec[:output].include?("Ready")
            end
            report_step(Step::Id::INSTALL_K3S, Step::DONE)
          end

          def setup_kubeconfig!(private_ip)
            report_step(Step::Id::SETUP_KUBECONFIG, Step::IN_PROGRESS)
            user = Naming.default_user
            @ctx.ssh_client.execute(<<~BASH)
            mkdir -p /home/#{user}/.kube
            sudo cp /etc/rancher/k3s/k3s.yaml /home/#{user}/.kube/config
            sudo sed -i 's/127.0.0.1/#{private_ip}/g' /home/#{user}/.kube/config
            sudo chown -R #{user}:#{user} /home/#{user}/.kube
            chmod 600 /home/#{user}/.kube/config
          BASH
            report_step(Step::Id::SETUP_KUBECONFIG, Step::DONE)
          end

          def deploy_ingress_controller!
            report_step(Step::Id::DEPLOY_INGRESS, Step::IN_PROGRESS)
            kubeconfig = "/home/#{Naming.default_user}/.kube/config"
            @ctx.ssh_client.execute("kubectl --kubeconfig=#{kubeconfig} apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/baremetal/deploy.yaml")

            Waiter.poll(max_attempts: 30, interval: 5, message: "Ingress controller did not become ready") do
              exec = @ctx.ssh_client.execute(
                "kubectl --kubeconfig=#{kubeconfig} -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.phase}'", raise_on_error: false
              )
              exec[:output].include?("Running")
            end

            patch_json = '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080},{"op":"replace","path":"/spec/ports/1/nodePort","value":30443}]'
            @ctx.ssh_client.execute(
              "kubectl --kubeconfig=#{kubeconfig} patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='#{patch_json}'", raise_on_error: false
            )
            report_step(Step::Id::DEPLOY_INGRESS, Step::DONE)
          end

          def label_all_nodes!
            return unless multi_server?

            report_step(Step::Id::LABEL_NODES, Step::IN_PROGRESS)
            kubeconfig = "/home/#{Naming.default_user}/.kube/config"

            @ctx.servers.each do |server_key, server_info|
              group = server_info[:group]
              node_name = "#{@ctx.prefix}-#{server_key}"
              @ctx.ssh_client.execute("kubectl --kubeconfig=#{kubeconfig} label node #{node_name} #{Naming::LABEL_SERVER_GROUP}=#{group} --overwrite",
                   raise_on_error: false)
            end
            report_step(Step::Id::LABEL_NODES, Step::DONE)
          end

          def setup_worker_nodes!(master_private_ip)
            report_step(Step::Id::RETRIEVE_TOKEN, Step::IN_PROGRESS)
            token_result = @ctx.ssh_client.execute("sudo cat /var/lib/rancher/k3s/server/node-token")
            cluster_token = token_result[:output].strip
            report_step(Step::Id::RETRIEVE_TOKEN, Step::DONE)

            kubeconfig = "/home/#{Naming.default_user}/.kube/config"

            # Skip the first server (master)
            worker_entries = @ctx.servers.to_a[1..]
            workers_to_setup = worker_entries.select do |server_key, _server_info|
              node_name = "#{@ctx.prefix}-#{server_key}"
              @ctx.new_servers.include?(server_key) || !node_in_cluster?(node_name, kubeconfig:)
            end

            if workers_to_setup.any?
              report_step(Step::Id::SETUP_WORKERS, Step::IN_PROGRESS)
              workers_to_setup.each do |server_key, server_info|
                node_name = "#{@ctx.prefix}-#{server_key}"
                worker_ip = server_info[:ip]

                report_step(:"worker_#{server_key}", Step::IN_PROGRESS, parent: Step::Id::SETUP_WORKERS)

                worker_ssh = Clients::Ssh.new(
                  host: worker_ip, private_key: @ctx.ssh_private_key, user: Naming.default_user
                )

                # Wait for cloud-init
                Waiter.poll(max_attempts: CLOUD_INIT_TIMEOUT, interval: 5, message: "Worker cloud-init did not complete") do
                  result = worker_ssh.execute("test -f /var/lib/cloud/instance/boot-finished && echo ready",
                                              raise_on_error: false)
                  result[:output].include?("ready")
                end

                # Discover worker private IP (exclude virtual interfaces)
                exec = worker_ssh.execute("ip -4 addr show | grep -v 'cni\\|flannel\\|veth' | grep -oP '(?<=inet\\s)10\\.\\d+\\.\\d+\\.\\d+|172\\.(1[6-9]|2[0-9]|3[01])\\.\\d+\\.\\d+|192\\.168\\.\\d+\\.\\d+' | head -1")
                worker_private_ip = exec[:output].strip

                exec = worker_ssh.execute("ip -4 addr show | grep '#{worker_private_ip}' -B2 | grep -oP '(?<=: )[^:@]+(?=:)'")
                worker_iface = exec[:output].strip.split("\n").last || "eth0"

                # Join K3s cluster as agent
                worker_ssh.execute_with_retry(
                  "curl -sfL https://get.k3s.io | K3S_URL=\"https://#{master_private_ip}:6443\" " \
                  "K3S_TOKEN=\"#{cluster_token}\" sh -s - agent " \
                  "--node-ip=#{worker_private_ip} " \
                  "--flannel-iface=#{worker_iface} " \
                  "--node-name=#{node_name}",
                  timeout: 300
                )

                wait_for_node_ready!(node_name, kubeconfig:)
                report_step(:"worker_#{server_key}", Step::DONE, parent: Step::Id::SETUP_WORKERS)
              end
              report_step(Step::Id::SETUP_WORKERS, Step::DONE)
            end

            # Always re-label all nodes (applies label changes on redeploy)
            label_all_nodes!
          end

          def node_in_cluster?(node_name, kubeconfig:)
            result = @ctx.ssh_client.execute("kubectl --kubeconfig=#{kubeconfig} get node #{node_name} 2>/dev/null", raise_on_error: false)
            result[:exit_code].zero? && result[:output].include?("Ready")
          end

          def wait_for_node_ready!(node_name, kubeconfig:, max_attempts: 30, interval: 5)
            Waiter.poll(max_attempts:, interval:, message: "Node #{node_name} not Ready after #{max_attempts * interval}s") do
              result = @ctx.ssh_client.execute("kubectl --kubeconfig=#{kubeconfig} get node #{node_name} 2>/dev/null", raise_on_error: false)
              result[:output].include?("Ready")
            end
          end
      end
    end
  end
end
