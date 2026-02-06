# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    class DeployTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @ctx = build_context(target: :production, branch: "main")
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        @ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
      end

      def test_initializes_with_context
        cmd = Deploy.new(@ctx)

        assert_kind_of Deploy, cmd
      end

      def test_accepts_on_log_callback
        logger = TestLogger.new
        cmd = Deploy.new(@ctx, logger:)

        assert_kind_of Deploy, cmd
      end

      def test_run_calls_steps_in_order
        stub_hetzner_infrastructure!
        stub_cloudflare!

        with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady", exit_code: 0) do
          cmd = Deploy.new(@ctx, logger: TestLogger.new)
          cmd.run
        end

        assert_equal :production, @ctx.target
        refute_nil @ctx.server_id
        refute_nil @ctx.server_ip
      end

      def test_on_log_callback_fires
        stub_hetzner_infrastructure!
        stub_cloudflare!
        logger = TestLogger.new

        with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady", exit_code: 0) do
          Deploy.new(@ctx, logger:).run
        end

        assert_includes logger.categories, "firewall"
        assert_includes logger.categories, "network"
      end

      def test_cleanup_images_runs_when_app_configured
        @ctx.config.app do |a|
          a.process(:web) do |p|
            p.command = "bin/start"
            p.port = 3000
          end
        end
        stub_hetzner_infrastructure!
        stub_cloudflare!
        cleanup_ran = false

        noop_build = ->(*) { Object.new.tap { |o| o.define_singleton_method(:run) { } } }
        noop_cleanup = lambda { |_ctx, logger: nil|
          Object.new.tap do |o|
            o.define_singleton_method(:run) do
              cleanup_ran = true
              logger&.log("cleanup_images", "Cleaning up")
            end
          end
        }

        Deploy::BuildImage.stub(:new, noop_build) do
          Deploy::CleanupImages.stub(:new, noop_cleanup) do
            with_mocked_ssh(output: "ok\nready\n10.0.0.1\neth0\nRunning\nReady", exit_code: 0) do
              Deploy.new(@ctx, logger: TestLogger.new).run
            end
          end
        end

        assert cleanup_ran
      end

      def test_state_becomes_failed_on_error
        states = []
        boom = lambda { |*|
          o = Object.new
          o.define_singleton_method(:run) { raise RbrunCore::Error::Standard, "boom" }
          o
        }

        Shared::CreateInfrastructure.stub(:new, boom) do
          assert_raises(RbrunCore::Error::Standard) do
            Deploy.new(@ctx,
                       logger: TestLogger.new,
                       on_state_change: ->(s) { states << s }).run
          end
        end

        assert_includes states, :failed
      end

      private

        def stub_hetzner_infrastructure!
          stub_request(:get, %r{hetzner\.cloud/v1/firewalls}).to_return(
            status: 200, body: { firewalls: [ { id: 1, name: @ctx.prefix } ] }.to_json, headers: json_headers
          )
          stub_request(:get, %r{hetzner\.cloud/v1/networks}).to_return(
            status: 200, body: { networks: [ { id: 1, name: @ctx.prefix,
                                              ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers
          )
          stub_request(:get, %r{hetzner\.cloud/v1/servers}).to_return(
            status: 200, body: { servers: [ hetzner_server ] }.to_json, headers: json_headers
          )
          stub_request(:get, %r{hetzner\.cloud/v1/ssh_keys}).to_return(
            status: 200, body: { ssh_keys: [ { id: 1, name: "key",
                                              fingerprint: "aa:bb" } ] }.to_json, headers: json_headers
          )
        end

        def stub_cloudflare!
          stub_request(:get, /cfd_tunnel/).to_return(
            status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /cfd_tunnel/).to_return(
            status: 200, body: { success: true,
                                 result: { id: "tun-1", name: @ctx.prefix } }.to_json, headers: json_headers
          )
          stub_request(:get, %r{cfd_tunnel/tun-1/token}).to_return(
            status: 200, body: { success: true, result: "cf-token" }.to_json, headers: json_headers
          )
          stub_request(:put, %r{cfd_tunnel/tun-1/configurations}).to_return(
            status: 200, body: { success: true, result: {} }.to_json, headers: json_headers
          )
          stub_request(:get, /zones/).to_return(
            status: 200, body: { success: true, result: [ { id: "zone-1" } ] }.to_json, headers: json_headers
          )
          stub_request(:get, /dns_records/).to_return(
            status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
          )
          stub_request(:post, /dns_records/).to_return(
            status: 200, body: { success: true, result: { id: "dns-1" } }.to_json, headers: json_headers
          )
        end

        def hetzner_server
          { "id" => 123, "name" => "#{@ctx.prefix}-master-1", "status" => "running",
            "public_net" => { "ipv4" => { "ip" => "1.2.3.4" } },
            "server_type" => { "name" => "cpx11" },
            "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } },
            "labels" => {} }
        end
    end
  end
end
