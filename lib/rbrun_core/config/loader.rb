# frozen_string_literal: true

module RbrunCore
  module Config
    class Loader
      ALLOWED_DATABASE_TYPES = %i[postgres sqlite].freeze

      class << self
        def load(path, env: ENV)
          yaml = File.read(path)
          raw = YAML.safe_load(yaml, permitted_classes: [ Symbol ]) || {}
          data = interpolate_env(raw, env)

          build_configuration(data)
        end

        private

          def interpolate_env(obj, env)
            case obj
            when Hash
              obj.transform_values { |v| interpolate_env(v, env) }
            when Array
              obj.map { |v| interpolate_env(v, env) }
            when String
              obj.gsub(/\$\{([^}]+)\}/) { env.fetch(Regexp.last_match(1)) }
            else
              obj
            end
          end

          def build_configuration(data)
            config = Configuration.new
            raise Error::Configuration, "target is required (e.g., target: production)" unless data["target"]
            config.target = data["target"].to_sym
            config.name = data["name"]

            apply_compute!(config, data["compute"]) if data["compute"]
            apply_cloudflare!(config, data["cloudflare"]) if data["cloudflare"]
            apply_storage!(config, data["storage"]) if data["storage"]
            apply_claude!(config, data["claude"]) if data["claude"]
            apply_databases!(config, data["databases"]) if data["databases"]
            apply_services!(config, data["services"]) if data["services"]
            apply_app!(config, data["app"]) if data["app"]
            apply_env!(config, data["env"]) if data["env"]
            validate_runs_on!(config)

            config
          end

          def apply_compute!(config, compute_data)
            provider = compute_data["provider"]&.to_sym
            raise Error::Configuration, "compute.provider is required" unless provider

            config.compute(provider) do |c|
              # Common fields
              c.location = compute_data["location"] if compute_data["location"]
              c.image = compute_data["image"] if compute_data["image"]
              c.ssh_key_path = compute_data["ssh_key_path"] if compute_data["ssh_key_path"]

              # Provider-specific credentials
              case provider
              when :hetzner
                c.api_key = compute_data["api_key"]
              when :scaleway
                c.api_key = compute_data["api_key"]
                c.project_id = compute_data["project_id"] if compute_data["project_id"]
                c.zone = compute_data["zone"] if compute_data["zone"]
              when :aws
                c.access_key_id = compute_data["access_key_id"]
                c.secret_access_key = compute_data["secret_access_key"]
                c.region = compute_data["region"] if compute_data["region"]
              end

              # Master config (required)
              if compute_data["master"]
                c.master.instance_type = compute_data.dig("master", "instance_type") || compute_data.dig("master", "type")
                c.master.count = compute_data.dig("master", "count") || 1
              else
                raise Error::Configuration, "compute.master is required"
              end

              # Optional additional server groups
              if compute_data["servers"]
                compute_data["servers"].each do |group_name, group_data|
                  c.add_server_group(group_name, type: group_data["type"], count: group_data["count"] || 1)
                end
              end
            end
          end

          def apply_cloudflare!(config, cf_data)
            config.cloudflare do |cf|
              cf.api_token = cf_data["api_token"]
              cf.account_id = cf_data["account_id"]
              cf.domain = cf_data["domain"]
            end
          end

          def apply_storage!(config, storage_data)
            storage_data.each do |bucket_name, bucket_data|
              bucket_data ||= {}
              config.storage do |s|
                s.bucket(bucket_name) do |b|
                  b.public = bucket_data["public"] == true
                  b.cors = parse_cors(bucket_data["cors"])
                end
              end
            end
          end

          def parse_cors(cors_value)
            case cors_value
            when true
              true
            when Hash
              {
                origins: cors_value["origins"] || [],
                methods: cors_value["methods"]
              }.compact
            else
              nil
            end
          end

          def apply_claude!(config, claude_data)
            config.claude do |c|
              c.auth_token = claude_data["auth_token"]
            end
          end

          def apply_databases!(config, dbs_data)
            dbs_data.each do |type_str, db_data|
              type = type_str.to_sym
              unless ALLOWED_DATABASE_TYPES.include?(type)
                raise Error::Configuration, "Unsupported database type: #{type_str} (use: #{ALLOWED_DATABASE_TYPES.join(', ')})"
              end

              config.database(type) do |db|
                db.image = db_data["image"] if db_data&.dig("image")
                # Note: runs_on is no longer supported for databases - they always run on master
              end
            end
          end

          def apply_services!(config, svcs_data)
            svcs_data.each do |name_str, svc_data|
              svc_data ||= {}
              raise Error::Configuration, "service(:#{name_str}) requires an image" unless svc_data["image"]

              config.service(name_str) do |s|
                s.image = svc_data["image"]
                s.port = svc_data["port"] if svc_data["port"]
                s.mount_path = svc_data["mount_path"] if svc_data["mount_path"]
                s.subdomain = svc_data["subdomain"] if svc_data["subdomain"]
                s.runs_on = svc_data["runs_on"]&.to_sym if svc_data["runs_on"]
                s.setup = svc_data["setup"] || []
                if svc_data["env"]
                  s.env = svc_data["env"].transform_keys(&:to_sym)
                end
              end
            end
          end

          def apply_app!(config, app_data)
            config.app do |a|
              a.dockerfile = app_data["dockerfile"] if app_data["dockerfile"]

              app_data["processes"]&.each do |name_str, proc_data|
                a.process(name_str) do |p|
                  p.command = proc_data["command"] if proc_data["command"]
                  p.port = proc_data["port"] if proc_data["port"]
                  p.subdomain = proc_data["subdomain"] if proc_data["subdomain"]
                  p.replicas = proc_data["replicas"] if proc_data["replicas"]
                  p.env = proc_data["env"] if proc_data["env"]
                  p.setup = proc_data["setup"] || []
                  if proc_data["runs_on"]
                    p.runs_on = Array(proc_data["runs_on"]).map(&:to_sym)
                  end
                end
              end
            end
          end

          def apply_env!(config, env_data)
            config.env(env_data.transform_keys(&:to_sym))
          end

          def validate_runs_on!(config)
            # Sandbox mode cannot use runs_on - sandboxes are single-server by design
            if config.target == :sandbox
              config.service_configs.each do |name, svc|
                if svc.runs_on
                  raise Error::Configuration, "runs_on is not supported in sandbox mode (service: #{name})"
                end
              end

              config.app_config&.processes&.each do |name, proc|
                if proc.runs_on
                  raise Error::Configuration, "runs_on is not supported in sandbox mode (process: #{name})"
                end
              end
              return
            end

            # runs_on is only valid with additional server groups
            return if config.compute_config&.respond_to?(:multi_server?) && config.compute_config.multi_server?

            config.service_configs.each do |name, svc|
              if svc.runs_on
                raise Error::Configuration, "runs_on is only valid with multi-server mode (service: #{name})"
              end
            end

            config.app_config&.processes&.each do |name, proc|
              if proc.runs_on
                raise Error::Configuration, "runs_on is only valid with multi-server mode (process: #{name})"
              end
            end
          end
      end
    end
  end
end
