# frozen_string_literal: true

require "open3"

module RbrunCore
  module Commands
    class Deploy
      # Builds Docker image locally and pushes to in-cluster registry.
      #
      # Uses DOCKER_HOST=ssh:// to target remote Docker daemon:
      # - Build context (local folder) is sent over SSH to remote daemon
      # - Build executes on remote, image stored on remote
      # - No local Docker daemon required
      #
      # Requires source_folder to be set on context.
      class BuildImage
        REGISTRY_PORT = 30_500

        def initialize(ctx, logger: nil)
          @ctx = ctx
          @logger = logger
        end

        def run
          raise Error::Standard, "source_folder is required for build" unless @ctx.source_folder

          ensure_host_key!

          log("docker_build", "Building from #{@ctx.source_folder}")
          result = build_and_push!(@ctx.source_folder)

          @ctx.registry_tag = result[:registry_tag]
        end

        private

          def build_and_push!(context_path)
            ts = Time.now.utc.strftime("%Y%m%d%H%M%S")
            prefix = @ctx.prefix
            local = "#{prefix}:#{ts}"
            registry = "localhost:#{REGISTRY_PORT}/#{prefix}:#{ts}"

            env = { "DOCKER_HOST" => docker_host }
            dockerfile = @ctx.config.app_config.dockerfile
            platform = @ctx.config.app_config.platform

            run_docker!(env, "build", "--platform", platform, "--pull", "-f", dockerfile, "-t", local, ".",
                        chdir: context_path)
            run_docker!(env, "tag", local, registry)
            run_docker!(env, "push", registry)
            run_docker!(env, "tag", local, "#{prefix}:latest")

            { local_tag: local, registry_tag: registry, timestamp: ts }
          end

          def run_docker!(env, *args, chdir: nil)
            opts = chdir ? { chdir: } : {}
            success = system(env, "docker", *args, **opts)
            raise Error::Standard, "docker #{args.first} failed" unless success
          end

          def ensure_host_key!
            # Net::SSH uses verify_host_key: :never, so the host key is never
            # written to known_hosts. Docker's SSH transport uses the system ssh
            # binary which requires it. Scan and append before docker commands.
            known_hosts = File.expand_path("~/.ssh/known_hosts")
            system("ssh-keyscan", "-H", @ctx.server_ip,
                   out: File.open(known_hosts, "a"), err: File::NULL)
          end

          def docker_host
            "ssh://#{Naming.default_user}@#{@ctx.server_ip}"
          end

          def log(category, message = nil)
            @logger&.log(category, message)
          end
      end
    end
  end
end
