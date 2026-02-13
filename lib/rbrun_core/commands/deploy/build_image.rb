# frozen_string_literal: true

require "socket"
require "fileutils"
require "tmpdir"

module RbrunCore
  module Commands
    class Deploy
      # Builds Docker image and pushes to in-cluster registry.
      #
      # Supports two modes:
      # 1. Local build (default): Build locally, push via SSH tunnel
      # 2. Remote build (with builder): Upload source to builder, build there, push via internal network
      #
      # Remote build is faster for slow upload connections as only source files
      # are uploaded (not built layers), and the builder has persistent cache.
      class BuildImage
        REMOTE_REGISTRY_PORT = 30_500
        BUILD_DIR = "/home/deploy/build"

        def initialize(ctx, on_step: nil, builder_context: nil)
          @ctx = ctx
          @on_step = on_step
          @builder_context = builder_context
        end

        def run
          raise Error::Standard, "source_folder is required for build" unless @ctx.source_folder

          @on_step&.call("Image", :in_progress)
          @timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")

          if @builder_context
            build_remote!
          else
            build_local!
          end

          @on_step&.call("Image", :done)
        end

        private

          # ── Local Build (original behavior) ──

          def build_local!
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
              result = build_and_push_local!(@ctx.source_folder)
              @ctx.registry_tag = result[:registry_tag]
            end
          end

          def find_available_port
            server = TCPServer.new("127.0.0.1", 0)
            port = server.addr[1]
            server.close
            port
          end

          def build_and_push_local!(context_path)
            prefix = @ctx.prefix
            local_tag = "#{prefix}:#{@timestamp}"
            tunnel_tag = "localhost:#{@local_port}/#{prefix}:#{@timestamp}"
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

            run_docker!("pull", "--platform", platform, tunnel_tag)
            run_docker!("tag", tunnel_tag, local_tag)
            run_docker!("tag", tunnel_tag, "#{prefix}:latest")

            { local_tag:, registry_tag: cluster_tag, timestamp: @timestamp }
          end

          def run_docker!(*args, chdir: nil)
            opts = chdir ? { chdir: } : {}
            success = system("docker", *args, **opts)
            raise Error::Standard, "docker #{args.first} failed" unless success
          end

          # ── Remote Build (on builder server) ──

          def build_remote!
            upload_source_to_builder!
            result = build_and_push_remote!
            @ctx.registry_tag = result[:registry_tag]
          end

          def upload_source_to_builder!
            builder_ssh = @builder_context.ssh_client
            source_path = @ctx.source_folder

            # Create build directory on builder
            builder_ssh.execute("rm -rf #{BUILD_DIR} && mkdir -p #{BUILD_DIR}")

            # Create a tarball of the source (respecting .dockerignore)
            Dir.mktmpdir do |tmpdir|
              tarball = File.join(tmpdir, "source.tar.gz")
              create_source_tarball(source_path, tarball)

              # Upload tarball to builder
              builder_ssh.upload(tarball, "/tmp/source.tar.gz")

              # Extract on builder
              builder_ssh.execute("tar -xzf /tmp/source.tar.gz -C #{BUILD_DIR} && rm /tmp/source.tar.gz")
            end
          end

          def create_source_tarball(source_path, tarball_path)
            # Use git archive if available (respects .gitignore)
            if File.exist?(File.join(source_path, ".git"))
              Dir.chdir(source_path) do
                system("git archive --format=tar.gz -o #{tarball_path} HEAD")
              end
            else
              # Fall back to tar, excluding common unwanted files
              excludes = %w[.git node_modules vendor/bundle tmp log coverage .bundle]
              exclude_args = excludes.map { |e| "--exclude=#{e}" }.join(" ")
              Dir.chdir(File.dirname(source_path)) do
                system("tar #{exclude_args} -czf #{tarball_path} #{File.basename(source_path)}")
              end
            end
          end

          def build_and_push_remote!
            builder_ssh = @builder_context.ssh_client
            prefix = @ctx.prefix

            # Registry is accessible at master's private IP:30500 from builder
            master_private_ip = @builder_context.master_private_ip
            registry_url = "#{master_private_ip}:#{REMOTE_REGISTRY_PORT}"

            # Cluster tag uses localhost (from K3s node perspective)
            cluster_tag = "localhost:#{REMOTE_REGISTRY_PORT}/#{prefix}:#{@timestamp}"

            dockerfile = @ctx.config.app_config.dockerfile
            platform = @ctx.config.app_config.platform

            # Build and push on the builder server
            builder_ssh.execute(<<~BASH, timeout: 600)
              cd #{BUILD_DIR} && \
              docker buildx build \
                --platform #{platform} \
                -f #{dockerfile} \
                -t #{registry_url}/#{prefix}:#{@timestamp} \
                --output=type=registry,registry.insecure=true \
                .
            BASH

            { registry_tag: cluster_tag, timestamp: @timestamp }
          end
      end
    end
  end
end
