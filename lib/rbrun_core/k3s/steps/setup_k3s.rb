# frozen_string_literal: true

module RbrunCore
  module K3s
    module Steps
      class SetupK3s
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
            @on_step&.call("Cloud-init", :in_progress)
            Waiter.poll(max_attempts: CLOUD_INIT_TIMEOUT, interval: 5, message: "Cloud-init did not complete") do
              result = @ctx.ssh_client.execute(cloud_init_check_cmd, raise_on_error: false)
              result[:output].include?("ready")
            end
            @on_step&.call("Cloud-init", :done)
          end

          def cloud_init_check_cmd
            [ "test", "-f", "/var/lib/cloud/instance/boot-finished", "&&", "echo", "ready" ].join(" ")
          end

          def discover_network_info
            @on_step&.call("Network", :in_progress)
            public_ip = @ctx.server_ip
            private_ip = discover_private_ip || public_ip
            interface = discover_interface(private_ip)
            @on_step&.call("Network", :done)
            { public_ip:, private_ip:, interface: }
          end

          def discover_private_ip
            cmd = [
              "ip", "addr", "show",
              "|", "grep", "-v", "'cni\\|flannel\\|veth'",
              "|", "grep", "-E", "'inet (10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)'",
              "|", "awk", "'{print $2}'",
              "|", "cut", "-d/", "-f1",
              "|", "head", "-1"
            ].join(" ")
            exec = @ctx.ssh_client.execute(cmd, raise_on_error: false)
            ip = exec[:output].strip
            ip.empty? ? nil : ip
          end

          def discover_interface(private_ip)
            cmd = [
              "ip", "addr", "show",
              "|", "grep", "'inet #{private_ip}/'",
              "|", "awk", "'{print $NF}'"
            ].join(" ")
            exec = @ctx.ssh_client.execute(cmd, raise_on_error: false)
            interface = exec[:output].strip
            interface.empty? ? "eth0" : interface
          end

          def configure_k3s_registries!
            @on_step&.call("Registries", :in_progress)
            @ctx.ssh_client.execute([ "sudo", "mkdir", "-p", "/etc/rancher/k3s" ].join(" "))
            encoded = Base64.strict_encode64(registries_yaml)
            write_cmd = [ "echo", "'#{encoded}'", "|", "base64", "-d", "|", "sudo", "tee", "/etc/rancher/k3s/registries.yaml", ">", "/dev/null" ]
            @ctx.ssh_client.execute(write_cmd.join(" "))
            @on_step&.call("Registries", :done)
          end

          def registries_yaml
            <<~YAML
              mirrors:
                "localhost:#{REGISTRY_PORT}":
                  endpoint:
                    - "http://registry.default.svc.cluster.local:5000"
                    - "http://localhost:#{REGISTRY_PORT}"
            YAML
          end

          def install_k3s!(public_ip, private_ip, interface)
            return if k3s_already_installed?

            @on_step&.call("K3s", :in_progress)
            k3s_args = build_k3s_args(public_ip, private_ip, interface)
            install_cmd = "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC=\"#{k3s_args}\" sh -"

            @ctx.ssh_client.execute_with_retry(install_cmd, timeout: 300)
            wait_for_k3s_ready!
            @on_step&.call("K3s", :done)
          end

          def k3s_already_installed?
            cmd = [ "command", "-v", "kubectl", "&&", "kubectl", "get", "nodes", "2>/dev/null", "|", "grep", "-q", "Ready" ].join(" ")
            check = @ctx.ssh_client.execute(cmd, raise_on_error: false)
            check[:exit_code].zero?
          end

          def build_k3s_args(public_ip, private_ip, interface)
            [
              "--disable=traefik",
              "--flannel-backend=wireguard-native",
              "--flannel-iface=#{interface}",
              "--bind-address=#{private_ip}",
              "--advertise-address=#{private_ip}",
              "--node-ip=#{private_ip}",
              "--node-external-ip=#{public_ip}",
              "--tls-san=#{private_ip}",
              "--write-kubeconfig-mode=644",
              "--cluster-cidr=#{CLUSTER_CIDR}",
              "--service-cidr=#{SERVICE_CIDR}"
            ].join(" ")
          end

          def wait_for_k3s_ready!
            Waiter.poll(max_attempts: 30, interval: 5, message: "K3s did not become ready") do
              cmd = [ "sudo", "kubectl", "get", "nodes" ].join(" ")
              exec = @ctx.ssh_client.execute(cmd, raise_on_error: false)
              exec[:exit_code].zero? && exec[:output].include?("Ready")
            end
          end

          def setup_kubeconfig!(private_ip)
            @on_step&.call("Kubeconfig", :in_progress)
            user = RbrunCore::Naming.default_user
            @ctx.ssh_client.execute(<<~BASH)
            mkdir -p /home/#{user}/.kube
            sudo cp /etc/rancher/k3s/k3s.yaml /home/#{user}/.kube/config
            sudo sed -i 's/127.0.0.1/#{private_ip}/g' /home/#{user}/.kube/config
            sudo chown -R #{user}:#{user} /home/#{user}/.kube
            chmod 600 /home/#{user}/.kube/config
          BASH
            @on_step&.call("Kubeconfig", :done)
          end

          def deploy_ingress_controller!
            @on_step&.call("Ingress", :in_progress)
            apply_ingress_manifest!
            wait_for_ingress_ready!
            patch_ingress_nodeports!
            @on_step&.call("Ingress", :done)
          end

          def apply_ingress_manifest!
            cmd = [
              "kubectl", "--kubeconfig=#{kubeconfig_path}",
              "apply", "-f", ingress_manifest_url
            ].join(" ")
            @ctx.ssh_client.execute(cmd)
          end

          def ingress_manifest_url
            "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/baremetal/deploy.yaml"
          end

          def wait_for_ingress_ready!
            Waiter.poll(max_attempts: 30, interval: 5, message: "Ingress controller did not become ready") do
              cmd = [
                "kubectl", "--kubeconfig=#{kubeconfig_path}",
                "-n", "ingress-nginx",
                "get", "pods",
                "-l", "app.kubernetes.io/component=controller",
                "-o", "jsonpath='{.items[0].status.phase}'"
              ].join(" ")
              exec = @ctx.ssh_client.execute(cmd, raise_on_error: false)
              exec[:output].include?("Running")
            end
          end

          def patch_ingress_nodeports!
            patch_json = '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080},{"op":"replace","path":"/spec/ports/1/nodePort","value":30443}]'
            cmd = [
              "kubectl", "--kubeconfig=#{kubeconfig_path}",
              "patch", "svc", "ingress-nginx-controller",
              "-n", "ingress-nginx",
              "--type='json'",
              "-p='#{patch_json}'"
            ].join(" ")
            @ctx.ssh_client.execute(cmd, raise_on_error: false)
          end

          def kubeconfig_path
            "/home/#{RbrunCore::Naming.default_user}/.kube/config"
          end

          def label_all_nodes!
            return unless multi_server?

            @on_step&.call("Nodes", :in_progress)
            @ctx.servers.each { |server_key, server_info| label_node(server_key, server_info) }
            @on_step&.call("Nodes", :done)
          end

          def label_node(server_key, server_info)
            node_name = "#{@ctx.prefix}-#{server_key}"
            cmd = [
              "kubectl", "--kubeconfig=#{kubeconfig_path}",
              "label", "node", node_name,
              "#{Naming::LABEL_SERVER_GROUP}=#{server_info[:group]}",
              "--overwrite"
            ].join(" ")
            @ctx.ssh_client.execute(cmd, raise_on_error: false)
          end

          def setup_worker_nodes!(master_private_ip)
            SetupWorkers.new(
              ctx: @ctx,
              master_private_ip:,
              kubeconfig_path:,
              on_step: @on_step
            ).run

            label_all_nodes!
          end
      end
    end
  end
end
