# frozen_string_literal: true

require "yaml"
require "base64"
require "shellwords"

module RbrunCore
  module Generators
    class K3s
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
        @allocations = calculate_resource_allocations
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

        def calculate_resource_allocations
          workloads = build_workload_list
          return {} if workloads.empty?

          ResourceAllocator.new(
            node_groups: build_node_groups,
            workloads:
          ).allocate
        end

        def build_node_groups
          provider = @config.compute_config.provider_name
          groups = {
            master: InstanceTypes.memory_mb(provider, @config.compute_config.master.instance_type)
          }

          @config.compute_config.servers.each do |name, server_group|
            groups[name] = InstanceTypes.memory_mb(provider, server_group.type)
          end

          groups
        end

        def build_workload_list
          workloads = []

          workloads << ResourceAllocator::Workload.new(
            name: "registry",
            profile: :minimal,
            replicas: 1,
            runs_on: :master
          )

          workloads << ResourceAllocator::Workload.new(
            name: "tunnel",
            profile: :minimal,
            replicas: 1,
            runs_on: :master
          )

          @config.database_configs.each_key do |type|
            workloads << ResourceAllocator::Workload.new(
              name: type.to_s,
              profile: :large,
              replicas: 1,
              runs_on: :master
            )
          end

          @config.service_configs.each do |name, svc|
            workloads << ResourceAllocator::Workload.new(
              name: name.to_s,
              profile: ResourceAllocator.profile_for_service(svc),
              replicas: 1,
              runs_on: normalize_runs_on(svc.runs_on)
            )
          end

          @config.app_config&.processes&.each do |name, process|
            workloads << ResourceAllocator::Workload.new(
              name: name.to_s,
              profile: ResourceAllocator.profile_for_process(process),
              replicas: process.effective_replicas,
              runs_on: normalize_runs_on(process.runs_on)
            )
          end

          workloads
        end

        def normalize_runs_on(runs_on)
          return :master if runs_on.nil? || runs_on.empty?

          # If runs_on is an array, take the first element as the target group
          Array(runs_on).first
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
