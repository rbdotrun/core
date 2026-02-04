# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Steps
    class CreateInfrastructureTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @ctx = build_context(target: :production)
        @ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
      end

      def test_creates_firewall_network_server_and_sets_context
        stub_request(:get, /firewalls/).to_return(
          status: 200, body: { firewalls: [] }.to_json, headers: json_headers)
        stub_request(:post, /firewalls/).to_return(
          status: 201, body: { firewall: { id: 1, name: @ctx.prefix } }.to_json, headers: json_headers)
        stub_request(:get, /networks/).to_return(
          status: 200, body: { networks: [] }.to_json, headers: json_headers)
        stub_request(:post, /networks/).to_return(
          status: 201, body: { network: { id: 2, name: @ctx.prefix, ip_range: "10.0.0.0/16" } }.to_json, headers: json_headers)
        stub_request(:get, /ssh_keys/).to_return(
          status: 200, body: { ssh_keys: [{ id: 1, name: "key", fingerprint: "aa" }] }.to_json, headers: json_headers)
        stub_request(:get, /servers/).to_return(
          status: 200, body: { servers: [] }.to_json, headers: json_headers)
        stub_request(:post, /servers/).to_return(
          status: 201, body: { server: hetzner_server }.to_json, headers: json_headers)

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx, on_log: ->(_, _) {}).run
        end

        assert_equal "123", @ctx.server_id
        assert_equal "1.2.3.4", @ctx.server_ip
      end

      def test_reuses_existing_firewall_and_network
        stub_request(:get, /firewalls/).to_return(
          status: 200, body: { firewalls: [{ id: 1, name: @ctx.prefix }] }.to_json, headers: json_headers)
        stub_request(:get, /networks/).to_return(
          status: 200, body: { networks: [{ id: 2, name: @ctx.prefix, ip_range: "10.0.0.0/16" }] }.to_json, headers: json_headers)
        stub_request(:get, /servers/).to_return(
          status: 200, body: { servers: [hetzner_server] }.to_json, headers: json_headers)
        stub_request(:get, /ssh_keys/).to_return(
          status: 200, body: { ssh_keys: [{ id: 1, name: "key", fingerprint: "aa" }] }.to_json, headers: json_headers)

        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx, on_log: ->(_, _) {}).run
        end

        assert_not_requested(:post, /firewalls/)
        assert_not_requested(:post, /networks/)
      end

      def test_on_log_fires_for_each_sub_step
        stub_all_existing!
        logs = []
        with_mocked_ssh(output: "ok", exit_code: 0) do
          CreateInfrastructure.new(@ctx, on_log: ->(cat, _) { logs << cat }).run
        end
        assert_includes logs, "firewall"
        assert_includes logs, "network"
        assert_includes logs, "server"
        assert_includes logs, "ssh_wait"
      end

      private

      def hetzner_server
        { "id" => 123, "name" => @ctx.prefix, "status" => "running",
          "public_net" => { "ipv4" => { "ip" => "1.2.3.4" } },
          "server_type" => { "name" => "cpx11" },
          "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } }, "labels" => {} }
      end

      def stub_all_existing!
        stub_request(:get, /firewalls/).to_return(status: 200, body: { firewalls: [{ id: 1, name: @ctx.prefix }] }.to_json, headers: json_headers)
        stub_request(:get, /networks/).to_return(status: 200, body: { networks: [{ id: 2, name: @ctx.prefix, ip_range: "10.0.0.0/16" }] }.to_json, headers: json_headers)
        stub_request(:get, /servers/).to_return(status: 200, body: { servers: [hetzner_server] }.to_json, headers: json_headers)
        stub_request(:get, /ssh_keys/).to_return(status: 200, body: { ssh_keys: [{ id: 1, name: "key", fingerprint: "aa" }] }.to_json, headers: json_headers)
      end
    end
  end
end
