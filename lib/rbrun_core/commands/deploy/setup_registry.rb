# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      class SetupRegistry
        include Stepable

        REGISTRY_PORT = 30_500
        REGISTRY_TIMEOUT = 60

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          return unless @ctx.config.cloudflare_configured?

          report_step(Step::Id::SETUP_REGISTRY, Step::IN_PROGRESS)

          r2_credentials = setup_backend_bucket
          return unless r2_credentials

          deploy_registry_manifest!(r2_credentials)
          wait_for_registry!

          report_step(Step::Id::SETUP_REGISTRY, Step::DONE)
        end

        private

          def setup_backend_bucket
            cf_config = @ctx.config.cloudflare_config
            r2 = Clients::CloudflareR2.new(api_token: cf_config.api_token, account_id: cf_config.account_id)

            bucket_name = Naming.backend_bucket(@ctx.config.name, @ctx.target)
            r2.ensure_bucket(bucket_name)

            r2.credentials.merge(bucket: bucket_name)
          end

          def deploy_registry_manifest!(r2_credentials)
            generator = Generators::K3s.new(
              @ctx.config,
              prefix: @ctx.prefix,
              zone: @ctx.zone,
              r2_credentials:
            )

            manifest = generator.registry_manifest_yaml
            kubectl.apply(manifest)
          end

          def wait_for_registry!
            Waiter.poll(max_attempts: REGISTRY_TIMEOUT, interval: 2, message: "Registry did not become ready") do
              exec = @ctx.ssh_client.execute(
                "curl -sf http://localhost:#{REGISTRY_PORT}/v2/ && echo ok",
                raise_on_error: false
              )
              exec[:output].include?("ok")
            end
          end

          def kubectl
            @kubectl ||= Clients::Kubectl.new(@ctx.ssh_client)
          end
      end
    end
  end
end
