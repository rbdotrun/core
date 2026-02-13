# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    class Deploy
      class SetupBuilderTest < Minitest::Test
        MockServer = Struct.new(:id, :public_ipv4, :private_ipv4, :status, keyword_init: true)
        MockVolume = Struct.new(:id, :status, keyword_init: true)
        MockImage = Struct.new(:id, :status, keyword_init: true)
        MockFirewall = Struct.new(:id, keyword_init: true)
        MockNetwork = Struct.new(:id, keyword_init: true)

        def setup
          super
          @ctx = build_context(target: :production, branch: "main")
          @ctx.server_ip = "1.2.3.4"
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
          @ctx.config.builder { |b| b.enabled = true }
        end

        def test_returns_nil_when_builder_not_enabled
          @ctx.config.builder { |b| b.enabled = false }
          step = SetupBuilder.new(@ctx)

          result = step.run

          assert_nil result
        end

        def test_returns_builder_context_when_enabled
          with_stubbed_context do |step|
            result = step.run

            assert_kind_of SetupBuilder::BuilderContext, result
          end
        end

        def test_builder_context_has_server
          with_stubbed_context do |step|
            result = step.run

            refute_nil result.server
          end
        end

        def test_builder_context_has_volume
          with_stubbed_context do |step|
            result = step.run

            refute_nil result.volume
          end
        end

        def test_builder_context_has_ssh_client
          with_stubbed_context do |step|
            result = step.run

            refute_nil result.ssh_client
          end
        end

        def test_builder_context_has_master_private_ip
          with_stubbed_context do |step|
            result = step.run

            refute_nil result.master_private_ip
          end
        end

        def test_reports_builder_step
          steps = TestStepCollector.new

          with_stubbed_context(on_step: steps) do |step|
            step.run
          end

          assert_includes steps, "Builder"
          assert_includes steps.done_steps, "Builder"
        end

        def test_cleanup_destroys_server
          builder_context = SetupBuilder::BuilderContext.new(
            server: MockServer.new(id: "123"),
            volume: MockVolume.new(id: "456"),
            ssh_client: MockSshClient.new(host: "10.0.0.2", private_key: TEST_SSH_KEY.private_key),
            master_private_ip: "10.0.0.1"
          )

          compute_client = MockComputeClient.new
          @ctx.config.compute_config.stub(:client, compute_client) do
            step = SetupBuilder.new(@ctx)
            step.cleanup(builder_context)

            assert_includes compute_client.deleted_servers, "123"
          end
        end

        def test_cleanup_detaches_volume
          builder_context = SetupBuilder::BuilderContext.new(
            server: MockServer.new(id: "123"),
            volume: MockVolume.new(id: "456"),
            ssh_client: MockSshClient.new(host: "10.0.0.2", private_key: TEST_SSH_KEY.private_key),
            master_private_ip: "10.0.0.1"
          )

          compute_client = MockComputeClient.new
          @ctx.config.compute_config.stub(:client, compute_client) do
            step = SetupBuilder.new(@ctx)
            step.cleanup(builder_context)

            assert_includes compute_client.detached_volumes, "456"
          end
        end

        def test_cleanup_does_nothing_when_no_context
          step = SetupBuilder.new(@ctx)

          # Should not raise
          step.cleanup(nil)
        end

        def test_cleanup_reports_step
          builder_context = SetupBuilder::BuilderContext.new(
            server: MockServer.new(id: "123"),
            volume: MockVolume.new(id: "456"),
            ssh_client: MockSshClient.new(host: "10.0.0.2", private_key: TEST_SSH_KEY.private_key),
            master_private_ip: "10.0.0.1"
          )

          steps = TestStepCollector.new
          compute_client = MockComputeClient.new
          @ctx.config.compute_config.stub(:client, compute_client) do
            step = SetupBuilder.new(@ctx, on_step: steps)
            step.cleanup(builder_context)
          end

          assert_includes steps, "Builder cleanup"
        end

        private

          def with_stubbed_context(on_step: nil)
            compute_client = MockComputeClient.new
            master_ssh = MockSshClient.new(host: "1.2.3.4", private_key: TEST_SSH_KEY.private_key, output: "10.0.0.1")

            @ctx.config.compute_config.stub(:client, compute_client) do
              Clients::Ssh.stub(:new, ->(**opts) {
                if opts[:proxy]
                  # Builder SSH (via proxy)
                  MockSshClient.new(host: opts[:host], private_key: opts[:private_key], output: "ready")
                elsif opts[:host] == "1.2.3.4"
                  # Master SSH
                  master_ssh
                else
                  # Direct builder SSH (temp server with public IP)
                  MockSshClient.new(host: opts[:host], private_key: opts[:private_key], output: "ready")
                end
              }) do
                # Stub Net::SSH::Proxy::Jump
                Net::SSH::Proxy::Jump.stub(:new, ->(*args, **kwargs) { Object.new }) do
                  step = SetupBuilder.new(@ctx, on_step:)
                  yield step
                end
              end
            end
          end

          class MockComputeClient
            attr_reader :deleted_servers, :detached_volumes

            def initialize
              @deleted_servers = []
              @detached_volumes = []
              @servers = {}
            end

            def find_image(_name)
              nil
            end

            def find_firewall(_name)
              SetupBuilderTest::MockFirewall.new(id: "fw-1")
            end

            def find_network(_name)
              SetupBuilderTest::MockNetwork.new(id: "net-1")
            end

            def find_or_create_server(**opts)
              server = SetupBuilderTest::MockServer.new(
                id: "server-#{rand(1000)}",
                public_ipv4: opts[:public_ip] ? "1.2.3.#{rand(255)}" : nil,
                private_ipv4: "10.0.0.#{rand(255)}",
                status: "running"
              )
              @servers[server.id] = server
              server
            end

            def create_server(**opts)
              find_or_create_server(**opts)
            end

            def find_server(_name)
              nil
            end

            def wait_for_server(id, **_opts)
              @servers[id] || SetupBuilderTest::MockServer.new(id:, status: "running", private_ipv4: "10.0.0.2", public_ipv4: nil)
            end

            def delete_server(id)
              @deleted_servers << id
            end

            def find_or_create_volume(**_opts)
              SetupBuilderTest::MockVolume.new(id: "vol-#{rand(1000)}", status: "available")
            end

            def attach_volume(**_opts)
              true
            end

            def detach_volume(volume_id:)
              @detached_volumes << volume_id
            end

            def wait_for_device_path(_volume_id, _ssh_client)
              "/dev/sdb"
            end

            def create_image_from_server(**_opts)
              SetupBuilderTest::MockImage.new(id: "img-#{rand(1000)}", status: "available")
            end
          end
      end
    end
  end
end
