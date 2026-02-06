# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    module Shared
      class CreateInfrastructureTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @ctx = build_context(target: :production)
          @ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        end

        # ── Single-server mode ──

        def test_creates_firewall_network_server_and_sets_context
          stub_request(:get, /firewalls/).to_return(
            status: 200, body: { firewalls: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /firewalls/).to_return(
            status: 201, body: { firewall: { id: 1, name: @ctx.prefix } }.to_json, headers: json_headers
          )
          stub_request(:get, /networks/).to_return(
            status: 200, body: { networks: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /networks/).to_return(
            status: 201, body: { network: { id: 2, name: @ctx.prefix,
                                            ip_range: "10.0.0.0/16" } }.to_json, headers: json_headers
          )
          stub_request(:get, /ssh_keys/).to_return(
            status: 200, body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers
          )
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /servers/).to_return(
            status: 201, body: { server: hetzner_server }.to_json, headers: json_headers
          )

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(@ctx, on_log: ->(_, _) { }).run
          end

          assert_equal "123", @ctx.server_id
          assert_equal "1.2.3.4", @ctx.server_ip
        end

        def test_single_server_does_not_populate_servers_hash
          stub_all_existing!

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(@ctx, on_log: ->(_, _) { }).run
          end

          assert_empty @ctx.servers
        end

        def test_reuses_existing_firewall_and_network
          stub_request(:get, /firewalls/).to_return(
            status: 200, body: { firewalls: [ { id: 1, name: @ctx.prefix } ] }.to_json, headers: json_headers
          )
          stub_request(:get, /networks/).to_return(
            status: 200, body: { networks: [ { id: 2, name: @ctx.prefix,
                                              ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers
          )
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [ hetzner_server ] }.to_json, headers: json_headers
          )
          stub_request(:get, /ssh_keys/).to_return(
            status: 200, body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers
          )

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(@ctx, on_log: ->(_, _) { }).run
          end

          assert_not_requested(:post, /firewalls/)
          assert_not_requested(:post, /networks/)
        end

        def test_on_log_fires_for_infrastructure_steps
          stub_all_existing!
          logs = []
          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(@ctx, on_log: ->(cat, _) { logs << cat }).run
          end

          assert_includes logs, "firewall"
          assert_includes logs, "network"
        end

        def test_on_log_fires_for_server_steps
          stub_all_existing!
          logs = []
          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(@ctx, on_log: ->(cat, _) { logs << cat }).run
          end

          assert_includes logs, "server"
          assert_includes logs, "ssh_wait"
        end

        # ── Firewall sandbox vs release ──

        def test_sandbox_firewall_only_includes_port_22
          sandbox_ctx = build_context(target: :sandbox, slug: "a1b2c3")
          sandbox_ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
          sandbox_ctx.ssh_private_key = TEST_SSH_KEY.private_key

          captured_body = nil
          stub_request(:get, /firewalls/).to_return(
            status: 200, body: { firewalls: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /firewalls/).to_return(lambda { |req|
            captured_body = JSON.parse(req.body)
            { status: 201, body: { firewall: { id: 1, name: sandbox_ctx.prefix } }.to_json, headers: json_headers }
          })
          stub_request(:get, /networks/).to_return(
            status: 200, body: { networks: [ { id: 2, name: sandbox_ctx.prefix,
                                              ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers
          )
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [ sandbox_server ] }.to_json, headers: json_headers
          )
          stub_request(:get, /ssh_keys/).to_return(
            status: 200, body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers
          )

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(sandbox_ctx, on_log: ->(_, _) { }).run
          end

          rules = captured_body["rules"]

          assert_equal 1, rules.length
          assert_equal "22", rules[0]["port"]
        end

        def test_release_firewall_includes_port_22_and_6443
          captured_body = nil
          stub_request(:get, /firewalls/).to_return(
            status: 200, body: { firewalls: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /firewalls/).to_return(lambda { |req|
            captured_body = JSON.parse(req.body)
            { status: 201, body: { firewall: { id: 1, name: @ctx.prefix } }.to_json, headers: json_headers }
          })
          stub_request(:get, /networks/).to_return(
            status: 200, body: { networks: [ { id: 2, name: @ctx.prefix,
                                              ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers
          )
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [ hetzner_server ] }.to_json, headers: json_headers
          )
          stub_request(:get, /ssh_keys/).to_return(
            status: 200, body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers
          )

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(@ctx, on_log: ->(_, _) { }).run
          end

          rules = captured_body["rules"]
          ports = rules.map { |r| r["port"] }

          assert_equal 2, rules.length
          assert_includes ports, "22"
          assert_includes ports, "6443"
        end

        # ── Multi-server mode ──

        def test_multi_server_creates_all_servers_and_populates_ctx
          ctx = build_multi_server_context
          server_index = 0

          stub_all_existing_for!(ctx)
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /servers/).to_return(lambda { |_req|
            server_index += 1
            { status: 201, body: { server: multi_server_response(server_index) }.to_json, headers: json_headers }
          })

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          assert_equal 3, ctx.servers.size
          assert_includes ctx.servers.keys, "web-1"
          assert_includes ctx.servers.keys, "web-2"
          assert_includes ctx.servers.keys, "worker-1"
        end

        def test_multi_server_sets_first_server_as_master
          ctx = build_multi_server_context
          server_index = 0

          stub_all_existing_for!(ctx)
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /servers/).to_return(lambda { |_req|
            server_index += 1
            { status: 201, body: { server: multi_server_response(server_index) }.to_json, headers: json_headers }
          })

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          # First server created becomes master
          assert_equal "1", ctx.server_id
          assert_equal "10.0.0.1", ctx.server_ip
        end

        def test_multi_server_stores_group_info
          ctx = build_multi_server_context
          server_index = 0

          stub_all_existing_for!(ctx)
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /servers/).to_return(lambda { |_req|
            server_index += 1
            { status: 201, body: { server: multi_server_response(server_index) }.to_json, headers: json_headers }
          })

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          assert_equal "web", ctx.servers["web-1"][:group]
          assert_equal "web", ctx.servers["web-2"][:group]
          assert_equal "worker", ctx.servers["worker-1"][:group]
        end

        def test_multi_server_creates_correct_number_of_servers
          ctx = build_multi_server_context

          stub_all_existing_for!(ctx)
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /servers/).to_return(lambda { |_req|
            { status: 201, body: { server: multi_server_response(1) }.to_json, headers: json_headers }
          })

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          # web: count 2, worker: count 1 → 3 POST /servers calls
          assert_requested(:post, /servers/, times: 3)
        end

        def test_multi_server_logs_each_server_creation
          ctx = build_multi_server_context
          logs = []

          stub_all_existing_for!(ctx)
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /servers/).to_return(lambda { |_req|
            { status: 201, body: { server: multi_server_response(1) }.to_json, headers: json_headers }
          })

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_log: ->(cat, msg) { logs << [ cat, msg ] }).run
          end

          server_logs = logs.select { |cat, _| cat == "server" }

          assert_equal 3, server_logs.size
          assert(server_logs.any? { |_, msg| msg.include?("web-1") })
          assert(server_logs.any? { |_, msg| msg.include?("web-2") })
          assert(server_logs.any? { |_, msg| msg.include?("worker-1") })
        end

        # ── Reconciliation ──

        def test_scale_up_creates_only_new_servers
          ctx = build_multi_server_context_with_count(app: 3, db: 1)
          existing_list = [ hetzner_named_server(ctx, "app-1", 1) ]

          stub_all_existing_for!(ctx)
          stub_reconciliation_servers!(ctx, existing_list)

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          assert_equal 4, ctx.servers.size
          assert_equal Set["app-2", "app-3", "db-1"], ctx.new_servers
        end

        def test_scale_down_drains_and_deletes_excess
          ctx = build_multi_server_context_with_count(app: 1, db: 1)
          existing_list = [
            hetzner_named_server(ctx, "app-1", 1),
            hetzner_named_server(ctx, "app-2", 2),
            hetzner_named_server(ctx, "app-3", 3),
            hetzner_named_server(ctx, "db-1", 4)
          ]

          stub_all_existing_for!(ctx)
          stub_reconciliation_servers!(ctx, existing_list)
          stub_server_deletion!

          with_mocked_ssh(output: "", exit_code_for: { "kubectl get node" => 1 }) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          assert_requested(:delete, /servers\/2/)
          assert_requested(:delete, /servers\/3/)
          assert_equal 2, ctx.servers.size
          assert_includes ctx.servers.keys, "app-1"
          assert_includes ctx.servers.keys, "db-1"
          assert_empty ctx.new_servers
        end

        def test_scale_down_preserves_master_node
          # Master is always desired.keys.first — which is always in the desired set.
          # Verify scale-down never touches the master even when other servers are removed.
          ctx = build_multi_server_context_with_count(app: 1, db: 1)
          existing_list = [
            hetzner_named_server(ctx, "app-1", 1),
            hetzner_named_server(ctx, "app-2", 2),
            hetzner_named_server(ctx, "db-1", 3)
          ]

          stub_all_existing_for!(ctx)
          stub_reconciliation_servers!(ctx, existing_list)
          stub_server_deletion!

          with_mocked_ssh(output: "", exit_code_for: { "kubectl get node" => 1 }) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          # app-1 (master) and db-1 kept, app-2 removed
          assert_includes ctx.servers.keys, "app-1"
          assert_requested(:delete, /servers\/2/)
          assert_not_requested(:delete, /servers\/1/)
        end

        def test_drain_failure_continues_with_deletion
          ctx = build_multi_server_context_with_count(app: 1, db: 0)
          existing_list = [
            hetzner_named_server(ctx, "app-1", 1),
            hetzner_named_server(ctx, "app-2", 2)
          ]

          stub_all_existing_for!(ctx)
          stub_reconciliation_servers!(ctx, existing_list)
          stub_server_deletion!

          # drain will see non-empty pods output (triggering the "still has pods" error), but we rescue it
          with_mocked_ssh(output: "some-pod", exit_code_for: { "kubectl get node" => 1 }) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          assert_requested(:delete, /servers\/2/)
        end

        def test_no_change_when_counts_match
          ctx = build_multi_server_context
          existing_list = [
            hetzner_named_server(ctx, "web-1", 1),
            hetzner_named_server(ctx, "web-2", 2),
            hetzner_named_server(ctx, "worker-1", 3)
          ]

          stub_all_existing_for!(ctx)
          stub_reconciliation_servers!(ctx, existing_list)

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          assert_equal 3, ctx.servers.size
          assert_empty ctx.new_servers
        end

        def test_idempotent_rerun_preserves_existing_servers
          ctx = build_multi_server_context
          existing_list = [
            hetzner_named_server(ctx, "web-1", 10),
            hetzner_named_server(ctx, "web-2", 20),
            hetzner_named_server(ctx, "worker-1", 30)
          ]

          stub_all_existing_for!(ctx)
          stub_reconciliation_servers!(ctx, existing_list)

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_log: ->(_, _) { }).run
          end

          assert_equal "10.0.0.10", ctx.servers["web-1"][:ip]
          assert_equal "10.0.0.20", ctx.servers["web-2"][:ip]
          assert_equal "10.0.0.30", ctx.servers["worker-1"][:ip]
        end

        private

          def sandbox_server
            { "id" => 456, "name" => "rbrun-sandbox-a1b2c3", "status" => "running",
              "public_net" => { "ipv4" => { "ip" => "5.6.7.8" } },
              "server_type" => { "name" => "cpx11" },
              "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } }, "labels" => {} }
          end

          def hetzner_server
            { "id" => 123, "name" => @ctx.prefix, "status" => "running",
              "public_net" => { "ipv4" => { "ip" => "1.2.3.4" } },
              "server_type" => { "name" => "cpx11" },
              "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } }, "labels" => {} }
          end

          def multi_server_response(index)
            { "id" => index, "name" => "test-repo-production-srv-#{index}", "status" => "running",
              "public_net" => { "ipv4" => { "ip" => "10.0.0.#{index}" } },
              "server_type" => { "name" => "cpx21" },
              "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } }, "labels" => {} }
          end

          def build_multi_server_context
            config = RbrunCore::Configuration.new
            config.compute(:hetzner) do |c|
              c.api_key = "test-hetzner-key"
              c.ssh_key_path = TEST_SSH_KEY_PATH
              c.add_server_group(:web, type: "cpx21", count: 2)
              c.add_server_group(:worker, type: "cpx11", count: 1)
            end
            config.cloudflare do |cf|
              cf.api_token = "test-cloudflare-key"
              cf.account_id = "test-account-id"
              cf.domain = "test.dev"
            end
            config.git do |g|
              g.pat = "test-github-token"
              g.repo = "owner/test-repo"
            end

            ctx = RbrunCore::Context.new(config:, target: :production)
            ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
            ctx.ssh_private_key = TEST_SSH_KEY.private_key
            ctx
          end

          def stub_all_existing!
            stub_request(:get, /firewalls/).to_return(status: 200,
                                                      body: { firewalls: [ { id: 1, name: @ctx.prefix } ] }.to_json, headers: json_headers)
            stub_request(:get, /networks/).to_return(status: 200,
                                                     body: { networks: [ { id: 2, name: @ctx.prefix, ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers)
            stub_request(:get, /servers/).to_return(status: 200, body: { servers: [ hetzner_server ] }.to_json,
                                                    headers: json_headers)
            stub_request(:get, /ssh_keys/).to_return(status: 200,
                                                     body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers)
          end

          def stub_all_existing_for!(ctx)
            stub_request(:get, /firewalls/).to_return(status: 200,
                                                      body: { firewalls: [ { id: 1, name: ctx.prefix } ] }.to_json, headers: json_headers)
            stub_request(:get, /networks/).to_return(status: 200,
                                                     body: { networks: [ { id: 2, name: ctx.prefix, ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers)
            stub_request(:get, /ssh_keys/).to_return(status: 200,
                                                     body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers)
          end

          def stub_reconciliation_servers!(ctx, existing_list)
            existing_by_name = existing_list.each_with_object({}) { |s, h| h[s["name"]] = s }
            server_create_index = 100

            stub_request(:get, /servers/).to_return(lambda { |req|
              uri = URI(req.uri)
              params = URI.decode_www_form(uri.query || "").to_h
              if params["name"]
                match = existing_by_name[params["name"]]
                body = { servers: match ? [ match ] : [] }
              else
                body = { servers: existing_list }
              end
              { status: 200, body: body.to_json, headers: json_headers }
            })

            stub_request(:post, %r{/v1/servers\b}).to_return(lambda { |_req|
              server_create_index += 1
              { status: 201, body: { server: multi_server_response(server_create_index) }.to_json, headers: json_headers }
            })
          end

          def stub_server_deletion!
            stub_request(:get, /servers\/\d+\b/).to_return(lambda { |req|
              id = req.uri.to_s[/servers\/(\d+)/, 1]
              { status: 200, body: { server: multi_server_response(id.to_i) }.to_json, headers: json_headers }
            })
            stub_request(:delete, /servers\/\d+/).to_return(status: 200, body: "".to_json, headers: json_headers)
            stub_request(:post, /servers\/\d+\/actions/).to_return(
              status: 200, body: { action: { id: 1 } }.to_json, headers: json_headers
            )
          end

          def hetzner_named_server(ctx, key, id)
            { "id" => id, "name" => "#{ctx.prefix}-#{key}", "status" => "running",
              "public_net" => { "ipv4" => { "ip" => "10.0.0.#{id}" } },
              "server_type" => { "name" => "cpx21" },
              "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } }, "labels" => {} }
          end

          def build_multi_server_context_with_count(app: 2, db: 0)
            config = RbrunCore::Configuration.new
            config.compute(:hetzner) do |c|
              c.api_key = "test-hetzner-key"
              c.ssh_key_path = TEST_SSH_KEY_PATH
              c.add_server_group(:app, type: "cpx21", count: app) if app > 0
              c.add_server_group(:db, type: "cpx11", count: db) if db > 0
            end
            config.cloudflare do |cf|
              cf.api_token = "test-cloudflare-key"
              cf.account_id = "test-account-id"
              cf.domain = "test.dev"
            end
            config.git do |g|
              g.pat = "test-github-token"
              g.repo = "owner/test-repo"
            end

            ctx = RbrunCore::Context.new(config:, target: :production)
            ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
            ctx.ssh_private_key = TEST_SSH_KEY.private_key
            ctx
          end
      end
    end
  end
end
