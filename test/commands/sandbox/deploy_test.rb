# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    module Sandbox
      class DeployTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @ctx = build_context(target: :sandbox, slug: "a1b2c3", branch: "main")
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
          @ctx.ssh_public_key = TEST_SSH_KEY.ssh_public_key
        end

        def test_initializes_with_sandbox_context
          cmd = Deploy.new(@ctx)

          assert_kind_of Deploy, cmd
        end

        def test_prefix_uses_naming_resource
          assert_equal "rbrun-sandbox-a1b2c3", @ctx.prefix
        end

        def test_run_reports_infrastructure_steps
          steps = run_and_collect_steps

          assert_includes steps, "Firewall"
          assert_includes steps, "Server"
        end

        def test_run_reports_application_steps
          steps = run_and_collect_steps

          assert_includes steps, "Packages"
          assert_includes steps, "Repo"
          assert_includes steps, "Compose"
        end

        def test_state_transitions
          stub_hetzner_sandbox!
          states = []

          with_mocked_ssh(output: "ok", exit_code: 0) do
            Deploy.new(@ctx, on_state_change: ->(state) { states << state }).run
          end

          assert_includes states, :provisioning
          assert_includes states, :running
        end

        def test_state_becomes_failed_on_error
          states = []
          boom = lambda { |*|
            o = Object.new
            o.define_singleton_method(:run) { raise RbrunCore::Error::Standard, "boom" }
            o
          }

          Shared::CreateInfrastructure.stub(:new, boom) do
            assert_raises(RbrunCore::Error::Standard) do
              Deploy.new(@ctx, on_state_change: ->(s) { states << s }).run
            end
          end

          assert_includes states, :failed
        end

        private

          def run_and_collect_steps
            stub_hetzner_sandbox!
            steps = TestStepCollector.new
            with_mocked_ssh(output: "ok", exit_code: 0) do
              Deploy.new(@ctx, on_step: steps).run
            end
            steps
          end

          def stub_hetzner_sandbox!
            stub_request(:get, %r{hetzner\.cloud/v1/firewalls}).to_return(
              status: 200, body: { firewalls: [ { id: 1, name: "rbrun-sandbox-a1b2c3" } ] }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/networks}).to_return(
              status: 200, body: { networks: [ { id: 1, name: "rbrun-sandbox-a1b2c3",
                                                ip_range: "10.0.0.0/16" } ] }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/servers}).to_return(
              status: 200, body: { servers: [ sandbox_server ] }.to_json, headers: json_headers
            )
            stub_request(:get, %r{hetzner\.cloud/v1/ssh_keys}).to_return(
              status: 200, body: { ssh_keys: [ { id: 1, name: "key",
                                                fingerprint: "aa:bb" } ] }.to_json, headers: json_headers
            )
          end

          def sandbox_server
            { "id" => 456, "name" => "rbrun-sandbox-a1b2c3", "status" => "running",
              "public_net" => { "ipv4" => { "ip" => "5.6.7.8" } },
              "server_type" => { "name" => "cpx11" },
              "datacenter" => { "name" => "ash-dc1", "location" => { "name" => "ash" } },
              "labels" => { "purpose" => "sandbox" } }
          end
      end
    end
  end
end
