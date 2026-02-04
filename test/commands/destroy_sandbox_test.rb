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
        server_data = { "id" => 1, "name" => "rbrun-sandbox-a1b2c3", "status" => "running",
          "public_net" => { "ipv4" => { "ip" => "5.6.7.8" } },
          "server_type" => { "name" => "cpx11" },
          "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } },
          "private_net" => [], "labels" => {} }

        stub_request(:get, /hetzner\.cloud\/v1\/servers\?/).to_return(
          status: 200, body: { servers: [server_data] }.to_json, headers: json_headers)
        stub_request(:get, /hetzner\.cloud\/v1\/servers\/1$/).to_return(
          status: 200, body: { server: server_data }.to_json, headers: json_headers)
        stub_request(:delete, /servers\/1/).to_return(status: 200, body: {}.to_json, headers: json_headers)
        stub_request(:get, /firewalls/).to_return(status: 200, body: { firewalls: [] }.to_json, headers: json_headers)
        stub_request(:get, /networks\?/).to_return(status: 200, body: { networks: [] }.to_json, headers: json_headers)

        with_mocked_ssh { DestroySandbox.new(@ctx, on_log: ->(_, _) {}).run }

        assert_requested(:delete, /servers\/1/)
      end

      def test_stops_containers_via_ssh
        stub_request(:get, /hetzner\.cloud\/v1\/servers/).to_return(
          status: 200, body: { servers: [] }.to_json, headers: json_headers)
        stub_request(:get, /networks/).to_return(status: 200, body: { networks: [] }.to_json, headers: json_headers)
        stub_request(:get, /firewalls/).to_return(status: 200, body: { firewalls: [] }.to_json, headers: json_headers)

        cmds = with_capturing_ssh { DestroySandbox.new(@ctx, on_log: ->(_, _) {}).run }

        assert cmds.any? { |cmd| cmd.include?("docker compose") && cmd.include?("down") }
      end
    end
  end
end
