# frozen_string_literal: true

require "open3"

module RbrunCore
  module Commands
    class Deploy
      # Builds Docker image locally and pushes to in-cluster registry via SSH tunnel.
      #
      # Uses local Docker with SSH port forwarding:
      # - Build executes locally using local CPU/RAM/cache
      # - SSH tunnel forwards localhost:30500 to remote registry
      # - Only image layers transferred over network
      #
      # Requires source_folder to be set on context.
      # Requires local Docker to be running.
      class BuildImage
        REGISTRY_PORT = 30_500

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          raise Error::Standard, "source_folder is required for build" unless @ctx.source_folder

          @on_step&.call("Image", :in_progress)

          @timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")

          ssh_client = Clients::Ssh.new(
            host: @ctx.server_ip,
            private_key: @ctx.config.compute_config.ssh_private_key,
            user: Naming.default_user
          )

          ssh_client.with_local_forward(
            local_port: REGISTRY_PORT,
            remote_host: "localhost",
            remote_port: REGISTRY_PORT
          ) do
            result = build_and_push!(@ctx.source_folder)
            @ctx.registry_tag = result[:registry_tag]
          end

          @on_step&.call("Image", :done)
        end

        private

          def build_and_push!(context_path)
            prefix = @ctx.prefix
            local_tag = "#{prefix}:#{@timestamp}"
            registry_tag = "localhost:#{REGISTRY_PORT}/#{prefix}:#{@timestamp}"

            dockerfile = @ctx.config.app_config.dockerfile
            platform = @ctx.config.app_config.platform

            # Build and push via buildx (handles insecure registry)
            run_docker!(
              "buildx", "build",
              "--platform", platform,
              "--pull",
              "-f", dockerfile,
              "-t", registry_tag,
              "--output=type=registry,registry.insecure=true",
              ".",
              chdir: context_path
            )

            # Pull from registry and tag locally (faster than rebuilding)
            run_docker!("pull", "--platform", platform, registry_tag)
            run_docker!("tag", registry_tag, local_tag)
            run_docker!("tag", registry_tag, "#{prefix}:latest")

            { local_tag:, registry_tag:, timestamp: @timestamp }
          end

          def run_docker!(*args, chdir: nil)
            success = execute_docker(*args, chdir: chdir) { |line| emit_docker_line(line) }
            raise Error::Standard, "docker #{args.first} failed" unless success
          end

          def execute_docker(*args, chdir: nil)
            opts = chdir ? { chdir: } : {}

            Open3.popen2e("docker", *args, **opts) do |_stdin, stdout_err, wait_thr|
              stdout_err.each_line { |line| yield line if block_given? }
              wait_thr.value.success?
            end
          end

          def emit_docker_line(line)
            $stdout.print "    #{line}"
          end
      end
    end
  end
end
