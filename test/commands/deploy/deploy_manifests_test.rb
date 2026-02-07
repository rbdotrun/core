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
          cmds = with_capturing_ssh do
            DeployManifests.new(@ctx, logger: TestLogger.new).run
          end

          assert(cmds.any? { |cmd| cmd.include?("kubectl") && cmd.include?("apply") })
        end

        def test_waits_for_rollout_of_configured_resources
          @ctx.config.database(:postgres)
          @ctx.config.app { |a| a.process(:web) { |p| p.port = 3000 } }

          stub_cloudflare_token_verify

          cmds = with_capturing_ssh do
            Clients::CloudflareR2.stub(:new, mock_r2_client) do
              DeployManifests.new(@ctx, logger: TestLogger.new).run
            end
          end

          assert(cmds.any? { |cmd| cmd.include?("rollout status") })
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
