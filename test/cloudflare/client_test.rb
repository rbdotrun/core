# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Cloudflare
    class ClientTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @client = Client.new(api_token: "test-cf-token", account_id: "test-account-id")
      end

      def test_get_zone_id_returns_zone_id
        stub_request(:get, %r{api\.cloudflare\.com/client/v4/zones})
          .to_return(status: 200, body: { success: true, result: [ { id: "zone-1" } ] }.to_json, headers: json_headers)

        assert_equal "zone-1", @client.get_zone_id("example.com")
      end

      def test_get_zone_id_raises_when_not_found
        stub_request(:get, /zones/).to_return(
          status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
        )
        assert_raises(RbrunCore::Error) { @client.get_zone_id("missing.com") }
      end

      def test_find_tunnel_returns_nil
        stub_request(:get, /cfd_tunnel/).to_return(
          status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
        )

        assert_nil @client.find_tunnel("nonexistent")
      end

      def test_find_or_create_tunnel_returns_existing
        stub_request(:get, /cfd_tunnel/).to_return(
          status: 200, body: { success: true, result: [ { id: "tun-1", name: "test" } ] }.to_json, headers: json_headers
        )
        tunnel = @client.find_or_create_tunnel("test")

        assert_equal "tun-1", tunnel[:id]
      end

      def test_find_or_create_tunnel_creates_when_not_found
        stub_request(:get, /cfd_tunnel/).to_return(
          status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
        )
        stub_request(:post, /cfd_tunnel/).to_return(
          status: 200, body: { success: true, result: { id: "tun-new", name: "test" } }.to_json, headers: json_headers
        )
        tunnel = @client.find_or_create_tunnel("test")

        assert_equal "tun-new", tunnel[:id]
      end

      def test_delete_tunnel_sends_request
        stub_request(:delete, %r{cfd_tunnel/tun-1}).to_return(
          status: 200, body: { success: true, result: {} }.to_json, headers: json_headers
        )
        @client.delete_tunnel("tun-1")

        assert_requested(:delete, %r{cfd_tunnel/tun-1$})
      end

      def test_ensure_dns_record_creates_when_not_found
        stub_request(:get, /dns_records/).to_return(
          status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
        )
        stub_request(:post, /dns_records/).to_return(
          status: 200, body: { success: true, result: { id: "dns-1" } }.to_json, headers: json_headers
        )
        @client.ensure_dns_record("zone-1", "app.example.com", "tun-1")

        assert_requested(:post, /dns_records/)
      end

      def test_ensure_dns_record_skips_when_exists
        stub_request(:get, /dns_records/).to_return(
          status: 200, body: { success: true,
                               result: [ { id: "dns-1", name: "app.example.com",
                                          content: "tun-1.cfargotunnel.com" } ] }.to_json, headers: json_headers
        )
        @client.ensure_dns_record("zone-1", "app.example.com", "tun-1")

        assert_not_requested(:post, /dns_records/)
      end
    end
  end
end
