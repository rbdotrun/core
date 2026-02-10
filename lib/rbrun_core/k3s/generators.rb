# frozen_string_literal: true

require "yaml"
require "base64"
require "shellwords"

module RbrunCore
  module K3s
    class Generators
      NAMESPACE = "default"

      include Primitives
      include Database
      include Services
      include App
      include Tunnel
      include Backup
      include Registry

      def initialize(config, prefix:, zone:, db_password: nil, registry_tag: nil, tunnel_token: nil, r2_credentials: nil,
                     storage_credentials: nil)
        @config = config
        @prefix = prefix
        @zone = zone
        @db_password = db_password || SecureRandom.hex(16)
        @registry_tag = registry_tag
        @tunnel_token = tunnel_token
        @r2_credentials = r2_credentials
        @storage_credentials = storage_credentials || {}
      end

      def generate
        manifests = []
        manifests << app_secret
        manifests.concat(database_manifests) if @config.database?
        manifests.concat(service_manifests) if @config.service?
        manifests.concat(app_manifests) if @config.app? && @registry_tag
        manifests << tunnel_manifest if @tunnel_token
        manifests.concat(backup_manifests) if @config.database?(:postgres) && @r2_credentials
        manifests.concat(registry_manifest) if @r2_credentials
        to_yaml(manifests)
      end

      def registry_manifest_yaml
        to_yaml(registry_manifest)
      end

      private

        def to_yaml(resources)
          Array(resources).compact.map { |r| YAML.dump(deep_stringify_keys(r)) }.join("\n---\n")
        end

        def deep_stringify_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify_keys(v) }
          when Array
            obj.map { |v| deep_stringify_keys(v) }
          else
            obj
          end
        end

        def app_secret
          env_data = {}

          @config.env_vars.each do |key, value|
            env_data[key.to_s] = value.to_s
          end

          if @config.database?(:postgres)
            pg = @config.database_configs[:postgres]
            pg_user = pg.username || "app"
            pg_db = pg.database || "app"
            env_data["DATABASE_URL"] = Naming.postgres_url(@prefix, pg_user, @db_password, pg_db)
            env_data["POSTGRES_HOST"] = Naming.postgres(@prefix)
            env_data["POSTGRES_USER"] = pg_user
            env_data["POSTGRES_PASSWORD"] = @db_password
            env_data["POSTGRES_DB"] = pg_db
            env_data["POSTGRES_PORT"] = "5432"
          end

          @config.service_configs.each do |name, svc_config|
            next unless svc_config.port

            protocol = name == :redis ? "redis" : "http"
            env_data[Naming.service_env_var(name)] = Naming.service_url(@prefix, name, svc_config.port, protocol:)
          end

          @storage_credentials.each do |bucket_name, creds|
            env_prefix = Naming.storage_env_prefix(bucket_name)
            env_data["#{env_prefix}_BUCKET"] = creds[:bucket]
            env_data["#{env_prefix}_ACCESS_KEY_ID"] = creds[:access_key_id]
            env_data["#{env_prefix}_SECRET_ACCESS_KEY"] = creds[:secret_access_key]
            env_data["#{env_prefix}_ENDPOINT"] = creds[:endpoint]
            env_data["#{env_prefix}_REGION"] = creds[:region]
          end

          secret(name: Naming.app_secret(@prefix), data: env_data)
        end
    end
  end
end
