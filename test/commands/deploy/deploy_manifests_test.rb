# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    class Deploy
      class DeployManifestsTest < Minitest::Test
        def setup
          super
          @ctx = build_context(target: :production)
          @ctx.server_ip = "1.2.3.4"
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
          @ctx.registry_tag = "localhost:30500/app:v1"
        end

        def test_applies_generated_k3s_manifests_via_ssh_kubectl
          stub_cloudflare_token_verify

          cmds = with_capturing_ssh do
            Clients::CloudflareR2.stub(:new, mock_r2_client) do
              DeployManifests.new(@ctx).run
            end
          end

          assert(cmds.any? { |cmd| cmd.include?("kubectl") && cmd.include?("apply") })
        end

        def test_waits_for_rollout_of_configured_resources
          @ctx.config.database(:postgres)
          @ctx.config.app { |a| a.process(:web) { |p| p.port = 3000 } }

          stub_cloudflare_token_verify

          cmds = with_capturing_ssh do
            Clients::CloudflareR2.stub(:new, mock_r2_client) do
              DeployManifests.new(@ctx).run
            end
          end

          assert(cmds.any? { |cmd| cmd.include?("rollout status") })
        end

        def test_backend_bucket_uses_context_target_not_config_target
          # Build staging context - ctx.target should be :staging
          staging_ctx = build_context(target: :staging)
          staging_ctx.server_ip = "1.2.3.4"
          staging_ctx.ssh_private_key = TEST_SSH_KEY.private_key
          staging_ctx.registry_tag = "localhost:30500/app:v1"
          staging_ctx.config.database(:postgres)
          staging_ctx.config.app { |a| a.process(:web) { |p| p.port = 3000 } }

          # Config target might be nil but ctx.target should be :staging
          assert_equal :staging, staging_ctx.target

          captured_bucket = nil
          mock_client = Object.new
          mock_client.define_singleton_method(:ensure_bucket) { |name| captured_bucket = name }
          mock_client.define_singleton_method(:credentials) { { access_key_id: "k", secret_access_key: "s", endpoint: "https://x" } }

          stub_cloudflare_token_verify
          with_capturing_ssh do
            Clients::CloudflareR2.stub(:new, mock_client) do
              DeployManifests.new(staging_ctx).run
            end
          end

          assert_equal "testapp-staging-backend", captured_bucket, "Bucket should use staging target"
        end

        def test_staging_target_produces_staging_prefix
          staging_ctx = build_context(target: :staging)

          assert_equal :staging, staging_ctx.target
          assert_equal "testapp-staging", staging_ctx.prefix
        end

        private

          def mock_r2_client
            client = Minitest::Mock.new
            client.expect(:ensure_bucket, nil, [ String ])
            client.expect(:credentials, { access_key_id: "key", secret_access_key: "secret", endpoint: "https://test.r2.cloudflarestorage.com" })
            client
          end

          def stub_cloudflare_token_verify
            stub_request(:get, "https://api.cloudflare.com/client/v4/user/tokens/verify")
              .to_return(status: 200, body: { result: { id: "test-token-id" } }.to_json)
          end
      end
    end
  end
end
