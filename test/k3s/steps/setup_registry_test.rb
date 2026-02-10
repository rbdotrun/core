# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module K3s
    module Steps
      class SetupRegistryTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @ctx = build_context(target: :production)
          @ctx.server_ip = "1.2.3.4"
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        end

        def test_skips_when_cloudflare_not_configured
          config = RbrunCore::Configuration.new
          config.target = :production
          config.name = "testapp"
          config.compute(:hetzner) do |c|
            c.api_key = "k"
            c.ssh_key_path = TEST_SSH_KEY_PATH
          end
          ctx = RbrunCore::Context.new(config:)

          steps = TestStepCollector.new
          SetupRegistry.new(ctx, on_step: steps).run

          refute_includes steps, "Registry"
        end

        def test_reports_registry_step
          steps = TestStepCollector.new

          with_stubbed_registry do
            SetupRegistry.new(@ctx, on_step: steps).run
          end

          assert_includes steps, "Registry"
          assert_includes steps.done_steps, "Registry"
        end

        def test_ensures_bucket_exists
          bucket_created = false

          with_stubbed_registry(on_ensure_bucket: -> { bucket_created = true }) do
            SetupRegistry.new(@ctx).run
          end

          assert bucket_created
        end

        def test_merges_bucket_name_with_credentials
          captured_creds = nil

          with_stubbed_registry(on_generator: ->(creds) { captured_creds = creds }) do
            SetupRegistry.new(@ctx).run
          end

          assert_equal "testapp-production-backend", captured_creds[:bucket]
          assert_equal "access-key", captured_creds[:access_key_id]
          assert_equal "secret-key", captured_creds[:secret_access_key]
        end

        def test_applies_registry_manifest
          applied_manifest = nil

          with_stubbed_registry(on_apply: ->(m) { applied_manifest = m }) do
            SetupRegistry.new(@ctx).run
          end

          assert_equal "registry-manifest", applied_manifest
        end

        def test_waits_for_registry_to_be_ready
          poll_count = 0

          with_stubbed_registry(registry_ready_after: 2, on_poll: -> { poll_count += 1 }) do
            SetupRegistry.new(@ctx).run
          end

          assert_equal 2, poll_count
        end

        private

          def with_stubbed_registry(on_ensure_bucket: nil, on_apply: nil, on_generator: nil, registry_ready_after: 1, on_poll: nil)
            fake_r2 = Object.new
            fake_r2.define_singleton_method(:ensure_bucket) { |_| on_ensure_bucket&.call }
            fake_r2.define_singleton_method(:credentials) do
              { access_key_id: "access-key", secret_access_key: "secret-key", endpoint: "https://r2.example.com" }
            end

            generator_stub = ->(*_args, r2_credentials:, **_opts) {
              on_generator&.call(r2_credentials)
              mock_generator
            }

            Clients::CloudflareR2.stub(:new, fake_r2) do
              Generators.stub(:new, generator_stub) do
                with_fake_kubectl(on_apply:) do
                  with_fake_ssh(registry_ready_after:, on_poll:) do
                    yield
                  end
                end
              end
            end
          end

          def mock_generator
            gen = Object.new
            gen.define_singleton_method(:registry_manifest_yaml) { "registry-manifest" }
            gen
          end

          def with_fake_kubectl(on_apply: nil)
            fake_kubectl = Object.new
            fake_kubectl.define_singleton_method(:apply) { |m| on_apply&.call(m) }

            Clients::Kubectl.stub(:new, fake_kubectl) do
              yield
            end
          end

          def with_fake_ssh(registry_ready_after:, on_poll: nil)
            poll_count = 0

            fake_ssh = Object.new
            fake_ssh.define_singleton_method(:execute) do |_cmd, **_opts|
              poll_count += 1
              on_poll&.call
              ready = poll_count >= registry_ready_after
              { output: ready ? "ok" : "", exit_code: ready ? 0 : 1 }
            end

            @ctx.define_singleton_method(:ssh_client) { fake_ssh }

            # Stub sleep to speed up tests
            Waiter.stub(:sleep, ->(_) {}) do
              yield
            end
          end
      end
    end
  end
end
