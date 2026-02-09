# frozen_string_literal: true

module RbrunCore
  module Commands
    module K3s
      # Naming conventions for K3s/Kubernetes resources.
      # Labels, deployment names, service URLs, database names, etc.
      module Naming
        # Kubernetes label keys
        LABEL_APP = "app.kubernetes.io/name"
        LABEL_INSTANCE = "app.kubernetes.io/instance"
        LABEL_MANAGED_BY = "app.kubernetes.io/managed-by"
        LABEL_SERVER_GROUP = "rb.run/server-group"

        # Backend bucket prefixes
        POSTGRES_BACKUPS_PREFIX = "postgres-backups/"
        DOCKER_REGISTRY_PREFIX = "docker-registry"

        class << self
          def deployment(prefix, name)
            "#{prefix}-#{name}"
          end

          def secret_for(name)
            "#{name}-secret"
          end

          def app_secret(prefix)
            "#{prefix}-app-secret"
          end

          def postgres(prefix)
            "#{prefix}-postgres"
          end

          def postgres_backup(prefix)
            "#{prefix}-postgres-backup"
          end

          def cloudflared(prefix)
            "#{prefix}-cloudflared"
          end

          def service_url(prefix, name, port, protocol: "http")
            "#{protocol}://#{prefix}-#{name}:#{port}"
          end

          def postgres_url(prefix, user, password, database)
            "postgresql://#{user}:#{password}@#{postgres(prefix)}:5432/#{database}"
          end

          def storage_env_prefix(bucket_name)
            "STORAGE_#{bucket_name.to_s.upcase}"
          end

          def service_env_var(name)
            "#{name.to_s.upcase}_URL"
          end

          def fqdn(subdomain, zone)
            "#{subdomain}.#{zone}"
          end

          def database_volume(prefix, type)
            "#{prefix}-#{type}-data"
          end

          def manual_job(cronjob_name)
            suffix = Time.now.to_i.to_s[-6..]
            base = cronjob_name.slice(0, 63 - 8)
            "#{base}-m#{suffix}"
          end
        end
      end
    end
  end
end
