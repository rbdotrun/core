# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    class Deploy
      class BuildImageTest < Minitest::Test
        def setup
          super
          @ctx = build_context(target: :production, branch: "main")
          @ctx.server_ip = "1.2.3.4"
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
          @ctx.source_folder = "/tmp/my-app"
          @ctx.config.app do |a|
            a.dockerfile = "Dockerfile"
            a.process(:web) { |p| p.port = 3000 }
          end
        end

        def test_sets_registry_tag_on_context_after_build
          step = BuildImage.new(@ctx, logger: TestLogger.new)

          with_fake_ssh_tunnel do
            step.stub(:system, true) do
              step.run
            end
          end

          refute_nil @ctx.registry_tag
          assert_includes @ctx.registry_tag, "localhost"
        end

        def test_logs_source_folder_path
          logger = TestLogger.new
          step = BuildImage.new(@ctx, logger:)

          with_fake_ssh_tunnel do
            step.stub(:system, true) do
              step.run
            end
          end

          assert logger.logs.any? { |cat, msg| cat == "docker_build" && msg.include?("/tmp/my-app") }
        end

        def test_raises_when_no_source_folder
          @ctx.source_folder = nil

          step = BuildImage.new(@ctx, logger: TestLogger.new)
          assert_raises(RbrunCore::Error::Standard) { step.run }
        end

        def test_creates_ssh_client_with_correct_params
          step = BuildImage.new(@ctx, logger: TestLogger.new)
          captured_args = nil

          fake_client = Object.new
          fake_client.define_singleton_method(:with_local_forward) { |**_opts, &block| block.call }

          Clients::Ssh.stub(:new, ->(host:, private_key:, user:) {
            captured_args = { host:, private_key:, user: }
            fake_client
          }) do
            step.stub(:system, true) do
              step.run
            end
          end

          assert_equal "1.2.3.4", captured_args[:host]
          assert_equal Naming.default_user, captured_args[:user]
          assert_equal TEST_SSH_KEY.private_key, captured_args[:private_key]
        end

        def test_uses_correct_tunnel_ports
          step = BuildImage.new(@ctx, logger: TestLogger.new)
          tunnel_opts = nil

          fake_client = Object.new
          fake_client.define_singleton_method(:with_local_forward) do |**opts, &block|
            tunnel_opts = opts
            block.call
          end

          Clients::Ssh.stub(:new, fake_client) do
            step.stub(:system, true) do
              step.run
            end
          end

          assert_equal 30_500, tunnel_opts[:local_port]
          assert_equal "localhost", tunnel_opts[:remote_host]
          assert_equal 30_500, tunnel_opts[:remote_port]
        end

        private

          def with_fake_ssh_tunnel(&block)
            fake_client = Object.new
            fake_client.define_singleton_method(:with_local_forward) { |**_opts, &blk| blk.call }

            Clients::Ssh.stub(:new, fake_client, &block)
          end
      end
    end
  end
end
