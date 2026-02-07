# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    class DestroyTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @ctx = build_context(target: :production)
        @ctx.server_ip = "1.2.3.4"
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
      end

      def test_initializes_with_context
        cmd = Destroy.new(@ctx)

        assert_kind_of Destroy, cmd
      end

      def test_run_deletes_infrastructure
        server_data = { "id" => 1, "name" => "#{@ctx.prefix}-master-1", "status" => "running",
                        "public_net" => { "ipv4" => { "ip" => "1.2.3.4" } },
                        "server_type" => { "name" => "cpx11" },
                        "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } },
                        "private_net" => [], "labels" => {} }

        stub_request(:get, /cfd_tunnel/).to_return(
          status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
        )
        stub_request(:get, /zones\?/).to_return(
          status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
        )
        stub_request(:get, %r{hetzner\.cloud/v1/servers$}).to_return(
          status: 200, body: { servers: [ server_data ] }.to_json, headers: json_headers
        )
        # First call returns server (for firewall detach), subsequent calls return 404 (server deleted)
        stub_request(:get, %r{hetzner\.cloud/v1/servers/1$}).to_return(
          { status: 200, body: { server: server_data }.to_json, headers: json_headers },
          { status: 404, body: { error: { code: "not_found" } }.to_json, headers: json_headers }
        )
        stub_request(:delete, %r{servers/1}).to_return(status: 200, body: {}.to_json, headers: json_headers)
        stub_request(:get, %r{hetzner\.cloud/v1/networks}).to_return(status: 200,
                                                                     body: { networks: [ { id: 2, name: @ctx.prefix, ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers)
        stub_request(:delete, %r{networks/2}).to_return(status: 200, body: {}.to_json, headers: json_headers)
        stub_request(:get, %r{hetzner\.cloud/v1/firewalls}).to_return(status: 200,
                                                                      body: { firewalls: [ { id: 3, name: @ctx.prefix } ] }.to_json, headers: json_headers)
        stub_request(:delete, %r{firewalls/3}).to_return(status: 200, body: {}.to_json, headers: json_headers)
        stub_request(:get, %r{hetzner\.cloud/v1/volumes}).to_return(status: 200,
                                                                    body: { volumes: [] }.to_json, headers: json_headers)

        Destroy.new(@ctx, logger: TestLogger.new).run

        assert_requested(:delete, %r{servers/1})
        assert_requested(:delete, %r{networks/2})
        assert_requested(:delete, %r{firewalls/3})
      end

      def test_run_cleans_up_tunnel
        stub_request(:get, /cfd_tunnel/).to_return(
          status: 200, body: { success: true,
                               result: [ { id: "tun-1", name: @ctx.prefix } ] }.to_json, headers: json_headers
        )
        stub_request(:get, /zones/).to_return(
          status: 200, body: { success: true, result: [ { id: "zone-1" } ] }.to_json, headers: json_headers
        )
        stub_request(:get, /dns_records/).to_return(
          status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
        )
        stub_request(:delete, %r{cfd_tunnel/tun-1}).to_return(
          status: 200, body: { success: true, result: {} }.to_json, headers: json_headers
        )
        stub_request(:get, %r{hetzner\.cloud/v1/servers}).to_return(
          status: 200, body: { servers: [] }.to_json, headers: json_headers
        )
        stub_request(:get, %r{hetzner\.cloud/v1/networks}).to_return(
          status: 200, body: { networks: [] }.to_json, headers: json_headers
        )
        stub_request(:get, %r{hetzner\.cloud/v1/firewalls}).to_return(
          status: 200, body: { firewalls: [] }.to_json, headers: json_headers
        )
        stub_request(:get, %r{hetzner\.cloud/v1/volumes}).to_return(
          status: 200, body: { volumes: [] }.to_json, headers: json_headers
        )

        Destroy.new(@ctx, logger: TestLogger.new).run

        assert_requested(:delete, %r{cfd_tunnel/tun-1$})
      end
    end
  end
end
