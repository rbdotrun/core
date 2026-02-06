# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    class DestroySandboxTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @ctx = build_context(target: :sandbox, slug: "a1b2c3")
        @ctx.server_ip = "5.6.7.8"
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
      end

      def test_run_deletes_infrastructure
        # Servers now use prefix-master-1 naming
        server_data = { "id" => 1, "name" => "rbrun-sandbox-a1b2c3-master-1", "status" => "running",
                        "public_net" => { "ipv4" => { "ip" => "5.6.7.8" } },
                        "server_type" => { "name" => "cpx11" },
                        "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } },
                        "private_net" => [], "labels" => {} }

        stub_request(:get, %r{hetzner\.cloud/v1/servers$}).to_return(
          status: 200, body: { servers: [ server_data ] }.to_json, headers: json_headers
        )
        # First call returns server (for firewall detach), subsequent calls return 404 (server deleted)
        stub_request(:get, %r{hetzner\.cloud/v1/servers/1$}).to_return(
          { status: 200, body: { server: server_data }.to_json, headers: json_headers },
          { status: 404, body: { error: { code: "not_found" } }.to_json, headers: json_headers }
        )
        stub_request(:delete, %r{servers/1}).to_return(status: 200, body: {}.to_json, headers: json_headers)
        stub_request(:get, /firewalls/).to_return(status: 200, body: { firewalls: [] }.to_json, headers: json_headers)
        stub_request(:get, /networks\?/).to_return(status: 200, body: { networks: [] }.to_json, headers: json_headers)
        stub_cloudflare_tunnel!

        with_mocked_ssh { DestroySandbox.new(@ctx, logger: TestLogger.new).run }

        assert_requested(:delete, %r{servers/1})
      end

      def test_stops_containers_via_ssh
        stub_request(:get, %r{hetzner\.cloud/v1/servers}).to_return(
          status: 200, body: { servers: [] }.to_json, headers: json_headers
        )
        stub_request(:get, /networks/).to_return(status: 200, body: { networks: [] }.to_json, headers: json_headers)
        stub_request(:get, /firewalls/).to_return(status: 200, body: { firewalls: [] }.to_json, headers: json_headers)
        stub_cloudflare_tunnel!

        cmds = with_capturing_ssh { DestroySandbox.new(@ctx, logger: TestLogger.new).run }

        assert(cmds.any? { |cmd| cmd.include?("docker compose") && cmd.include?("down") })
      end

      def test_cleanup_tunnel_when_cloudflare_configured
        @ctx.config.app do |a|
          a.process(:web) do |p|
            p.command = "bin/rails server"
            p.subdomain = "myapp"
          end
        end

        stub_hetzner_empty!
        tunnel_data = { id: "tun-1", name: @ctx.prefix, token: "tok" }
        stub_request(:get, /cfd_tunnel\?/).to_return(
          status: 200, body: { success: true, result: [ tunnel_data ] }.to_json, headers: json_headers
        )
        stub_request(:get, /zones\?/).to_return(
          status: 200, body: { success: true, result: [ { id: "zone-1" } ] }.to_json, headers: json_headers
        )
        stub_request(:get, /dns_records\?/).to_return(
          status: 200, body: { success: true,
                               result: [ { "id" => "dns-1", "name" => "myapp.test.dev" } ] }.to_json, headers: json_headers
        )
        stub_request(:delete, %r{dns_records/dns-1}).to_return(
          status: 200, body: { success: true, result: {} }.to_json, headers: json_headers
        )
        stub_request(:delete, %r{cfd_tunnel/tun-1/connections}).to_return(
          status: 200, body: { success: true, result: {} }.to_json, headers: json_headers
        )
        stub_request(:delete, %r{cfd_tunnel/tun-1$}).to_return(
          status: 200, body: { success: true, result: {} }.to_json, headers: json_headers
        )

        with_mocked_ssh { DestroySandbox.new(@ctx, logger: TestLogger.new).run }

        assert_requested(:delete, %r{cfd_tunnel/tun-1$})
        assert_requested(:delete, %r{dns_records/dns-1})
      end

      def test_no_cloudflare_calls_when_not_configured
        stub_hetzner_empty!
        @ctx.config.instance_variable_set(:@cloudflare_config, nil)

        with_mocked_ssh { DestroySandbox.new(@ctx, logger: TestLogger.new).run }

        assert_not_requested(:get, /cfd_tunnel/)
      end

      private

        def stub_hetzner_empty!
          stub_request(:get, %r{hetzner\.cloud/v1/servers}).to_return(
            status: 200, body: { servers: [] }.to_json, headers: json_headers
          )
          stub_request(:get, /networks/).to_return(status: 200, body: { networks: [] }.to_json, headers: json_headers)
          stub_request(:get, /firewalls/).to_return(status: 200, body: { firewalls: [] }.to_json, headers: json_headers)
        end

        def stub_cloudflare_tunnel!
          stub_request(:get, /cfd_tunnel/).to_return(
            status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
          )
          stub_request(:get, /zones\?/).to_return(
            status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
          )
        end
    end
  end
end
