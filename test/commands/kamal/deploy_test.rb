# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    module Kamal
      class DeployTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @ctx = build_context(target: :production, branch: "main")
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
          @ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
          @ctx.source_folder = Dir.mktmpdir("kamal-test")
        end

        def teardown
          FileUtils.rm_rf(@ctx.source_folder) if @ctx.source_folder
          super
        end

        def test_initializes_with_context
          cmd = Deploy.new(@ctx)

          assert_kind_of Deploy, cmd
        end

        def test_prefix_uses_app_name_with_kamal_suffix
          cmd = Deploy.new(@ctx)
          assert_equal "testapp-kamal", cmd.send(:prefix)
        end

        def test_provisions_network_firewall_and_server
          stub_hetzner_infrastructure!

          cmd = Deploy.new(@ctx, on_step: TestStepCollector.new)
          cmd.stub(:configure_dns!, nil) do
            cmd.stub(:generate_config!, nil) do
              cmd.stub(:run_kamal_deploy!, nil) do
                cmd.run
              end
            end
          end

          assert_requested(:get, %r{hetzner\.cloud/v1/networks})
          assert_requested(:get, %r{hetzner\.cloud/v1/firewalls})
        end

        def test_single_server_skips_load_balancer
          stub_hetzner_infrastructure!

          cmd = Deploy.new(@ctx)
          lb_created = false

          cmd.stub(:configure_dns!, nil) do
            cmd.stub(:generate_config!, nil) do
              cmd.stub(:run_kamal_deploy!, nil) do
                cmd.stub(:create_load_balancer!, -> { lb_created = true }) do
                  cmd.run
                end
              end
            end
          end

          refute lb_created, "Load balancer should not be created for single-server mode"
        end

        def test_state_transitions_on_success
          stub_hetzner_infrastructure!
          states = []

          cmd = Deploy.new(@ctx, on_state_change: ->(s) { states << s })
          cmd.stub(:configure_dns!, nil) do
            cmd.stub(:generate_config!, nil) do
              cmd.stub(:run_kamal_deploy!, nil) do
                cmd.run
              end
            end
          end

          assert_equal [ :provisioning, :deploying, :deployed ], states
        end

        def test_state_becomes_failed_on_error
          states = []

          cmd = Deploy.new(@ctx, on_state_change: ->(s) { states << s })
          cmd.stub(:create_network!, -> { raise Error::Standard, "boom" }) do
            assert_raises(Error::Standard) { cmd.run }
          end

          assert_includes states, :failed
        end

        def test_on_step_fires_for_infrastructure
          stub_hetzner_infrastructure!
          steps = TestStepCollector.new

          cmd = Deploy.new(@ctx, on_step: steps)
          cmd.stub(:configure_dns!, nil) do
            cmd.stub(:generate_config!, nil) do
              cmd.stub(:run_kamal_deploy!, nil) do
                cmd.run
              end
            end
          end

          assert_includes steps, "Network"
          assert_includes steps, "Firewall"
          assert_includes steps, "Server"
        end

        def test_firewall_rules_include_http_and_https
          cmd = Deploy.new(@ctx)
          rules = cmd.send(:firewall_rules)

          ports = rules.map { |r| r[:port] }
          assert_includes ports, "443"
          assert_includes ports, "80"
          assert_includes ports, "22"
        end

        def test_config_builder_receives_correct_parameters
          stub_hetzner_infrastructure!
          captured = nil

          original_new = ConfigBuilder.method(:new)
          ConfigBuilder.stub(:new, ->(**args) {
            captured = args
            original_new.call(**args)
          }) do
            cmd = Deploy.new(@ctx)
            cmd.stub(:configure_dns!, nil) do
              cmd.stub(:run_kamal_deploy!, nil) do
                cmd.run
              end
            end
          end

          assert_equal "testapp", captured[:config].name
          assert_equal "test.dev", captured[:domain]
        end

        private

          def stub_hetzner_infrastructure!
            stub_request(:get, %r{hetzner\.cloud/v1/networks}).to_return(
              status: 200, body: { networks: [] }.to_json, headers: json_headers
            )
            stub_request(:post, %r{hetzner\.cloud/v1/networks}).to_return(
              status: 201, body: { network: { id: 1, name: "testapp-kamal", ip_range: "10.0.0.0/16" } }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/firewalls}).to_return(
              status: 200, body: { firewalls: [] }.to_json, headers: json_headers
            )
            stub_request(:post, %r{hetzner\.cloud/v1/firewalls}).to_return(
              status: 201, body: { firewall: { id: 2, name: "testapp-kamal" } }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/servers}).to_return(
              status: 200, body: { servers: [] }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/ssh_keys}).to_return(
              status: 200, body: { ssh_keys: [ { id: 1, name: "key", fingerprint: "aa" } ] }.to_json, headers: json_headers
            )
            stub_request(:post, %r{hetzner\.cloud/v1/servers}).to_return(
              status: 201, body: { server: kamal_server }.to_json, headers: json_headers
            )
          end

          def kamal_server
            { "id" => 100, "name" => "testapp-kamal-web-1", "status" => "running",
              "public_net" => { "ipv4" => { "ip" => "10.0.0.1" } },
              "private_net" => [ { "ip" => "10.0.1.1" } ],
              "server_type" => { "name" => "cpx21" },
              "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } },
              "labels" => { "purpose" => "kamal", "role" => "web" } }
          end
      end
    end
  end
end
