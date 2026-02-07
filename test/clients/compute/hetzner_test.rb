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

        # delete_server tests
        def test_delete_server_detaches_and_waits_for_deletion
          # Server exists with no attachments
          stub_request(:get, %r{/servers/123$})
            .to_return(status: 200, body: { server: hetzner_server_data }.to_json, headers: json_headers)
            .then.to_return(status: 404, body: { error: { message: "not found" } }.to_json, headers: json_headers)
          stub_request(:get, %r{/firewalls$}).to_return(
            status: 200, body: { firewalls: [] }.to_json, headers: json_headers
          )
          stub_request(:delete, %r{/servers/123$}).to_return(status: 204)

          @client.delete_server(123)

          assert_requested :delete, %r{/servers/123}
          assert_requested :get, %r{/servers/123}, times: 2
        end

        def test_delete_server_detaches_from_firewall_before_deletion
          server_with_fw = hetzner_server_data
          fw_data = { id: 1, name: "fw", applied_to: [ { type: "server", server: { id: 123 } } ] }

          stub_request(:get, %r{/servers/123$})
            .to_return(status: 200, body: { server: server_with_fw }.to_json, headers: json_headers)
            .then.to_return(status: 404, body: { error: { message: "not found" } }.to_json, headers: json_headers)
          stub_request(:get, %r{/firewalls$}).to_return(
            status: 200, body: { firewalls: [ fw_data ] }.to_json, headers: json_headers
          )
          stub_request(:post, %r{/firewalls/1/actions/remove_from_resources}).to_return(
            status: 201, body: { actions: [ { id: 1, status: "running" } ] }.to_json, headers: json_headers
          )
          stub_request(:get, %r{/actions/1$}).to_return(
            status: 200, body: { action: { id: 1, status: "success" } }.to_json, headers: json_headers
          )
          stub_request(:delete, %r{/servers/123$}).to_return(status: 204)

          @client.delete_server(123)

          assert_requested :post, %r{/firewalls/1/actions/remove_from_resources}
          assert_requested :delete, %r{/servers/123}
        end

        def test_delete_server_detaches_from_network_before_deletion
          server_with_net = hetzner_server_data.merge("private_net" => [ { "network" => 5, "ip" => "10.0.0.2" } ])

          stub_request(:get, %r{/servers/123$})
            .to_return(status: 200, body: { server: server_with_net }.to_json, headers: json_headers)
            .then.to_return(status: 404, body: { error: { message: "not found" } }.to_json, headers: json_headers)
          stub_request(:get, %r{/firewalls$}).to_return(
            status: 200, body: { firewalls: [] }.to_json, headers: json_headers
          )
          stub_request(:post, %r{/servers/123/actions/detach_from_network}).to_return(
            status: 201, body: { action: { id: 2, status: "running" } }.to_json, headers: json_headers
          )
          stub_request(:get, %r{/actions/2$}).to_return(
            status: 200, body: { action: { id: 2, status: "success" } }.to_json, headers: json_headers
          )
          stub_request(:delete, %r{/servers/123$}).to_return(status: 204)

          @client.delete_server(123)

          assert_requested :post, %r{/servers/123/actions/detach_from_network}
          assert_requested :delete, %r{/servers/123}
        end

        def test_delete_server_returns_nil_when_not_found
          stub_request(:get, %r{/servers/999$}).to_return(
            status: 404, body: { error: { message: "not found" } }.to_json, headers: json_headers
          )

          result = @client.delete_server(999)

          assert_nil result
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
