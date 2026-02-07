# frozen_string_literal: true

require "test_helper"
require "shellwords"

module RbrunCore
  module Commands
    class DeploySandbox
      class SetupApplicationTest < Minitest::Test
        def setup
          super
          @ctx = build_context(target: :sandbox, slug: "a1b2c3", branch: "main")
          @ctx.server_ip = "5.6.7.8"
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        end

        def test_clones_repo_checks_out_branch_and_runs_compose
          cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
            SetupApplication.new(@ctx, logger: TestLogger.new).run
          end

          assert(cmds.any? { |cmd| cmd.include?("git clone") })
          assert(cmds.any? { |cmd| cmd.include?("git checkout") })
          assert(cmds.any? { |cmd| cmd.include?("docker compose") })
        end

        def test_runs_setup_commands_from_process
          @ctx.config.app do |a|
            a.process(:web) do |p|
              p.setup = [ "bundle install", "rails db:prepare" ]
            end
          end

          cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
            SetupApplication.new(@ctx, logger: TestLogger.new).run
          end

          assert(cmds.any? { |cmd| cmd.include?(Shellwords.escape("bundle install")) })
          assert(cmds.any? { |cmd| cmd.include?(Shellwords.escape("rails db:prepare")) })
        end

        def test_writes_env_file_from_config_env_vars
          @ctx.config.env(RAILS_ENV: "development", SECRET: "abc")

          cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
            SetupApplication.new(@ctx, logger: TestLogger.new).run
          end

          assert(cmds.any? { |cmd| cmd.include?(".env") })
        end

        def test_on_log_fires_for_git_steps
          logs = collect_log_categories

          assert_includes logs, "clone"
          assert_includes logs, "branch"
          assert_includes logs, "environment"
        end

        def test_on_log_fires_for_compose_steps
          logs = collect_log_categories

          assert_includes logs, "compose_generate"
          assert_includes logs, "compose_setup"
        end

        def test_installs_node_when_not_present
          cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1, "command -v node" => 1, "command -v claude" => 1,
                                                     "command -v gh" => 1, "command -v docker" => 1 }) do
            SetupApplication.new(@ctx, logger: TestLogger.new).run
          end

          assert(cmds.any? { |cmd| cmd.include?("nodesource") || cmd.include?("setup_20.x") })
        end

        def test_installs_claude_code_when_not_present
          cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1, "command -v node" => 1, "command -v claude" => 1,
                                                     "command -v gh" => 1, "command -v docker" => 1 }) do
            SetupApplication.new(@ctx, logger: TestLogger.new).run
          end

          assert(cmds.any? { |cmd| cmd.include?("@anthropic-ai/claude-code") })
        end

        def test_installs_gh_cli_when_not_present
          cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1, "command -v node" => 1, "command -v claude" => 1,
                                                     "command -v gh\n" => 1, "command -v gh" => 1, "command -v docker" => 1 }) do
            SetupApplication.new(@ctx, logger: TestLogger.new).run
          end

          assert(cmds.any? { |cmd| cmd.include?("githubcli-archive-keyring") })
        end

        def test_gh_auth_login_runs_when_pat_present
          cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1, "command -v node" => 1, "command -v claude" => 1,
                                                     "command -v gh" => 1, "command -v docker" => 1 }) do
            SetupApplication.new(@ctx, logger: TestLogger.new).run
          end

          assert(cmds.any? { |cmd| cmd.include?("gh auth login --with-token") })
        end

        def test_skips_install_when_commands_exist
          cmds = with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
            SetupApplication.new(@ctx, logger: TestLogger.new).run
          end

          refute(cmds.any? { |cmd| cmd.include?("nodesource") || cmd.include?("setup_20.x") })
          refute(cmds.any? { |cmd| cmd.include?("@anthropic-ai/claude-code") })
          refute(cmds.any? { |cmd| cmd.include?("githubcli-archive-keyring") })
        end
        private

          def collect_log_categories
            logger = TestLogger.new
            with_capturing_ssh(exit_code_for: { "test -d" => 1 }) do
              SetupApplication.new(@ctx, logger:).run
            end
            logger.categories
          end
      end
    end
  end
end
