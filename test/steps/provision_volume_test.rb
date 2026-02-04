# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Steps
    class ProvisionVolumeTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @ctx = build_context(target: :production)
        @ctx.server_id = "123"
        @ctx.server_ip = "1.2.3.4"
        @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        @ctx.config.database(:postgres) { |db| db.volume_size = 20 }
      end

      def test_creates_and_attaches_volume_via_hetzner_api
        # find_server (for location)
        stub_request(:get, /servers\?/).to_return(
          status: 200, body: { servers: [hetzner_server] }.to_json, headers: json_headers)
        # find_volume (not found)
        stub_request(:get, /volumes\?/).to_return(
          status: 200, body: { volumes: [] }.to_json, headers: json_headers)
        # create_volume
        stub_request(:post, /\/volumes$/).to_return(
          status: 201, body: { volume: { id: 1, name: "vol", size: 20, linux_device: "/dev/sdb", server: nil, location: { name: "ash" } } }.to_json, headers: json_headers)
        # get_volume before attach (checks if already attached)
        stub_request(:get, /volumes\/1$/).to_return(
          status: 200, body: { volume: { id: 1, name: "vol", size: 20, linux_device: "/dev/sdb", server: nil, location: { name: "ash" } } }.to_json, headers: json_headers)
        # attach_volume
        stub_request(:post, /volumes\/1\/actions\/attach/).to_return(
          status: 200, body: { action: { id: 1, status: "success" } }.to_json, headers: json_headers)
        # wait_for_action
        stub_request(:get, /actions\/1$/).to_return(
          status: 200, body: { action: { id: 1, status: "success" } }.to_json, headers: json_headers)

        with_mocked_ssh(output: "ready\nmounted\nok\nTYPE=xfs", exit_code: 0) do
          ProvisionVolume.new(@ctx, on_log: ->(_, _) {}).run
        end

        assert_requested(:post, /\/volumes$/)
      end

      def test_skips_when_no_databases_configured
        ctx = build_context(target: :production)
        ctx.server_id = "123"
        ctx.server_ip = "1.2.3.4"
        ctx.ssh_private_key = TEST_SSH_KEY.private_key

        ProvisionVolume.new(ctx, on_log: ->(_, _) {}).run
        assert_not_requested(:post, /\/volumes/)
      end

      private

      def hetzner_server
        { "id" => 123, "name" => @ctx.prefix, "status" => "running",
          "public_net" => { "ipv4" => { "ip" => "1.2.3.4" } },
          "server_type" => { "name" => "cpx11" },
          "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } }, "labels" => {} }
      end
    end
  end
end
