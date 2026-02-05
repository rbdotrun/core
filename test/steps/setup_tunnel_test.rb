# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Steps
    class SetupTunnelTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @ctx = build_context(target: :production)
        @ctx.server_ip = "1.2.3.4"
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
      end

      def test_creates_tunnel_and_sets_tunnel_id_on_context
        stub_request(:get, /cfd_tunnel/).to_return(
          status: 200, body: { success: true, result: [] }.to_json, headers: json_headers
        )
        stub_request(:post, /cfd_tunnel/).to_return(
          status: 200, body: { success: true,
                               result: { id: "tun-new", name: @ctx.prefix } }.to_json, headers: json_headers
        )
        stub_request(:get, %r{cfd_tunnel/tun-new/token}).to_return(
          status: 200, body: { success: true, result: "cf-token" }.to_json, headers: json_headers
        )
        stub_request(:put, %r{cfd_tunnel/tun-new/configurations}).to_return(
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

        SetupTunnel.new(@ctx, on_log: ->(_, _) { }).run

        assert_equal "tun-new", @ctx.tunnel_id
      end

      def test_skips_when_cloudflare_not_configured
        config = RbrunCore::Configuration.new
        config.compute(:hetzner) do |c|
          c.api_key = "k"
          c.ssh_key_path = TEST_SSH_KEY_PATH
        end
        config.git do |g|
          g.pat = "t"
          g.repo = "o/r"
        end
        ctx = RbrunCore::Context.new(config:, target: :production)

        SetupTunnel.new(ctx, on_log: ->(_, _) { }).run

        assert_nil ctx.tunnel_id
      end
    end
  end
end
