# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      class SetupK3s
        REGISTRY_PORT = 30_500
        CLUSTER_CIDR = "10.42.0.0/16"
        SERVICE_CIDR = "10.43.0.0/16"
        CLOUD_INIT_TIMEOUT = 120

        def initialize(ctx, logger: nil)
          @ctx = ctx
          @logger = logger
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
            log("wait_cloud_init", "Waiting for cloud-init")
            Waiter.poll(max_attempts: CLOUD_INIT_TIMEOUT, interval: 5, message: "Cloud-init did not complete") do
              result = ssh!("test -f /var/lib/cloud/instance/boot-finished && echo ready", raise_on_error: false)
              result[:output].include?("ready")
            end
          end

          def discover_network_info
            log("discover_network", "Discovering network info")
            public_ip = @ctx.server_ip

            # Find private IP (RFC1918), excluding virtual interfaces
            exec = ssh!("ip addr show | grep -v 'cni\\|flannel\\|veth' | grep -E 'inet (10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)' | awk '{print $2}' | cut -d/ -f1 | head -1", raise_on_error: false)
            private_ip = exec[:output].strip
            private_ip = public_ip if private_ip.empty?

            # Find interface for the IP
            exec = ssh!("ip addr show | grep 'inet #{private_ip}/' | awk '{print $NF}'", raise_on_error: false)
            interface = exec[:output].strip
            interface = "eth0" if interface.empty?

            { public_ip:, private_ip:, interface: }
          end

          def configure_k3s_registries!
            log("configure_k3s_registries", "Configuring K3s registries")
            registries_yaml = <<~YAML
            mirrors:
              "localhost:#{REGISTRY_PORT}":
                endpoint:
                  - "http://registry.default.svc.cluster.local:5000"
                  - "http://localhost:#{REGISTRY_PORT}"
          YAML
            ssh!("sudo mkdir -p /etc/rancher/k3s")
            encoded = Base64.strict_encode64(registries_yaml)
            ssh!("echo '#{encoded}' | base64 -d | sudo tee /etc/rancher/k3s/registries.yaml > /dev/null")
          end

          def install_k3s!(public_ip, private_ip, interface)
            check = ssh!("command -v kubectl && kubectl get nodes 2>/dev/null | grep -q Ready", raise_on_error: false)
            return if check[:exit_code].zero?

            log("install_k3s", "Installing K3s")
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

            ssh_with_retry!("curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC=\"#{k3s_args}\" sh -", timeout: 300)

            Waiter.poll(max_attempts: 30, interval: 5, message: "K3s did not become ready") do
              exec = ssh!("sudo kubectl get nodes", raise_on_error: false)
              exec[:exit_code].zero? && exec[:output].include?("Ready")
            end
          end

          def setup_kubeconfig!(private_ip)
            log("setup_kubeconfig", "Setting up kubeconfig")
            user = Naming.default_user
            ssh!(<<~BASH)
            mkdir -p /home/#{user}/.kube
            sudo cp /etc/rancher/k3s/k3s.yaml /home/#{user}/.kube/config
            sudo sed -i 's/127.0.0.1/#{private_ip}/g' /home/#{user}/.kube/config
            sudo chown -R #{user}:#{user} /home/#{user}/.kube
            chmod 600 /home/#{user}/.kube/config
          BASH
          end

          def deploy_ingress_controller!
            log("deploy_ingress", "Deploying ingress controller")
            kubeconfig = "/home/#{Naming.default_user}/.kube/config"
            ssh!("kubectl --kubeconfig=#{kubeconfig} apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/baremetal/deploy.yaml")

            Waiter.poll(max_attempts: 30, interval: 5, message: "Ingress controller did not become ready") do
              exec = ssh!(
                "kubectl --kubeconfig=#{kubeconfig} -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.phase}'", raise_on_error: false
              )
              exec[:output].include?("Running")
            end

            patch_json = '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080},{"op":"replace","path":"/spec/ports/1/nodePort","value":30443}]'
            ssh!(
              "kubectl --kubeconfig=#{kubeconfig} patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='#{patch_json}'", raise_on_error: false
            )
          end

          def label_all_nodes!
            return unless multi_server?

            kubeconfig = "/home/#{Naming.default_user}/.kube/config"

            @ctx.servers.each do |server_key, server_info|
              group = server_info[:group]
              node_name = "#{@ctx.prefix}-#{server_key}"
              log("label_node", "Labeling node #{node_name}")
              ssh!("kubectl --kubeconfig=#{kubeconfig} label node #{node_name} #{Naming::LABEL_SERVER_GROUP}=#{group} --overwrite",
                   raise_on_error: false)
            end
          end

          def setup_worker_nodes!(master_private_ip)
            log("cluster_token", "Retrieving cluster token")
            token_result = ssh!("sudo cat /var/lib/rancher/k3s/server/node-token")
            cluster_token = token_result[:output].strip

            kubeconfig = "/home/#{Naming.default_user}/.kube/config"

            # Skip the first server (master)
            worker_entries = @ctx.servers.to_a[1..]
            worker_entries.each do |server_key, server_info|
              node_name = "#{@ctx.prefix}-#{server_key}"

              unless @ctx.new_servers.include?(server_key) || !node_in_cluster?(node_name, kubeconfig:)
                log("skip_worker", "Skipping existing worker #{node_name}")
                next
              end

              worker_ip = server_info[:ip]
              log("setup_worker", "Setting up worker #{node_name}")

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
            end

            # Always re-label all nodes (applies label changes on redeploy)
            label_all_nodes!
          end

          def node_in_cluster?(node_name, kubeconfig:)
            result = ssh!("kubectl --kubeconfig=#{kubeconfig} get node #{node_name} 2>/dev/null", raise_on_error: false)
            result[:exit_code].zero? && result[:output].include?("Ready")
          end

          def wait_for_node_ready!(node_name, kubeconfig:, max_attempts: 30, interval: 5)
            Waiter.poll(max_attempts:, interval:, message: "Node #{node_name} not Ready after #{max_attempts * interval}s") do
              result = ssh!("kubectl --kubeconfig=#{kubeconfig} get node #{node_name} 2>/dev/null", raise_on_error: false)
              result[:output].include?("Ready")
            end
          end

          def ssh!(command, raise_on_error: true, timeout: 300)
            @ctx.ssh_client.execute(command, raise_on_error:, timeout:)
          end

          def ssh_with_retry!(command, raise_on_error: true, timeout: 300)
            @ctx.ssh_client.execute_with_retry(command, raise_on_error:, timeout:)
          end

          def log(category, message = nil)
            @logger&.log(category, message)
          end
      end
    end
  end
end
