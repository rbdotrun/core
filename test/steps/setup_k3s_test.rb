# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Steps
    class SetupK3sTest < Minitest::Test
      def setup
        super
        @ctx = build_context(target: :production)
        @ctx.server_ip = "1.2.3.4"
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
      end

      def test_runs_k3s_install_commands_via_ssh
        cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
          SetupK3s.new(@ctx, on_log: ->(_, _) {}).run
        end
        assert cmds.any? { |cmd| cmd.include?("k3s") || cmd.include?("curl") }
      end

      def test_installs_docker_registry
        cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
          SetupK3s.new(@ctx, on_log: ->(_, _) {}).run
        end
        assert cmds.any? { |cmd| cmd.include?("registry") || cmd.include?("docker") }
      end

      def test_is_idempotent_checks_if_already_installed
        cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
          SetupK3s.new(@ctx, on_log: ->(_, _) {}).run
        end
        assert cmds.any? { |cmd| cmd.include?("command -v") || cmd.include?("test") }
      end
    end
  end
end
