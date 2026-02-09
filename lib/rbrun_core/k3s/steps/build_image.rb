# frozen_string_literal: true

module RbrunCore
  module K3s
    module Steps
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
            user: RbrunCore::Naming.default_user
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

            run_docker!(
              "buildx", "build",
              "--platform", platform,
              "-f", dockerfile,
              "-t", registry_tag,
              "--output=type=registry,registry.insecure=true",
              ".",
              chdir: context_path
            )

            run_docker!("pull", "--platform", platform, registry_tag)
            run_docker!("tag", registry_tag, local_tag)
            run_docker!("tag", registry_tag, "#{prefix}:latest")

            { local_tag:, registry_tag:, timestamp: @timestamp }
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
