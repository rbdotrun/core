# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    class Deploy
      class SetupK3sTest < Minitest::Test
        def setup
          super
          @ctx = build_context(target: :production)
          @ctx.server_ip = "1.2.3.4"
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        end

        # ── Single-server mode ──

        def test_runs_k3s_install_commands_via_ssh
          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
            SetupK3s.new(@ctx, on_log: ->(_, _) { }).run
          end

          assert(cmds.any? { |cmd| cmd.include?("k3s") || cmd.include?("curl") })
        end

        def test_installs_docker_registry
          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
            SetupK3s.new(@ctx, on_log: ->(_, _) { }).run
          end

          assert(cmds.any? { |cmd| cmd.include?("registry") || cmd.include?("docker") })
        end

        def test_is_idempotent_checks_if_already_installed
          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
            SetupK3s.new(@ctx, on_log: ->(_, _) { }).run
          end

          assert(cmds.any? { |cmd| cmd.include?("command -v") || cmd.include?("test") })
        end

        def test_single_server_does_not_label_or_join_workers
          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
            SetupK3s.new(@ctx, on_log: ->(_, _) { }).run
          end

          refute(cmds.any? { |cmd| cmd.include?("rbrun.dev/server-group") })
          refute(cmds.any? { |cmd| cmd.include?("node-token") })
        end

        # ── Multi-server mode ──

        def test_multi_server_labels_all_nodes
          setup_multi_server_ctx!
          @ctx.new_servers = Set["worker-1"]

          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady\nTrue\ntoken123") do
            SetupK3s.new(@ctx, on_log: ->(_, _) { }).run
          end

          label_cmds = cmds.select { |cmd| cmd.include?("rbrun.dev/server-group") }

          assert_operator(label_cmds.length, :>=, 2, "Expected label commands for all nodes (master + worker)")
        end

        def test_multi_server_retrieves_cluster_token
          setup_multi_server_ctx!
          @ctx.new_servers = Set["worker-1"]

          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady\nTrue\ntoken123") do
            SetupK3s.new(@ctx, on_log: ->(_, _) { }).run
          end

          assert(cmds.any? { |cmd| cmd.include?("node-token") })
        end

        def test_multi_server_logs_worker_setup
          setup_multi_server_ctx!
          # Mark all as new so they get joined
          @ctx.new_servers = Set["web-1", "worker-1"]
          logs = []

          with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady\nTrue\ntoken123") do
            SetupK3s.new(@ctx, on_log: ->(cat, msg) { logs << [ cat, msg ] }).run
          end

          assert(logs.any? { |cat, _| cat == "setup_worker" })
          assert(logs.any? { |cat, _| cat == "cluster_token" })
        end

        def test_skips_existing_workers
          setup_multi_server_ctx!
          # worker-1 is NOT in new_servers → should be skipped
          @ctx.new_servers = Set.new
          logs = []

          with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady\ntoken123") do
            SetupK3s.new(@ctx, on_log: ->(cat, msg) { logs << [ cat, msg ] }).run
          end

          assert(logs.any? { |cat, msg| cat == "skip_worker" && msg.include?("worker-1") })
          refute(logs.any? { |cat, _| cat == "setup_worker" })
        end

        def test_joins_only_new_workers
          @ctx.servers = {
            "web-1" => { id: "srv-1", ip: "1.2.3.4", private_ip: nil, group: "web" },
            "worker-1" => { id: "srv-2", ip: "5.6.7.8", private_ip: nil, group: "worker" },
            "worker-2" => { id: "srv-3", ip: "9.10.11.12", private_ip: nil, group: "worker" }
          }
          # Only worker-2 is new
          @ctx.new_servers = Set["worker-2"]
          logs = []

          with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady\nTrue\ntoken123") do
            SetupK3s.new(@ctx, on_log: ->(cat, msg) { logs << [ cat, msg ] }).run
          end

          assert(logs.any? { |cat, msg| cat == "skip_worker" && msg.include?("worker-1") })
          assert(logs.any? { |cat, msg| cat == "setup_worker" && msg.include?("worker-2") })
        end

        private

          def setup_multi_server_ctx!
            @ctx.servers = {
              "web-1" => { id: "srv-1", ip: "1.2.3.4", private_ip: nil, group: "web" },
              "worker-1" => { id: "srv-2", ip: "5.6.7.8", private_ip: nil, group: "worker" }
            }
          end
      end
    end
  end
end
