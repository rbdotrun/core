# frozen_string_literal: true

require "net/ssh/proxy/jump"

module RbrunCore
  module Commands
    class Deploy
      # Sets up an ephemeral build server with persistent cache.
      #
      # Architecture:
      # - Image (created once): Contains Docker + BuildKit installed
      # - Volume (persistent): Contains /var/lib/docker layer cache
      # - Server (ephemeral): Created from image, mounts volume, destroyed after build
      #
      # Security:
      # - Builder has NO public IP - only private IP
      # - Accessed via master node as jump host using Net::SSH::Proxy::Jump
      class SetupBuilder
        BuilderContext = Struct.new(:server, :volume, :ssh_client, :master_private_ip, keyword_init: true)

        DOCKER_DATA_DIR = "/var/lib/docker"
        BUILD_USER = Naming.default_user

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          return nil unless @ctx.config.builder?

          @on_step&.call("Builder", :in_progress)

          image = find_or_create_builder_image
          volume = find_or_create_builder_volume
          server = create_builder_server(image:, volume:)
          ssh_client = create_builder_ssh_client(server)

          wait_for_builder_ready!(ssh_client)
          mount_cache_volume!(ssh_client, volume)
          start_docker!(ssh_client)

          @on_step&.call("Builder", :done)

          BuilderContext.new(
            server:,
            volume:,
            ssh_client:,
            master_private_ip: discover_master_private_ip
          )
        end

        def cleanup(builder_context)
          return unless builder_context&.server

          @on_step&.call("Builder cleanup", :in_progress)

          # Stop Docker gracefully to flush cache
          builder_context.ssh_client.execute("sudo systemctl stop docker", raise_on_error: false)

          # Detach volume before destroying server
          @ctx.compute_client.detach_volume(volume_id: builder_context.volume.id)

          # Destroy ephemeral server (keep image + volume for next time)
          @ctx.compute_client.delete_server(builder_context.server.id)

          @on_step&.call("Builder cleanup", :done)
        rescue StandardError => e
          # Best effort cleanup - log but don't fail the deploy
          @on_step&.call("Builder cleanup", :done)
          warn "Builder cleanup warning: #{e.message}"
        end

        private

          def builder_config
            @ctx.config.builder_config
          end

          def prefix
            @ctx.prefix
          end

          def location
            @ctx.config.compute_config.location
          end

          def firewall
            @firewall ||= @ctx.compute_client.find_firewall(@ctx.prefix)
          end

          def network
            @network ||= @ctx.compute_client.find_network(@ctx.prefix)
          end

          # ── Image Management ──

          def find_or_create_builder_image
            image_name = Naming.builder_image(prefix)
            existing = @ctx.compute_client.find_image(image_name)
            return existing if existing

            create_builder_image(image_name)
          end

          def create_builder_image(image_name)
            # Create a temporary server to install Docker, then snapshot it
            temp_server = create_temp_server_for_image
            temp_ssh = create_builder_ssh_client(temp_server)

            wait_for_builder_ready!(temp_ssh)
            install_docker!(temp_ssh)

            # Create image from the prepared server
            image = @ctx.compute_client.create_image_from_server(
              server_id: temp_server.id,
              name: image_name,
              description: "Builder image with Docker for #{prefix}",
              labels: { Naming::LABEL_BUILDER => "true" }
            )

            # Clean up temp server
            @ctx.compute_client.delete_server(temp_server.id)

            image
          end

          def create_temp_server_for_image
            # Temp server needs public IP for initial setup
            @ctx.compute_client.find_or_create_server(
              name: "#{Naming.builder_server(prefix)}-temp",
              instance_type: builder_config.machine_type,
              location:,
              image: @ctx.config.compute_config.image || "ubuntu-22.04",
              user_data: cloud_init_script,
              labels: { Naming::LABEL_BUILDER => "true" },
              firewall_ids: [ firewall.id ],
              network_ids: [ network.id ],
              public_ip: true
            )
          end

          # ── Volume Management ──

          def find_or_create_builder_volume
            volume_name = Naming.builder_volume(prefix)
            @ctx.compute_client.find_or_create_volume(
              name: volume_name,
              size: builder_config.volume_size,
              location:,
              labels: { Naming::LABEL_BUILDER => "true" }
            )
          end

          # ── Server Management ──

          def create_builder_server(image:, volume:)
            server_name = Naming.builder_server(prefix)

            # Delete any existing builder server first
            existing = @ctx.compute_client.find_server(server_name)
            @ctx.compute_client.delete_server(existing.id) if existing

            # Create server from builder image (NO public IP)
            server = @ctx.compute_client.create_server(
              name: server_name,
              instance_type: builder_config.machine_type,
              location:,
              image: image.id,
              user_data: cloud_init_script,
              labels: { Naming::LABEL_BUILDER => "true" },
              firewall_ids: [ firewall.id ],
              network_ids: [ network.id ],
              public_ip: false
            )

            # Wait for server to be running
            server = @ctx.compute_client.wait_for_server(server.id)

            # Attach cache volume
            @ctx.compute_client.attach_volume(volume_id: volume.id, server_id: server.id)

            server
          end

          # ── SSH via Jump Host ──

          def create_builder_ssh_client(builder_server)
            # If server has public IP (temp server), connect directly
            # Otherwise (builder server), use master as jump host
            if builder_server.public_ipv4
              Clients::Ssh.new(
                host: builder_server.public_ipv4,
                private_key: @ctx.config.compute_config.ssh_private_key,
                user: BUILD_USER
              )
            else
              # Builder has only private IP - access via master as jump host
              private_ip = builder_server.private_ipv4
              raise Error::Standard, "Builder server has no private IP" unless private_ip

              jump_host = "#{BUILD_USER}@#{@ctx.server_ip}"
              proxy = Net::SSH::Proxy::Jump.new(jump_host, keys: [], key_data: [ @ctx.config.compute_config.ssh_private_key ])

              Clients::Ssh.new(
                host: private_ip,
                private_key: @ctx.config.compute_config.ssh_private_key,
                user: BUILD_USER,
                proxy:
              )
            end
          end

          def discover_master_private_ip
            # Get master's private IP for registry access
            cmd = "ip addr show | grep -v 'cni\\|flannel\\|veth' | grep -E 'inet (10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)' | awk '{print $2}' | cut -d/ -f1 | head -1"
            result = @ctx.ssh_client.execute(cmd, raise_on_error: false)
            ip = result[:output].strip
            ip.empty? ? @ctx.server_ip : ip
          end

          # ── Setup Commands ──

          def wait_for_builder_ready!(ssh_client)
            ssh_client.wait_until_ready(max_attempts: 60, interval: 5)

            # Wait for cloud-init to complete
            Waiter.poll(max_attempts: 60, interval: 5, message: "Builder cloud-init did not complete") do
              result = ssh_client.execute("test -f /var/lib/cloud/instance/boot-finished && echo ready", raise_on_error: false)
              result[:output].include?("ready")
            end
          end

          def install_docker!(ssh_client)
            ssh_client.execute(<<~BASH, timeout: 300)
              # Install Docker
              curl -fsSL https://get.docker.com | sh

              # Add user to docker group
              sudo usermod -aG docker #{BUILD_USER}

              # Configure Docker for BuildKit
              sudo mkdir -p /etc/docker
              echo '{"features":{"buildkit":true}}' | sudo tee /etc/docker/daemon.json

              # Enable and start Docker
              sudo systemctl enable docker
              sudo systemctl start docker

              # Install buildx
              mkdir -p ~/.docker/cli-plugins
              BUILDX_VERSION=$(curl -s https://api.github.com/repos/docker/buildx/releases/latest | grep tag_name | cut -d '"' -f 4)
              curl -Lo ~/.docker/cli-plugins/docker-buildx "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64"
              chmod +x ~/.docker/cli-plugins/docker-buildx

              # Create and use buildx builder
              docker buildx create --name builder --use || true
            BASH
          end

          def mount_cache_volume!(ssh_client, volume)
            device_path = @ctx.compute_client.wait_for_device_path(volume.id, ssh_client)

            ssh_client.execute(<<~BASH)
              # Stop Docker if running
              sudo systemctl stop docker 2>/dev/null || true

              # Check if volume needs formatting
              if ! sudo blkid #{device_path} | grep -q 'TYPE='; then
                sudo mkfs.xfs #{device_path}
              fi

              # Mount the volume
              sudo mkdir -p #{DOCKER_DATA_DIR}
              sudo mount #{device_path} #{DOCKER_DATA_DIR}

              # Ensure proper permissions
              sudo chown root:root #{DOCKER_DATA_DIR}
            BASH
          end

          def start_docker!(ssh_client)
            ssh_client.execute(<<~BASH)
              sudo systemctl start docker
              # Verify Docker is working
              docker info > /dev/null
            BASH
          end

          def cloud_init_script
            <<~CLOUD_INIT
              #cloud-config
              users:
                - name: #{BUILD_USER}
                  groups: sudo
                  shell: /bin/bash
                  sudo: ALL=(ALL) NOPASSWD:ALL
                  ssh_authorized_keys:
                    - #{@ctx.config.compute_config.ssh_public_key}
              package_update: true
              packages:
                - curl
                - git
            CLOUD_INIT
          end
      end
    end
  end
end
