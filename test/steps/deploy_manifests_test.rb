# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Steps
    class DeployManifestsTest < Minitest::Test
      def setup
        super
        @ctx = build_context(target: :production)
        @ctx.server_ip = "1.2.3.4"
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        @ctx.registry_tag = "localhost:30500/app:v1"
      end

      def test_applies_generated_k3s_manifests_via_ssh_kubectl
        cmds = with_capturing_ssh do
          DeployManifests.new(@ctx, on_log: ->(_, _) {}).run
        end
        assert cmds.any? { |cmd| cmd.include?("kubectl") && cmd.include?("apply") }
      end

      def test_waits_for_rollout_of_configured_resources
        @ctx.config.database(:postgres)
        @ctx.config.app { |a| a.process(:web) { |p| p.port = 3000 } }

        cmds = with_capturing_ssh do
          DeployManifests.new(@ctx, on_log: ->(_, _) {}).run
        end
        assert cmds.any? { |cmd| cmd.include?("rollout status") }
      end
    end
  end
end
