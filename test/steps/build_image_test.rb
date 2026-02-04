# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Steps
    class BuildImageTest < Minitest::Test
      def setup
        super
        @ctx = build_context(target: :production, branch: "main")
        @ctx.server_ip = "1.2.3.4"
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        @ctx.config.app do |a|
          a.dockerfile = "Dockerfile"
          a.process(:web) { |p| p.port = 3000 }
        end
      end

      def test_sets_registry_tag_on_context_after_build
        step = BuildImage.new(@ctx, on_log: ->(_, _) {})
        # Stub system calls (git clone + docker build/tag/push)
        step.stub(:system, true) do
          step.run
        end
        refute_nil @ctx.registry_tag
        assert_includes @ctx.registry_tag, "localhost"
      end

      def test_on_log_fires_for_git_clone_and_docker_build
        logs = []
        step = BuildImage.new(@ctx, on_log: ->(cat, _) { logs << cat })
        step.stub(:system, true) do
          step.run
        end
        assert_includes logs, "git_clone"
        assert_includes logs, "docker_build"
      end
    end
  end
end
