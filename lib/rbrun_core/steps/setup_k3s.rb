# frozen_string_literal: true

module RbrunCore
  module Steps
    class SetupK3s
      REGISTRY_PORT = 30_500
      CLUSTER_CIDR = "10.42.0.0/16"
      SERVICE_CIDR = "10.43.0.0/16"
      CLOUD_INIT_TIMEOUT = 120
      REGISTRY_TIMEOUT = 60

      def initialize(ctx, on_log: nil)
        @ctx = ctx
        @on_log = on_log
      end

      def run
        wait_for_cloud_init!
        network = discover_network_info
        install_docker!
        configure_docker!(network[:private_ip])
        configure_k3s_registries!
        install_k3s!(network[:public_ip], network[:private_ip], network[:interface])
        setup_kubeconfig!(network[:private_ip])
        deploy_priority_classes!
        deploy_registry!
        wait_for_registry!
        deploy_ingress_controller!
      end

      private

        def wait_for_cloud_init!
          log("wait_cloud_init", "Waiting for cloud-init")
          CLOUD_INIT_TIMEOUT.times do
            result = ssh!("test -f /var/lib/cloud/instance/boot-finished && echo ready", raise_on_error: false)
            return if result[:output].include?("ready")

            sleep 5
          end
          raise RbrunCore::Error, "Cloud-init did not complete"
        end

        def discover_network_info
          log("discover_network", "Discovering network info")
          exec = ssh!("curl -s ifconfig.me || curl -s icanhazip.com")
          public_ip = exec[:output].strip

          exec = ssh!("ip -4 addr show | grep -oP '(?<=inet\\s)10\\.\\d+\\.\\d+\\.\\d+|172\\.(1[6-9]|2[0-9]|3[01])\\.\\d+\\.\\d+|192\\.168\\.\\d+\\.\\d+'")
          private_ip = exec[:output].strip.split("\n").first
          raise RbrunCore::Error, "Could not detect private IP" unless private_ip

          exec = ssh!("ip -4 addr show | grep '#{private_ip}' -B2 | grep -oP '(?<=: )[^:@]+(?=:)'")
          interface = exec[:output].strip.split("\n").last || "eth0"

          { public_ip:, private_ip:, interface: }
        end

        def install_docker!
          check = ssh!("command -v docker && systemctl is-active docker", raise_on_error: false)
          return if check[:exit_code].zero?

          log("install_docker", "Installing Docker")
          ssh!(<<~BASH)
          export DEBIAN_FRONTEND=noninteractive
          sudo apt-get update -qq
          sudo apt-get install -y -qq docker.io docker-compose
          sudo systemctl enable docker
          sudo systemctl start docker
          sudo usermod -aG docker #{Naming.default_user}
        BASH
        end

        def configure_docker!(private_ip)
          log("configure_docker", "Configuring Docker")
          daemon_json = {
            "insecure-registries" => [ "#{private_ip}:5001", "localhost:#{REGISTRY_PORT}" ]
          }.to_json

          ssh!("sudo mkdir -p /etc/docker")
          ssh!("sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'\n#{daemon_json}\nEOF")
          ssh!("sudo systemctl restart docker")
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
          ssh!("sudo tee /etc/rancher/k3s/registries.yaml > /dev/null << 'EOF'\n#{registries_yaml}\nEOF")
        end

        def install_k3s!(public_ip, private_ip, interface)
          check = ssh!("command -v kubectl && kubectl get nodes 2>/dev/null | grep -q Ready", raise_on_error: false)
          return if check[:exit_code].zero?

          log("install_k3s", "Installing K3s")
          k3s_args = [
            "--disable traefik", "--disable servicelb",
            "--flannel-backend=wireguard-native",
            "--flannel-iface=#{interface}",
            "--bind-address=#{private_ip}", "--advertise-address=#{private_ip}",
            "--node-ip=#{private_ip}", "--node-external-ip=#{public_ip}",
            "--write-kubeconfig-mode=644",
            "--cluster-cidr=#{CLUSTER_CIDR}", "--service-cidr=#{SERVICE_CIDR}"
          ].join(" ")

          ssh_with_retry!("curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC=\"#{k3s_args}\" sh -", timeout: 300)

          30.times do
            exec = ssh!("sudo kubectl get nodes", raise_on_error: false)
            break if exec[:exit_code].zero? && exec[:output].include?("Ready")

            sleep 5
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

        def deploy_priority_classes!
          log("deploy_priority_classes", "Deploying priority classes")
          apply_manifest!(Kubernetes::Resources.priority_class_yaml)
        end

        def deploy_registry!
          log("deploy_registry", "Deploying registry")
          apply_manifest!(registry_manifest)
        end

        def registry_manifest
          <<~YAML
          apiVersion: v1
          kind: PersistentVolumeClaim
          metadata:
            name: registry-pvc
            namespace: default
          spec:
            accessModes: [ReadWriteOnce]
            resources:
              requests:
                storage: 10Gi
          ---
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: registry
            namespace: default
          spec:
            replicas: 1
            selector:
              matchLabels:
                app: registry
            template:
              metadata:
                labels:
                  app: registry
              spec:
                containers:
                - name: registry
                  image: registry:2
                  ports:
                  - containerPort: 5000
                  volumeMounts:
                  - name: registry-data
                    mountPath: /var/lib/registry
                volumes:
                - name: registry-data
                  persistentVolumeClaim:
                    claimName: registry-pvc
          ---
          apiVersion: v1
          kind: Service
          metadata:
            name: registry
            namespace: default
          spec:
            type: NodePort
            selector:
              app: registry
            ports:
            - port: 5000
              targetPort: 5000
              nodePort: #{REGISTRY_PORT}
        YAML
        end

        def wait_for_registry!
          log("wait_registry", "Waiting for registry")
          REGISTRY_TIMEOUT.times do
            exec = ssh!("curl -sf http://localhost:#{REGISTRY_PORT}/v2/ && echo ok", raise_on_error: false)
            return if exec[:output].include?("ok")

            sleep 2
          end
          raise RbrunCore::Error, "Registry did not become ready"
        end

        def deploy_ingress_controller!
          log("deploy_ingress", "Deploying ingress controller")
          kubeconfig = "/home/#{Naming.default_user}/.kube/config"
          ssh!("kubectl --kubeconfig=#{kubeconfig} apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/baremetal/deploy.yaml")

          30.times do
            exec = ssh!(
              "kubectl --kubeconfig=#{kubeconfig} -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.phase}'", raise_on_error: false
            )
            break if exec[:output].include?("Running")

            sleep 5
          end

          patch_json = '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080},{"op":"replace","path":"/spec/ports/1/nodePort","value":30443}]'
          ssh!(
            "kubectl --kubeconfig=#{kubeconfig} patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='#{patch_json}'", raise_on_error: false
          )
        end

        def apply_manifest!(yaml)
          kubeconfig = "/home/#{Naming.default_user}/.kube/config"
          if yaml.start_with?("http")
            ssh!("kubectl --kubeconfig=#{kubeconfig} apply -f #{yaml}")
          else
            ssh!("kubectl --kubeconfig=#{kubeconfig} apply -f - << 'EOF'\n#{yaml}\nEOF")
          end
        end

        def ssh!(command, raise_on_error: true, timeout: 300)
          @ctx.ssh_client.execute(command, raise_on_error:, timeout:)
        end

        def ssh_with_retry!(command, raise_on_error: true, timeout: 300)
          @ctx.ssh_client.execute_with_retry(command, raise_on_error:, timeout:)
        end

        def log(category, message = nil)
          @on_log&.call(category, message)
        end
    end
  end
end
