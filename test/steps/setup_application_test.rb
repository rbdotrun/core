# frozen_string_literal: true

require "test_helper"
require "shellwords"

module RbrunCore
  module Steps
    class SetupApplicationTest < Minitest::Test
      def setup
        super
        @ctx = build_context(target: :sandbox, slug: "a1b2c3", branch: "main")
        @ctx.server_ip = "5.6.7.8"
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
      end

      def test_clones_repo_checks_out_branch_and_runs_compose
        cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
          SetupApplication.new(@ctx, on_log: ->(_, _) {}).run
        end

        assert cmds.any? { |cmd| cmd.include?("git clone") }
        assert cmds.any? { |cmd| cmd.include?("git checkout") }
        assert cmds.any? { |cmd| cmd.include?("docker compose") }
      end

      def test_runs_setup_commands_from_config
        @ctx.config.setup("bundle install", "rails db:prepare")

        cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
          SetupApplication.new(@ctx, on_log: ->(_, _) {}).run
        end
        assert cmds.any? { |cmd| cmd.include?(Shellwords.escape("bundle install")) }
        assert cmds.any? { |cmd| cmd.include?(Shellwords.escape("rails db:prepare")) }
      end

      def test_writes_env_file_from_config_env_vars
        @ctx.config.env(RAILS_ENV: "development", SECRET: "abc")

        cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
          SetupApplication.new(@ctx, on_log: ->(_, _) {}).run
        end
        assert cmds.any? { |cmd| cmd.include?(".env") }
      end

      def test_on_log_fires_for_each_sub_step
        logs = []
        with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
          SetupApplication.new(@ctx, on_log: ->(cat, _) { logs << cat }).run
        end
        assert_includes logs, "clone"
        assert_includes logs, "branch"
        assert_includes logs, "environment"
        assert_includes logs, "compose_generate"
        assert_includes logs, "compose_setup"
      end
    end
  end
end
