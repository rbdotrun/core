# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      class DeployManifests
        HTTP_NODE_PORT = 30_080

        def initialize(ctx, logger: nil)
          @ctx = ctx
          @logger = logger
        end

        def run
          log("deploy_manifests", "Generating and applying K3s manifests")

          generator = Generators::K3s.new(
            @ctx.config,
            prefix: @ctx.prefix,
            zone: @ctx.zone,
            db_password: resolve_db_password,
            registry_tag: @ctx.registry_tag,
            tunnel_token: @ctx.tunnel_token
          )

          kubectl.apply(generator.generate)

          log("wait_rollout", "Waiting for rollout")
          wait_for_rollout!
        end

        private

          def resolve_db_password
            @ctx.db_password ||
              @ctx.config.database_configs[:postgres]&.password ||
              existing_db_password ||
              SecureRandom.hex(16)
          end

          def existing_db_password
            return nil unless @ctx.server_ip && @ctx.ssh_private_key

            result = @ctx.ssh_client.execute(
              "kubectl get secret #{@ctx.prefix}-postgres-secret -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d",
              raise_on_error: false
            )
            pw = result[:output].strip
            pw.empty? ? nil : pw
          rescue Clients::Ssh::Error
            nil
          end

          def wait_for_rollout!
            @ctx.config.database_configs.each_key do |type|
              kubectl.rollout_status("#{@ctx.prefix}-#{type}", timeout: 300)
            end

            @ctx.config.service_configs.each_key do |name|
              kubectl.rollout_status("#{@ctx.prefix}-#{name}", timeout: 120)
            end

            return unless @ctx.config.app?

            @ctx.config.app_config.processes.each_key do |name|
              kubectl.rollout_status("#{@ctx.prefix}-#{name}", timeout: 300)
            end
          end

          def kubectl
            @kubectl ||= Clients::Kubectl.new(@ctx.ssh_client)
          end

          def ssh_with_retry!(command, raise_on_error: true, timeout: 300)
            @ctx.ssh_client.execute_with_retry(command, raise_on_error:, timeout:)
          end

          def log(category, message = nil)
            @logger&.log(category, message)
          end
      end
    end
  end
end
