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
          step.stub(:system, true) do
            step.run
          end

          refute_nil @ctx.registry_tag
          assert_includes @ctx.registry_tag, "localhost"
        end

        def test_logs_source_folder_path
          logger = TestLogger.new
          step = BuildImage.new(@ctx, logger:)
          step.stub(:system, true) do
            step.run
          end

          assert logger.logs.any? { |cat, msg| cat == "docker_build" && msg.include?("/tmp/my-app") }
        end

        def test_raises_when_no_source_folder
          @ctx.source_folder = nil

          step = BuildImage.new(@ctx, logger: TestLogger.new)
          assert_raises(RbrunCore::Error::Standard) { step.run }
        end
      end
    end
  end
end
