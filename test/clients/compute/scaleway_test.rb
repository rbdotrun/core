# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Clients
    module Compute
      class ScalewayTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @api_key = "test-scaleway-key"
          @project_id = "test-project-id"
          @zone = "fr-par-1"
          @client = Scaleway.new(api_key: @api_key, project_id: @project_id, zone: @zone)
        end

        def test_raises_without_api_key
          assert_raises(RbrunCore::Error::Standard) { Scaleway.new(api_key: nil, project_id: @project_id) }
        end

        def test_raises_without_project_id
          assert_raises(RbrunCore::Error::Standard) { Scaleway.new(api_key: @api_key, project_id: nil) }
        end

        def test_find_server_returns_nil
          stub_servers_list([])

          assert_nil @client.find_server("nonexistent")
        end

        def test_find_server_returns_server
          stub_servers_list([ server_data ])
          server = @client.find_server("test-server")

          assert_equal "server-123", server.id
          assert_equal "1.2.3.4", server.public_ipv4
        end

        def test_find_or_create_firewall_creates_when_not_found
          stub_security_groups_list([])
          stub_request(:post, /security_groups/)
            .to_return(status: 201, body: { security_group: security_group_data }.to_json, headers: json_headers)
          stub_request(:post, /security_groups\/sg-123\/rules/)
            .to_return(status: 201, body: { rule: {} }.to_json, headers: json_headers)

          rules = [ { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0" ] } ]
          fw = @client.find_or_create_firewall("new-fw", rules:)

          assert_equal "sg-123", fw.id
        end

        def test_find_or_create_network_creates_when_not_found
          stub_networks_list([])
          stub_request(:post, %r{/private-networks})
            .to_return(status: 201, body: network_data.to_json, headers: json_headers)

          network = @client.find_or_create_network("test-net", location: "fr-par-1")

          assert_equal "net-123", network.id
        end

        def test_find_network_returns_nil_when_not_found
          stub_networks_list([])

          assert_nil @client.find_network("nonexistent")
        end

        def test_find_network_returns_network
          stub_networks_list([ network_data ])

          network = @client.find_network("test-network")

          assert_equal "net-123", network.id
          assert_equal "test-network", network.name
        end

        def test_validate_credentials_returns_true
          stub_servers_list([])

          assert @client.validate_credentials
        end

        def test_validate_credentials_raises_on_unauthorized
          stub_request(:get, %r{/servers}).to_return(status: 401, body: { message: "unauthorized" }.to_json,
                                                     headers: json_headers)
          assert_raises(RbrunCore::Error::Standard) { @client.validate_credentials }
        end

        # find_or_create_server creation path test
        def test_find_or_create_server_creates_when_not_found
          stub_servers_list([])
          stub_resolve_image
          stub_create_server
          stub_server_action("poweron")
          stub_get_server(server_data)
          server = @client.find_or_create_server(
            name: "new-server", instance_type: "DEV1-S", image: "ubuntu_jammy"
          )

          assert_equal "server-123", server.id
        end

        # get_server tests
        def test_get_server_returns_server
          stub_get_server(server_data)
          server = @client.get_server("server-123")

          assert_equal "server-123", server.id
          assert_equal "1.2.3.4", server.public_ipv4
        end

        def test_get_server_returns_nil_when_not_found
          stub_get_server_not_found
          server = @client.get_server("nonexistent")

          assert_nil server
        end

        # list_servers test
        def test_list_servers_returns_servers
          stub_servers_list([ server_data, server_data(id: "server-456", name: "test-server-2") ])
          servers = @client.list_servers

          assert_equal 2, servers.size
          assert_equal "server-123", servers[0].id
          assert_equal "server-456", servers[1].id
        end

        # delete_server tests
        def test_delete_server_terminates_running_server_and_waits
          stub_list_private_nics
          stub_server_action("terminate")
          # First call returns running server, second call returns 404 (deleted)
          stub_request(:get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/server-123")
            .to_return(status: 200, body: { server: server_data(state: "running") }.to_json, headers: json_headers)
            .then.to_return(status: 404, body: { message: "not found" }.to_json, headers: json_headers)

          @client.delete_server("server-123")

          assert_requested :post, %r{/servers/server-123/action}
          # Verify it polls for deletion (get_server called twice: once to check state, once to verify deleted)
          assert_requested :get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/server-123", times: 2
        end

        def test_delete_server_deletes_stopped_server_and_waits
          stub_list_private_nics
          stub_delete_server
          # First call returns stopped server, second call returns 404 (deleted)
          stub_request(:get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/server-123")
            .to_return(status: 200, body: { server: server_data(state: "stopped") }.to_json, headers: json_headers)
            .then.to_return(status: 404, body: { message: "not found" }.to_json, headers: json_headers)

          @client.delete_server("server-123")

          assert_requested :delete, %r{/servers/server-123$}
          # Verify it polls for deletion
          assert_requested :get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/server-123", times: 2
        end

        def test_delete_server_returns_nil_when_not_found
          stub_list_private_nics
          stub_request(:get, %r{/servers/server-123})
            .to_return(status: 404, body: { message: "not found" }.to_json, headers: json_headers)

          result = @client.delete_server("server-123")

          assert_nil result
        end

        # delete_firewall tests
        def test_delete_firewall_removes_security_group
          stub_delete_security_group
          @client.delete_firewall("sg-123")

          assert_requested :delete, %r{/security_groups/sg-123}
        end

        def test_delete_firewall_returns_nil_when_not_found
          stub_delete_security_group_not_found
          result = @client.delete_firewall("sg-nonexistent")

          assert_nil result
        end

        # delete_network tests
        def test_delete_network_removes_private_network
          stub_delete_network
          @client.delete_network("net-123")

          assert_requested :delete, %r{/private-networks/net-123}
        end

        def test_delete_network_returns_nil_when_not_found
          stub_delete_network_not_found
          result = @client.delete_network("net-nonexistent")

          assert_nil result
        end

        private

          def stub_servers_list(servers)
            stub_request(:get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers")
              .with(query: hash_including("project" => @project_id))
              .to_return(status: 200, body: { servers: }.to_json, headers: json_headers)
          end

          def stub_security_groups_list(groups)
            stub_request(:get, /security_groups/)
              .with(query: hash_including("project" => @project_id))
              .to_return(status: 200, body: { security_groups: groups }.to_json, headers: json_headers)
          end

          def stub_networks_list(networks)
            stub_request(:get, %r{/private-networks})
              .with(query: hash_including("project_id" => @project_id))
              .to_return(status: 200, body: { private_networks: networks }.to_json, headers: json_headers)
          end

          def server_data(id: "server-123", name: "test-server", state: "running")
            { "id" => id, "name" => name, "state" => state, "public_ip" => { "address" => "1.2.3.4" },
              "private_ip" => "10.0.0.1", "commercial_type" => "DEV1-S",
              "image" => { "name" => "Ubuntu 22.04" }, "zone" => "fr-par-1",
              "tags" => [], "creation_date" => "2024-01-01T00:00:00Z", "volumes" => {} }
          end

          def security_group_data(id: "sg-123", name: "test-sg")
            { "id" => id, "name" => name, "inbound_default_policy" => "drop",
              "outbound_default_policy" => "accept", "servers" => [] }
          end

          def network_data(id: "net-123", name: "test-network")
            { "id" => id, "name" => name, "subnets" => [ { "subnet" => "10.0.0.0/24" } ],
              "region" => "fr-par", "created_at" => "2024-01-01T00:00:00Z" }
          end

          # New stubs for additional tests

          def stub_resolve_image
            stub_request(:get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/images")
              .with(query: hash_including("arch" => "x86_64", "name" => "ubuntu_jammy"))
              .to_return(status: 200, body: { images: [ { "id" => "img-123" } ] }.to_json, headers: json_headers)
          end

          def stub_create_server
            stub_request(:post, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers")
              .to_return(status: 201, body: { server: server_data }.to_json, headers: json_headers)
          end

          def stub_server_action(action)
            stub_request(:post, %r{/servers/server-123/action})
              .with(body: hash_including("action" => action))
              .to_return(status: 202, body: { task: { id: "task-123" } }.to_json, headers: json_headers)
          end

          def stub_list_private_nics
            stub_request(:get, %r{/servers/server-123/private_nics})
              .to_return(status: 200, body: { private_nics: [] }.to_json, headers: json_headers)
          end

          def stub_get_server(data)
            stub_request(:get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/server-123")
              .to_return(status: 200, body: { server: data }.to_json, headers: json_headers)
          end

          def stub_get_server_not_found
            stub_request(:get, %r{/servers/nonexistent})
              .to_return(status: 404, body: { message: "not found" }.to_json, headers: json_headers)
          end

          def stub_get_server_stopped
            stub_request(:get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/server-123")
              .to_return(status: 200, body: { server: server_data(state: "stopped") }.to_json, headers: json_headers)
          end

          def stub_get_server_for_volumes
            stub_request(:get, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/server-123")
              .to_return(status: 200, body: {
                server: server_data(state: "stopped").merge("volumes" => { "0" => { "id" => "vol-123" } })
              }.to_json, headers: json_headers)
          end

          def stub_delete_server
            stub_request(:delete, %r{/servers/server-123})
              .to_return(status: 204, body: nil)
          end

          def stub_delete_volume
            stub_request(:delete, %r{/volumes/vol-123})
              .to_return(status: 204, body: nil)
          end

          def stub_delete_security_group
            stub_request(:delete, %r{/security_groups/sg-123})
              .to_return(status: 204, body: nil)
          end

          def stub_delete_security_group_not_found
            stub_request(:delete, %r{/security_groups/sg-nonexistent})
              .to_return(status: 404, body: { message: "not found" }.to_json, headers: json_headers)
          end

          def stub_delete_network
            stub_request(:delete, %r{/private-networks/net-123})
              .to_return(status: 204, body: nil)
          end

          def stub_delete_network_not_found
            stub_request(:delete, %r{/private-networks/net-nonexistent})
              .to_return(status: 404, body: { message: "not found" }.to_json, headers: json_headers)
          end

          def stub_wait_for_server_deletion
            # After terminate/delete, the server should return 404 to indicate it's gone
            stub_request(:get, %r{/servers/server-123})
              .to_return(status: 404, body: { message: "not found" }.to_json, headers: json_headers)
          end

          def stub_products_servers(servers = { "DEV1-S" => { "ram" => 2_147_483_648 } })
            stub_request(:get, %r{/products/servers})
              .to_return(status: 200, body: { servers: }.to_json, headers: json_headers)
          end
      end

      class ScalewayServerTypeTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @client = Scaleway.new(api_key: "test-key", project_id: "test-project", zone: "fr-par-1")
        end

        def test_server_type_memory_mb_returns_memory
          stub_request(:get, %r{/products/servers})
            .to_return(status: 200, body: { servers: { "DEV1-S" => { "ram" => 2_147_483_648 } } }.to_json,
                       headers: { "Content-Type" => "application/json" })

          result = @client.server_type_memory_mb("DEV1-S")

          assert_equal 2048, result
        end

        def test_server_type_memory_mb_raises_for_unknown_type
          stub_request(:get, %r{/products/servers})
            .to_return(status: 200, body: { servers: {} }.to_json,
                       headers: { "Content-Type" => "application/json" })

          assert_raises(RbrunCore::Error::Configuration) do
            @client.server_type_memory_mb("UNKNOWN")
          end
        end
      end
    end
  end
end
