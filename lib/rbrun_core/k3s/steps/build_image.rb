# frozen_string_literal: true

require "socket"

module RbrunCore
  module K3s
    module Steps
      # Builds Docker image locally and pushes to in-cluster registry via SSH tunnel.
      #
      # Uses local Docker with SSH port forwarding:
      # - Build executes locally using local CPU/RAM/cache
      # - SSH tunnel forwards localhost:<dynamic_port> to remote registry
      # - Only image layers transferred over network
      #
      # Requires source_folder to be set on context.
      # Requires local Docker to be running.
      class BuildImage
        REMOTE_REGISTRY_PORT = 30_500

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          raise Error::Standard, "source_folder is required for build" unless @ctx.source_folder

          @on_step&.call("Image", :in_progress)

          @timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
          @local_port = find_available_port

          ssh_client = Clients::Ssh.new(
            host: @ctx.server_ip,
            private_key: @ctx.config.compute_config.ssh_private_key,
            user: RbrunCore::Naming.default_user
          )

          ssh_client.with_local_forward(
            local_port: @local_port,
            remote_host: "localhost",
            remote_port: REMOTE_REGISTRY_PORT
          ) do
            result = build_and_push!(@ctx.source_folder)
            @ctx.registry_tag = result[:registry_tag]
          end

          @on_step&.call("Image", :done)
        end

        private

          def find_available_port
            server = TCPServer.new("127.0.0.1", 0)
            port = server.addr[1]
            server.close
            port
          end

          def build_and_push!(context_path)
            prefix = @ctx.prefix
            local_tag = "#{prefix}:#{@timestamp}"
            # Local tunnel tag for build/push (dynamic port)
            tunnel_tag = "localhost:#{@local_port}/#{prefix}:#{@timestamp}"
            # Cluster tag for manifests (fixed NodePort)
            cluster_tag = "localhost:#{REMOTE_REGISTRY_PORT}/#{prefix}:#{@timestamp}"

            dockerfile = @ctx.config.app_config.dockerfile
            platform = @ctx.config.app_config.platform

            run_docker!(
              "buildx", "build",
              "--platform", platform,
              "-f", dockerfile,
              "-t", tunnel_tag,
              "--output=type=registry,registry.insecure=true",
              ".",
              chdir: context_path
            )

            # Pull from registry and tag locally (faster than rebuilding)
            run_docker!("pull", "--platform", platform, tunnel_tag)
            run_docker!("tag", tunnel_tag, local_tag)
            run_docker!("tag", tunnel_tag, "#{prefix}:latest")

            # Return cluster_tag for manifests (uses fixed port 30500)
            { local_tag:, registry_tag: cluster_tag, timestamp: @timestamp }
          end

          def run_docker!(*args, chdir: nil)
            opts = chdir ? { chdir: } : {}
            success = system("docker", *args, **opts)
            raise Error::Standard, "docker #{args.first} failed" unless success
          end
      end
    end
  end
end
