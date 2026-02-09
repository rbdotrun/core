# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    module Kamal
      class DestroyTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @ctx = build_context(target: :production)
        end

        def test_initializes_with_context
          cmd = Destroy.new(@ctx)

          assert_kind_of Destroy, cmd
        end

        def test_deletes_servers_network_firewall
          server_data = { "id" => 1, "name" => "testapp-kamal-web-1", "status" => "running",
                          "public_net" => { "ipv4" => { "ip" => "10.0.0.1" } },
                          "server_type" => { "name" => "cpx21" },
                          "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } },
                          "labels" => {} }

          stub_request(:get, %r{hetzner\.cloud/v1/servers$}).to_return(
            status: 200, body: { servers: [ server_data ] }.to_json, headers: json_headers
          )
          stub_request(:get, %r{hetzner\.cloud/v1/servers/1$}).to_return(
            { status: 200, body: { server: server_data }.to_json, headers: json_headers },
            { status: 404, body: { error: { code: "not_found" } }.to_json, headers: json_headers }
          )
          stub_request(:delete, %r{servers/1}).to_return(status: 200, body: {}.to_json, headers: json_headers)
          stub_request(:get, %r{hetzner\.cloud/v1/networks}).to_return(
            status: 200, body: { networks: [ { id: 2, name: "testapp-kamal", ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers
          )
          stub_request(:delete, %r{networks/2}).to_return(status: 200, body: {}.to_json, headers: json_headers)
          stub_request(:get, %r{hetzner\.cloud/v1/firewalls}).to_return(
            status: 200, body: { firewalls: [ { id: 3, name: "testapp-kamal" } ] }.to_json, headers: json_headers
          )
          stub_request(:delete, %r{firewalls/3}).to_return(status: 200, body: {}.to_json, headers: json_headers)
          stub_request(:get, %r{hetzner\.cloud/v1/load_balancers}).to_return(
            status: 200, body: { load_balancers: [] }.to_json, headers: json_headers
          )

          Destroy.new(@ctx).run

          assert_requested(:delete, %r{servers/1})
          assert_requested(:delete, %r{networks/2})
          assert_requested(:delete, %r{firewalls/3})
        end

        def test_state_transitions
          stub_empty_infrastructure!
          states = []

          Destroy.new(@ctx, on_state_change: ->(s) { states << s }).run

          assert_equal [ :destroying, :destroyed ], states
        end

        def test_state_becomes_failed_on_error
          states = []

          cmd = Destroy.new(@ctx, on_state_change: ->(s) { states << s })
          cmd.stub(:delete_load_balancers!, -> { raise Error::Standard, "boom" }) do
            assert_raises(Error::Standard) { cmd.run }
          end

          assert_includes states, :failed
        end

        private

          def stub_empty_infrastructure!
            stub_request(:get, %r{hetzner\.cloud/v1/servers}).to_return(
              status: 200, body: { servers: [] }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/networks}).to_return(
              status: 200, body: { networks: [] }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/firewalls}).to_return(
              status: 200, body: { firewalls: [] }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/load_balancers}).to_return(
              status: 200, body: { load_balancers: [] }.to_json, headers: json_headers
            )
          end
      end
    end
  end
end
