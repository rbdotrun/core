# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Clients
    module Compute
      class HetznerTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @client = Hetzner.new(api_key: "test-hetzner-key")
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
          server = @client.find_or_create_server(name: "test-server", instance_type: "cpx11", image: "ubuntu-22.04",
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
          server = @client.find_or_create_server(name: "new", instance_type: "cpx11", image: "ubuntu-22.04",
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
end
