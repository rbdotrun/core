# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      class DeployManifests
        HTTP_NODE_PORT = 30_080

        def initialize(ctx, on_step: nil, on_rollout_progress: nil)
          @ctx = ctx
          @on_step = on_step
          @on_rollout_progress = on_rollout_progress
        end

        def run
          @on_step&.call("Manifests", :in_progress)

          validate_no_volume_removal!

          r2_credentials = setup_backend_bucket
          storage_credentials = setup_storage_buckets

          generator = Generators::K3s.new(
            @ctx.config,
            prefix: @ctx.prefix,
            zone: @ctx.zone,
            db_password: resolve_db_password,
            registry_tag: @ctx.registry_tag,
            tunnel_token: @ctx.tunnel_token,
            r2_credentials:,
            storage_credentials:
          )

          kubectl.apply(generator.generate)
          @on_step&.call("Manifests", :done)

          @on_step&.call("Rollout", :in_progress)
          wait_for_rollout!
          @on_step&.call("Rollout", :done)
        end

        private

          def setup_backend_bucket
            return nil unless @ctx.config.cloudflare_configured?

            cf_config = @ctx.config.cloudflare_config
            r2 = Clients::CloudflareR2.new(api_token: cf_config.api_token, account_id: cf_config.account_id)

            bucket_name = Naming.backend_bucket(@ctx.config.name, @ctx.target)
            r2.ensure_bucket(bucket_name)

            r2.credentials.merge(bucket: bucket_name)
          end

          def setup_storage_buckets
            return {} unless @ctx.config.storage? && @ctx.config.cloudflare_configured?

            cf_config = @ctx.config.cloudflare_config
            r2 = Clients::CloudflareR2.new(api_token: cf_config.api_token, account_id: cf_config.account_id)
            base_credentials = r2.credentials
            inferred_origins = collect_inferred_cors_origins

            result = {}
            @ctx.config.storage_config.each do |name, bucket_config|
              bucket_name = Naming.storage_bucket(@ctx.config.name, @ctx.target, name)
              r2.ensure_bucket(bucket_name)

              if bucket_config.cors?
                cors_config = bucket_config.cors_config(inferred_origins:)
                r2.set_cors(bucket_name, cors_config)
              end

              result[name] = base_credentials.merge(bucket: bucket_name)
            end

            result
          end

          def collect_inferred_cors_origins
            return [] unless @ctx.config.cloudflare_configured?

            domain = @ctx.config.cloudflare_config.domain
            origins = []

            collect_process_origins(origins, domain)
            collect_service_origins(origins, domain)

            origins.uniq
          end

          def collect_process_origins(origins, domain)
            processes = @ctx.config.app_config&.processes
            return unless processes

            processes.each do |_name, process|
              origins << "https://#{process.subdomain}.#{domain}" if process.subdomain
            end
          end

          def collect_service_origins(origins, domain)
            @ctx.config.service_configs.each do |_name, service|
              origins << "https://#{service.subdomain}.#{domain}" if service.subdomain
            end
          end

          def resolve_db_password
            @ctx.db_password ||
              @ctx.config.database_configs[:postgres]&.password ||
              existing_db_password ||
              SecureRandom.hex(16)
          end

          def existing_db_password
            return nil unless @ctx.server_ip && @ctx.ssh_private_key

            cmd = [
              "kubectl", "get", "secret", "#{@ctx.prefix}-postgres-secret",
              "-o", "jsonpath='{.data.DB_PASSWORD}'",
              "2>/dev/null", "|", "base64", "-d"
            ].join(" ")

            result = @ctx.ssh_client.execute(cmd, raise_on_error: false)
            pw = result[:output].strip
            pw.empty? ? nil : pw
          rescue Clients::Ssh::Error
            nil
          end

          def validate_no_volume_removal!
            return unless @ctx.server_ip && @ctx.ssh_private_key

            existing_volumes = fetch_existing_volume_mounts
            return if existing_volumes.empty?

            configured_volumes = collect_configured_volume_mounts

            existing_volumes.each do |name, mount_path|
              next if configured_volumes[name]

              raise Error::Standard,
                    "Cannot remove volume from #{name}. " \
                    "It was deployed with mount_path: #{mount_path}. " \
                    "Removing volumes risks data loss. Use 'destroy' to fully remove."
            end
          end

          def fetch_existing_volume_mounts
            volumes = {}

            @ctx.config.service_configs.each_key do |name|
              deployment_name = Naming.deployment(@ctx.prefix, name)
              mount_path = kubectl.get_host_volume_mount(deployment_name)
              volumes[name.to_s] = mount_path if mount_path
            end

            volumes
          end

          def collect_configured_volume_mounts
            volumes = {}

            @ctx.config.service_configs.each do |name, svc|
              volumes[name.to_s] = svc.mount_path if svc.mount_path
            end

            volumes
          end

          def wait_for_rollout!
            deployments = collect_deployments
            return if deployments.empty?

            if @on_rollout_progress
              @on_rollout_progress.call(:wait, { kubectl:, deployments: })
            else
              deployments.each do |deployment|
                kubectl.rollout_status(deployment, timeout: 300)
              end
            end
          end

          def collect_deployments
            deployments = []

            @ctx.config.database_configs.each_key do |type|
              deployments << "#{@ctx.prefix}-#{type}"
            end

            @ctx.config.service_configs.each_key do |name|
              deployments << "#{@ctx.prefix}-#{name}"
            end

            if @ctx.config.app?
              @ctx.config.app_config.processes.each_key do |name|
                deployments << "#{@ctx.prefix}-#{name}"
              end
            end

            deployments
          end

          def kubectl
            @kubectl ||= Clients::Kubectl.new(@ctx.ssh_client)
          end
      end
    end
  end
end
