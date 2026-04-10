# frozen_string_literal: true

require "socket"

module RbrunCore
  module Commands
    class Deploy
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
            user: Naming.default_user
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
            # Local tunnel tag for build/push (dynamic port, use 127.0.0.1 to avoid IPv6)
            tunnel_tag = "127.0.0.1:#{@local_port}/#{prefix}:#{@timestamp}"
            # Cluster tag for manifests (fixed NodePort)
            cluster_tag = "localhost:#{REMOTE_REGISTRY_PORT}/#{prefix}:#{@timestamp}"

            dockerfile = @ctx.config.app_config.dockerfile
            platform = @ctx.config.app_config.platform

            # Build and push via buildx (handles insecure registry)
            build_args = [
              "buildx", "build",
              "--platform", platform,
              "-f", dockerfile,
              "-t", tunnel_tag,
              "--output=type=registry,registry.insecure=true"
            ]
            build_args.push("--cache-from", ENV["BUILDX_CACHE_FROM"]) if ENV["BUILDX_CACHE_FROM"]
            build_args.push("--cache-to", ENV["BUILDX_CACHE_TO"]) if ENV["BUILDX_CACHE_TO"]
            build_args.push(".")

            run_docker!(*build_args, chdir: context_path)

            # Return cluster_tag for manifests (uses fixed port 30500)
            { registry_tag: cluster_tag, timestamp: @timestamp }
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
