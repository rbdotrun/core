# frozen_string_literal: true

require "open3"
require "tmpdir"

module RbrunCore
  module Commands
    class Deploy
      class BuildImage
        REGISTRY_PORT = 30_500

        def initialize(ctx, on_log: nil)
          @ctx = ctx
          @on_log = on_log
        end

        def run
          Dir.mktmpdir("rbrun-build-") do |tmpdir|
            log("git_clone", "Cloning repository")
            clone_to_tmpdir!(tmpdir)

            log("docker_build", "Building Docker image")
            ensure_host_key!
            result = build_and_push!(tmpdir)
            @ctx.registry_tag = result[:registry_tag]
          end
        end

        private

          def clone_to_tmpdir!(tmpdir)
            clone_url = "https://#{@ctx.config.git_config.pat}@github.com/#{@ctx.config.git_config.repo}.git"
            branch = @ctx.branch

            success = system("git", "clone", "--depth=1", "--branch", branch, clone_url, tmpdir, out: File::NULL, err: File::NULL)
            raise RbrunCore::Error, "git clone failed for branch #{branch}" unless success
          end

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
            raise RbrunCore::Error, "docker #{args.first} failed" unless success
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
            @on_log&.call(category, message)
          end
      end
    end
  end
end
