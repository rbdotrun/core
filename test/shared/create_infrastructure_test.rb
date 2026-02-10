# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Shared
    class CreateInfrastructureTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @ctx = build_context(target: :production)
        @ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
      end

      # ── Master-only mode ──

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
          status: 201, body: { server: hetzner_master_server }.to_json, headers: json_headers
        )

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx).run
        end

        assert_equal "123", @ctx.server_id
        assert_equal "1.2.3.4", @ctx.server_ip
      end

      def test_master_only_populates_servers_hash
        stub_all_existing!

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx).run
        end

        assert_equal 1, @ctx.servers.size
        assert_includes @ctx.servers.keys, "master-1"
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
          status: 200, body: { servers: [ hetzner_master_server ] }.to_json, headers: json_headers
        )
        stub_request(:get, /ssh_keys/).to_return(
          status: 200, body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers
        )

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx).run
        end

        assert_not_requested(:post, /firewalls/)
        assert_not_requested(:post, /networks/)
      end

      def test_on_step_fires_for_infrastructure_steps
        stub_all_existing!
        steps = TestStepCollector.new
        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx, on_step: steps).run
        end

        assert_includes steps, "Firewall"
        assert_includes steps, "Network"
      end

      def test_on_step_fires_for_server_steps_when_creating_new_server
        # Stub existing firewall and network, but no servers
        stub_request(:get, /firewalls/).to_return(status: 200,
                                                  body: { firewalls: [ { id: 1, name: @ctx.prefix } ] }.to_json, headers: json_headers)
        stub_request(:get, /networks/).to_return(status: 200,
                                                 body: { networks: [ { id: 2, name: @ctx.prefix, ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers)
        stub_request(:get, /servers/).to_return(status: 200, body: { servers: [] }.to_json, headers: json_headers)
        stub_request(:get, /ssh_keys/).to_return(status: 200,
                                                 body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers)
        stub_request(:post, /servers/).to_return(
          status: 201, body: { server: hetzner_master_server }.to_json, headers: json_headers
        )

        steps = TestStepCollector.new
        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx, on_step: steps).run
        end

        assert_includes steps, "Server"
        assert_includes steps, "SSH"
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
          status: 200, body: { servers: [ sandbox_master_server(sandbox_ctx) ] }.to_json, headers: json_headers
        )
        stub_request(:get, /ssh_keys/).to_return(
          status: 200, body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers
        )

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(sandbox_ctx).run
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
          status: 200, body: { servers: [ hetzner_master_server ] }.to_json, headers: json_headers
        )
        stub_request(:get, /ssh_keys/).to_return(
          status: 200, body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers
        )

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx).run
        end

        rules = captured_body["rules"]
        ports = rules.map { |r| r["port"] }

        assert_equal 2, rules.length
        assert_includes ports, "22"
        assert_includes ports, "6443"
      end

      # ── Multi-server mode (master + additional servers) ──

      def test_multi_server_creates_correct_server_count
        ctx = run_multi_server_create

        assert_equal 4, ctx.servers.size
      end

      def test_multi_server_creates_master
        ctx = run_multi_server_create

        assert_includes ctx.servers.keys, "master-1"
      end

      def test_multi_server_creates_web_servers
        ctx = run_multi_server_create

        assert_includes ctx.servers.keys, "web-1"
        assert_includes ctx.servers.keys, "web-2"
      end

      def test_multi_server_creates_worker
        ctx = run_multi_server_create

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
          CreateInfrastructure.new(ctx).run
        end

        # First server created becomes master
        assert_equal "1", ctx.server_id
        assert_equal "10.0.0.1", ctx.server_ip
      end

      def test_multi_server_stores_master_group
        ctx = run_multi_server_create

        assert_equal "master", ctx.servers["master-1"][:group]
      end

      def test_multi_server_stores_web_group
        ctx = run_multi_server_create

        assert_equal "web", ctx.servers["web-1"][:group]
        assert_equal "web", ctx.servers["web-2"][:group]
      end

      def test_multi_server_stores_worker_group
        ctx = run_multi_server_create

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
          CreateInfrastructure.new(ctx).run
        end

        # master: 1 + web: 2 + worker: 1 = 4 POST /servers calls
        assert_requested(:post, /servers/, times: 4)
      end

      def test_multi_server_reports_create_server_steps
        _, steps = run_multi_server_create_with_steps

        # Should report CREATE_SERVER step (IN_PROGRESS + DONE for each = 8 total for 4 servers)
        create_server_steps = steps.steps.select { |s| s[:label] == "Server" }

        assert_operator create_server_steps.size, :>=, 4
      end

      def test_multi_server_reports_wait_ssh_steps
        _, steps = run_multi_server_create_with_steps

        # Should report WAIT_SSH step
        assert_includes steps, "SSH"
      end

      # ── Reconciliation ──

      def test_scale_up_creates_only_new_servers
        ctx = build_multi_server_context_with_count(app: 3, db: 1)
        # Existing: master-1, app-1
        existing_list = [
          hetzner_named_server(ctx, "master-1", 1),
          hetzner_named_server(ctx, "app-1", 2)
        ]

        stub_all_existing_for!(ctx)
        stub_reconciliation_servers!(ctx, existing_list)

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(ctx).run
        end

        # master-1 + app-1 + app-2 + app-3 + db-1 = 5
        assert_equal 5, ctx.servers.size
        assert_equal Set["app-2", "app-3", "db-1"], ctx.new_servers
      end

      def test_scale_down_stores_servers_to_remove_in_order
        ctx = run_scale_down_scenario

        assert_equal [ "#{ctx.prefix}-app-3", "#{ctx.prefix}-app-2" ], ctx.servers_to_remove
      end

      def test_scale_down_keeps_correct_server_count
        ctx = run_scale_down_scenario

        assert_equal 3, ctx.servers.size
      end

      def test_scale_down_keeps_master
        ctx = run_scale_down_scenario

        assert_includes ctx.servers.keys, "master-1"
      end

      def test_scale_down_keeps_first_app_and_db
        ctx = run_scale_down_scenario

        assert_includes ctx.servers.keys, "app-1"
        assert_includes ctx.servers.keys, "db-1"
      end

      def test_scale_down_has_no_new_servers
        ctx = run_scale_down_scenario

        assert_empty ctx.new_servers
      end

      def test_scale_down_preserves_master_node
        ctx = build_multi_server_context_with_count(app: 1, db: 1)
        existing_list = [
          hetzner_named_server(ctx, "master-1", 1),
          hetzner_named_server(ctx, "app-1", 2),
          hetzner_named_server(ctx, "app-2", 3),
          hetzner_named_server(ctx, "db-1", 4)
        ]

        stub_all_existing_for!(ctx)
        stub_reconciliation_servers!(ctx, existing_list)

        with_mocked_ssh(output: "", exit_code: 0) do
          CreateInfrastructure.new(ctx).run
        end

        # master-1 kept in servers, app-2 marked for removal
        assert_includes ctx.servers.keys, "master-1"
        assert_equal [ "#{ctx.prefix}-app-2" ], ctx.servers_to_remove
      end

      def test_servers_to_remove_is_empty_when_no_scale_down
        ctx = build_multi_server_context
        existing_list = [
          hetzner_named_server(ctx, "master-1", 1),
          hetzner_named_server(ctx, "web-1", 2),
          hetzner_named_server(ctx, "web-2", 3),
          hetzner_named_server(ctx, "worker-1", 4)
        ]

        stub_all_existing_for!(ctx)
        stub_reconciliation_servers!(ctx, existing_list)

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(ctx).run
        end

        assert_empty ctx.servers_to_remove
      end

      def test_no_change_when_counts_match
        ctx = build_multi_server_context
        existing_list = [
          hetzner_named_server(ctx, "master-1", 1),
          hetzner_named_server(ctx, "web-1", 2),
          hetzner_named_server(ctx, "web-2", 3),
          hetzner_named_server(ctx, "worker-1", 4)
        ]

        stub_all_existing_for!(ctx)
        stub_reconciliation_servers!(ctx, existing_list)

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(ctx).run
        end

        assert_equal 4, ctx.servers.size
        assert_empty ctx.new_servers
      end

      def test_idempotent_rerun_preserves_master_ip
        ctx = run_idempotent_scenario

        assert_equal "10.0.0.10", ctx.servers["master-1"][:ip]
      end

      def test_idempotent_rerun_preserves_web_ips
        ctx = run_idempotent_scenario

        assert_equal "10.0.0.20", ctx.servers["web-1"][:ip]
        assert_equal "10.0.0.30", ctx.servers["web-2"][:ip]
      end

      def test_idempotent_rerun_preserves_worker_ip
        ctx = run_idempotent_scenario

        assert_equal "10.0.0.40", ctx.servers["worker-1"][:ip]
      end

      # ── Per-process server provisioning ──

      def test_process_instance_type_creates_servers
        ctx = build_process_instance_type_context
        stub_all_existing_for!(ctx)
        stub_request(:get, /servers/).to_return(
          status: 200, body: { servers: [] }.to_json, headers: json_headers
        )
        stub_request(:post, /servers/).to_return(lambda { |_req|
          { status: 201, body: { server: multi_server_response(1) }.to_json, headers: json_headers }
        })

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(ctx).run
        end

        # master-1 + web-1 + web-2 + worker-1 = 4 servers
        assert_equal 4, ctx.servers.size
        assert_includes ctx.servers.keys, "master-1"
        assert_includes ctx.servers.keys, "web-1"
        assert_includes ctx.servers.keys, "web-2"
        assert_includes ctx.servers.keys, "worker-1"
      end

      def test_service_instance_type_creates_servers
        ctx = build_service_instance_type_context
        stub_all_existing_for!(ctx)
        stub_request(:get, /servers/).to_return(
          status: 200, body: { servers: [] }.to_json, headers: json_headers
        )
        stub_request(:post, /servers/).to_return(lambda { |_req|
          { status: 201, body: { server: multi_server_response(1) }.to_json, headers: json_headers }
        })

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(ctx).run
        end

        # master-1 + meilisearch-1 = 2 servers
        assert_equal 2, ctx.servers.size
        assert_includes ctx.servers.keys, "master-1"
        assert_includes ctx.servers.keys, "meilisearch-1"
      end

      private

        def build_process_instance_type_context
          config = RbrunCore::Configuration.new
          config.target = :production
          config.name = "testapp"
          config.compute(:hetzner) do |c|
            c.api_key = "test-hetzner-key"
            c.ssh_key_path = TEST_SSH_KEY_PATH
            c.master.instance_type = "cpx21"
          end
          config.cloudflare do |cf|
            cf.api_token = "test-cloudflare-key"
            cf.account_id = "test-account-id"
            cf.domain = "test.dev"
          end
          config.app do |a|
            a.process(:web) do |p|
              p.port = 3000
              p.instance_type = "cpx32"
              p.replicas = 2
            end
            a.process(:worker) do |p|
              p.command = "bin/jobs"
              p.instance_type = "cx23"
            end
          end

          ctx = RbrunCore::Context.new(config:)
          ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
          ctx.ssh_private_key = TEST_SSH_KEY.private_key
          ctx
        end

        def build_service_instance_type_context
          config = RbrunCore::Configuration.new
          config.target = :production
          config.name = "testapp"
          config.compute(:hetzner) do |c|
            c.api_key = "test-hetzner-key"
            c.ssh_key_path = TEST_SSH_KEY_PATH
            c.master.instance_type = "cpx21"
          end
          config.cloudflare do |cf|
            cf.api_token = "test-cloudflare-key"
            cf.account_id = "test-account-id"
            cf.domain = "test.dev"
          end
          config.service(:meilisearch) do |s|
            s.image = "getmeili/meilisearch:v1.6"
            s.port = 7700
            s.instance_type = "cx22"
          end

          ctx = RbrunCore::Context.new(config:)
          ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
          ctx.ssh_private_key = TEST_SSH_KEY.private_key
          ctx
        end

        def sandbox_master_server(ctx)
          { "id" => 456, "name" => "#{ctx.prefix}-master-1", "status" => "running",
            "public_net" => { "ipv4" => { "ip" => "5.6.7.8" } },
            "server_type" => { "name" => "cpx11" },
            "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } }, "labels" => {} }
        end

        def hetzner_master_server
          { "id" => 123, "name" => "#{@ctx.prefix}-master-1", "status" => "running",
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
          config.target = :production
          config.name = "testapp"
          config.compute(:hetzner) do |c|
            c.api_key = "test-hetzner-key"
            c.ssh_key_path = TEST_SSH_KEY_PATH
            c.master.instance_type = "cpx21"
            c.add_server_group(:web, type: "cpx21", count: 2)
            c.add_server_group(:worker, type: "cpx11", count: 1)
          end
          config.cloudflare do |cf|
            cf.api_token = "test-cloudflare-key"
            cf.account_id = "test-account-id"
            cf.domain = "test.dev"
          end

          ctx = RbrunCore::Context.new(config:)
          ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
          ctx.ssh_private_key = TEST_SSH_KEY.private_key
          ctx
        end

        def stub_all_existing!
          stub_request(:get, /firewalls/).to_return(status: 200,
                                                    body: { firewalls: [ { id: 1, name: @ctx.prefix } ] }.to_json, headers: json_headers)
          stub_request(:get, /networks/).to_return(status: 200,
                                                   body: { networks: [ { id: 2, name: @ctx.prefix, ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers)
          stub_request(:get, /servers/).to_return(status: 200, body: { servers: [ hetzner_master_server ] }.to_json,
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
          deleted_servers = Set.new
          stub_request(:get, /servers\/\d+\b/).to_return(lambda { |req|
            id = req.uri.to_s[/servers\/(\d+)/, 1]
            if deleted_servers.include?(id)
              { status: 404, body: { error: { code: "not_found" } }.to_json, headers: json_headers }
            else
              { status: 200, body: { server: multi_server_response(id.to_i) }.to_json, headers: json_headers }
            end
          })
          stub_request(:delete, /servers\/\d+/).to_return(lambda { |req|
            id = req.uri.to_s[/servers\/(\d+)/, 1]
            deleted_servers.add(id)
            { status: 200, body: "".to_json, headers: json_headers }
          })
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
          config.target = :production
          config.name = "testapp"
          config.compute(:hetzner) do |c|
            c.api_key = "test-hetzner-key"
            c.ssh_key_path = TEST_SSH_KEY_PATH
            c.master.instance_type = "cpx21"
            c.add_server_group(:app, type: "cpx21", count: app) if app > 0
            c.add_server_group(:db, type: "cpx11", count: db) if db > 0
          end
          config.cloudflare do |cf|
            cf.api_token = "test-cloudflare-key"
            cf.account_id = "test-account-id"
            cf.domain = "test.dev"
          end

          ctx = RbrunCore::Context.new(config:)
          ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
          ctx.ssh_private_key = TEST_SSH_KEY.private_key
          ctx
        end

        def run_multi_server_create
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
            CreateInfrastructure.new(ctx).run
          end

          ctx
        end

        def run_multi_server_create_with_steps
          ctx = build_multi_server_context
          steps = TestStepCollector.new

          stub_all_existing_for!(ctx)
          stub_request(:get, /servers/).to_return(
            status: 200, body: { servers: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /servers/).to_return(lambda { |_req|
            { status: 201, body: { server: multi_server_response(1) }.to_json, headers: json_headers }
          })

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx, on_step: steps).run
          end

          [ ctx, steps ]
        end

        def run_scale_down_scenario
          ctx = build_multi_server_context_with_count(app: 1, db: 1)
          existing_list = [
            hetzner_named_server(ctx, "master-1", 1),
            hetzner_named_server(ctx, "app-1", 2),
            hetzner_named_server(ctx, "app-2", 3),
            hetzner_named_server(ctx, "app-3", 4),
            hetzner_named_server(ctx, "db-1", 5)
          ]

          stub_all_existing_for!(ctx)
          stub_reconciliation_servers!(ctx, existing_list)

          with_mocked_ssh(output: "", exit_code: 0) do
            CreateInfrastructure.new(ctx).run
          end

          ctx
        end

        def run_idempotent_scenario
          ctx = build_multi_server_context
          existing_list = [
            hetzner_named_server(ctx, "master-1", 10),
            hetzner_named_server(ctx, "web-1", 20),
            hetzner_named_server(ctx, "web-2", 30),
            hetzner_named_server(ctx, "worker-1", 40)
          ]

          stub_all_existing_for!(ctx)
          stub_reconciliation_servers!(ctx, existing_list)

          with_mocked_ssh(output: "ok", exit_code: 0) do
            CreateInfrastructure.new(ctx).run
          end

          ctx
        end
    end
  end
end
