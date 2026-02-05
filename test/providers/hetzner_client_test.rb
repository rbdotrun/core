# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Providers
    class HetznerClientTest < Minitest::Test
      def setup
        super
        WebMock.reset!
        @client = Hetzner::Client.new(api_key: "test-hetzner-key")
      end

      def test_find_server_returns_nil
        stub_request(:get, %r{api\.hetzner\.cloud/v1/servers}).to_return(
          status: 200, body: { servers: [] }.to_json, headers: json_headers
        )

        assert_nil @client.find_server("nonexistent")
      end

      def test_find_server_returns_server
        stub_request(:get, %r{api\.hetzner\.cloud/v1/servers}).to_return(
          status: 200, body: { servers: [ hetzner_server_data ] }.to_json, headers: json_headers
        )
        server = @client.find_server("test-server")

        assert_equal "123", server.id
        assert_equal "1.2.3.4", server.public_ipv4
      end

      def test_find_or_create_server_returns_existing
        stub_request(:get, %r{/servers}).to_return(
          status: 200, body: { servers: [ hetzner_server_data ] }.to_json, headers: json_headers
        )
        server = @client.find_or_create_server(name: "test-server", server_type: "cpx11", image: "ubuntu-22.04",
                                               location: "ash")

        assert_equal "123", server.id
      end

      def test_find_or_create_server_creates_when_not_found
        stub_request(:get, %r{/servers}).to_return(
          status: 200, body: { servers: [] }.to_json, headers: json_headers
        )
        stub_request(:post, %r{/servers}).to_return(
          status: 201, body: { server: hetzner_server_data }.to_json, headers: json_headers
        )
        server = @client.find_or_create_server(name: "new", server_type: "cpx11", image: "ubuntu-22.04",
                                               location: "ash")

        assert_equal "123", server.id
      end

      def test_find_or_create_firewall_returns_existing
        stub_request(:get, %r{/firewalls}).to_return(
          status: 200, body: { firewalls: [ { id: 1, name: "fw" } ] }.to_json, headers: json_headers
        )
        fw = @client.find_or_create_firewall("fw")

        assert_equal "1", fw.id
      end

      def test_find_or_create_network_returns_existing
        stub_request(:get, %r{/networks}).to_return(
          status: 200, body: { networks: [ { id: 1, name: "net",
                                            ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers
        )
        net = @client.find_or_create_network("net", location: "ash")

        assert_equal "1", net.id
      end

      def test_find_volume_returns_nil
        stub_request(:get, %r{/volumes}).to_return(
          status: 200, body: { volumes: [] }.to_json, headers: json_headers
        )

        assert_nil @client.find_volume("nonexistent")
      end

      def test_find_or_create_volume_creates_when_not_found
        stub_request(:get, %r{/volumes}).to_return(
          status: 200, body: { volumes: [] }.to_json, headers: json_headers
        )
        stub_request(:post, %r{/volumes}).to_return(
          status: 201, body: { volume: { id: 1, name: "vol", size: 20, linux_device: "/dev/sda", format: "xfs",
                                         status: "available", server: nil, location: { name: "ash" } } }.to_json, headers: json_headers
        )
        vol = @client.find_or_create_volume(name: "vol", size: 20, location: "ash")

        assert_equal "1", vol.id
      end

      def test_find_or_create_ssh_key_returns_existing
        stub_request(:get, %r{/ssh_keys}).to_return(
          status: 200, body: { ssh_keys: [ { id: 1, name: "key",
                                            fingerprint: "aa:bb" } ] }.to_json, headers: json_headers
        )
        key = @client.find_or_create_ssh_key(name: "key", public_key: "ssh-rsa AAAA...")

        assert_equal "1", key.id
      end

      private

        def hetzner_server_data
          { "id" => 123, "name" => "test-server", "status" => "running",
            "public_net" => { "ipv4" => { "ip" => "1.2.3.4" } },
            "server_type" => { "name" => "cpx11" },
            "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } },
            "labels" => {} }
        end
    end
  end
end
