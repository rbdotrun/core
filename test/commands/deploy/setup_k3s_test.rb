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
            SetupK3s.new(@ctx).run
          end

          assert(cmds.any? { |cmd| cmd.include?("k3s") || cmd.include?("curl") })
        end

        def test_configures_k3s_registry_mirrors
          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
            SetupK3s.new(@ctx).run
          end

          assert(cmds.any? { |cmd| cmd.include?("registries.yaml") })
        end

        def test_is_idempotent_checks_if_already_installed
          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
            SetupK3s.new(@ctx).run
          end

          assert(cmds.any? { |cmd| cmd.include?("command -v") || cmd.include?("test") })
        end

        def test_single_server_does_not_label_or_join_workers
          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady") do
            SetupK3s.new(@ctx).run
          end

          refute(cmds.any? { |cmd| cmd.include?(RbrunCore::Naming::LABEL_SERVER_GROUP) })
          refute(cmds.any? { |cmd| cmd.include?("node-token") })
        end

        # ── Multi-server mode ──

        def test_multi_server_labels_all_nodes
          setup_multi_server_ctx!
          @ctx.new_servers = Set["worker-1"]

          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \nTrue\ntoken123", output_for: nodes_json_output_for) do
            SetupK3s.new(@ctx).run
          end

          label_cmds = cmds.select { |cmd| cmd.include?(RbrunCore::Naming::LABEL_SERVER_GROUP) }

          assert_operator(label_cmds.length, :>=, 2, "Expected label commands for all nodes (master + worker)")
        end

        def test_multi_server_retrieves_cluster_token
          setup_multi_server_ctx!
          @ctx.new_servers = Set["worker-1"]

          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \nTrue\ntoken123", output_for: nodes_json_output_for) do
            SetupK3s.new(@ctx).run
          end

          assert(cmds.any? { |cmd| cmd.include?("node-token") })
        end

        def test_multi_server_reports_worker_steps
          setup_multi_server_ctx!
          @ctx.new_servers = Set["web-1", "worker-1"]
          steps = TestStepCollector.new

          with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \nTrue\ntoken123", output_for: nodes_json_output_for) do
            SetupK3s.new(@ctx, on_step: steps).run
          end

          assert_includes steps, "Workers"
          assert_includes steps, "Token"
        end

        def test_skips_existing_workers
          setup_multi_server_ctx!
          @ctx.new_servers = Set.new
          steps = TestStepCollector.new

          with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \ntoken123", output_for: nodes_json_output_for(skip_workers: true)) do
            SetupK3s.new(@ctx, on_step: steps).run
          end

          # SETUP_WORKERS should not fire when no new workers
          refute_includes steps, "Workers"
        end

        def test_joins_only_new_workers
          @ctx.servers = {
            "web-1" => { id: "srv-1", ip: "1.2.3.4", private_ip: nil, group: "web" },
            "worker-1" => { id: "srv-2", ip: "5.6.7.8", private_ip: nil, group: "worker" },
            "worker-2" => { id: "srv-3", ip: "9.10.11.12", private_ip: nil, group: "worker" }
          }
          @ctx.new_servers = Set["worker-2"]

          three_node_json = nodes_json_output_for(nodes: %w[web-1 worker-1 worker-2], groups: %w[web worker worker])

          cmds = with_capturing_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \nTrue\ntoken123", output_for: three_node_json) do
            SetupK3s.new(@ctx).run
          end

          # Only worker-2 should get k3s agent install
          join_cmds = cmds.select { |cmd| cmd.include?("K3S_URL") }

          assert_equal 1, join_cmds.size
        end

        def test_verify_cluster_topology_raises_on_missing_nodes
          setup_multi_server_ctx!
          @ctx.new_servers = Set["worker-1"]

          # Return JSON with only web-1, missing worker-1
          incomplete_json = { "get nodes -o json" => fake_nodes_json(nodes: %w[web-1], groups: %w[web]) }

          error = assert_raises(RbrunCore::Error::Standard) do
            with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \nTrue\ntoken123", output_for: incomplete_json) do
              SetupK3s.new(@ctx).run
            end
          end

          assert_match(/missing nodes/, error.message)
        end

        def test_verify_cluster_topology_raises_on_not_ready_nodes
          setup_multi_server_ctx!
          @ctx.new_servers = Set["worker-1"]

          # Return JSON with worker-1 not ready
          not_ready_json = { "get nodes -o json" => fake_nodes_json(nodes: %w[web-1 worker-1], groups: %w[web worker], ready: [ true, false ]) }

          error = assert_raises(RbrunCore::Error::Standard) do
            with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \nTrue\ntoken123", output_for: not_ready_json) do
              SetupK3s.new(@ctx).run
            end
          end

          assert_match(/not Ready/, error.message)
        end

        def test_verify_cluster_topology_raises_on_missing_labels
          setup_multi_server_ctx!
          @ctx.new_servers = Set["worker-1"]

          # Return JSON with nodes but no labels
          unlabeled_json = { "get nodes -o json" => fake_nodes_json(nodes: %w[web-1 worker-1], groups: [ nil, nil ]) }

          error = assert_raises(RbrunCore::Error::Standard) do
            with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \nTrue\ntoken123", output_for: unlabeled_json) do
              SetupK3s.new(@ctx).run
            end
          end

          assert_match(/missing.*label/, error.message)
        end

        def test_verify_reports_step
          setup_multi_server_ctx!
          @ctx.new_servers = Set["worker-1"]
          steps = TestStepCollector.new

          with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\n Ready \nTrue\ntoken123", output_for: nodes_json_output_for) do
            SetupK3s.new(@ctx, on_step: steps).run
          end

          assert_includes steps, "Verify"
        end

        private

          def setup_multi_server_ctx!
            @ctx.servers = {
              "web-1" => { id: "srv-1", ip: "1.2.3.4", private_ip: nil, group: "web" },
              "worker-1" => { id: "srv-2", ip: "5.6.7.8", private_ip: nil, group: "worker" }
            }
          end

          def nodes_json_output_for(nodes: nil, groups: nil, skip_workers: false)
            nodes ||= @ctx.servers.keys
            groups ||= @ctx.servers.values.map { |s| s[:group] }
            { "get nodes -o json" => fake_nodes_json(nodes:, groups:) }
          end

          def fake_nodes_json(nodes:, groups:, ready: nil)
            ready ||= Array.new(nodes.size, true)
            items = nodes.each_with_index.map do |name, i|
              node_name = "#{@ctx.prefix}-#{name}"
              labels = { "kubernetes.io/hostname" => node_name }
              labels[RbrunCore::Naming::LABEL_SERVER_GROUP] = groups[i] if groups[i]
              {
                "metadata" => { "name" => node_name, "labels" => labels },
                "status" => {
                  "conditions" => [
                    { "type" => "Ready", "status" => ready[i] ? "True" : "False" }
                  ]
                }
              }
            end
            JSON.generate({ "items" => items })
          end
      end
    end
  end
end
