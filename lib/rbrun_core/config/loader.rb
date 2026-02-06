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
            config.target = data["target"]&.to_sym

            apply_compute!(config, data["compute"]) if data["compute"]
            apply_cloudflare!(config, data["cloudflare"]) if data["cloudflare"]
            apply_claude!(config, data["claude"]) if data["claude"]
            apply_databases!(config, data["databases"]) if data["databases"]
            apply_services!(config, data["services"]) if data["services"]
            apply_app!(config, data["app"]) if data["app"]
            apply_setup!(config, data["setup"]) if data["setup"]
            apply_env!(config, data["env"]) if data["env"]
            apply_git!(config)
            validate_runs_on!(config)

            config
          end

          def apply_compute!(config, compute_data)
            provider = compute_data["provider"]&.to_sym
            raise ConfigurationError, "compute.provider is required" unless provider

            config.compute(provider) do |c|
              c.api_key = compute_data["api_key"]
              c.location = compute_data["location"] if compute_data["location"]
              c.image = compute_data["image"] if compute_data["image"]
              c.ssh_key_path = compute_data["ssh_key_path"] if compute_data["ssh_key_path"]

              has_server = compute_data.key?("server")
              has_servers = compute_data.key?("servers")

              if has_server && has_servers
                raise ConfigurationError, "compute.server and compute.servers are mutually exclusive"
              end
              raise ConfigurationError, "compute.server or compute.servers is required" unless has_server || has_servers

              if has_server
                c.server = compute_data["server"]
              else
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

          def apply_claude!(config, claude_data)
            config.claude do |c|
              c.auth_token = claude_data["auth_token"]
            end
          end

          def apply_databases!(config, dbs_data)
            dbs_data.each do |type_str, db_data|
              type = type_str.to_sym
              unless ALLOWED_DATABASE_TYPES.include?(type)
                raise ConfigurationError, "Unsupported database type: #{type_str} (use: #{ALLOWED_DATABASE_TYPES.join(', ')})"
              end

              config.database(type) do |db|
                db.image = db_data["image"] if db_data&.dig("image")
                db.runs_on = db_data["runs_on"]&.to_sym if db_data&.dig("runs_on")
              end
            end
          end

          def apply_services!(config, svcs_data)
            svcs_data.each do |name_str, svc_data|
              svc_data ||= {}
              raise ConfigurationError, "service(:#{name_str}) requires an image" unless svc_data["image"]

              config.service(name_str) do |s|
                s.image = svc_data["image"]
                s.subdomain = svc_data["subdomain"] if svc_data["subdomain"]
                s.runs_on = svc_data["runs_on"]&.to_sym if svc_data["runs_on"]
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
                  if proc_data["runs_on"]
                    p.runs_on = Array(proc_data["runs_on"]).map(&:to_sym)
                  end
                end
              end
            end
          end

          def apply_setup!(config, setup_data)
            config.setup(*setup_data)
          end

          def apply_env!(config, env_data)
            config.env(env_data.transform_keys(&:to_sym))
          end

          def apply_git!(config)
            config.git do |g|
              g.repo = LocalGit.repo_from_remote
              g.pat = LocalGit.gh_auth_token
            end
          rescue RbrunCore::Error
            # git info is optional at config load time — may not be in a repo
          end

          def validate_runs_on!(config)
            return if config.compute_config&.respond_to?(:multi_server?) && config.compute_config.multi_server?

            config.database_configs.each do |type, db|
              if db.runs_on
                raise ConfigurationError, "runs_on is only valid with multi-server mode (database: #{type})"
              end
            end

            config.service_configs.each do |name, svc|
              if svc.runs_on
                raise ConfigurationError, "runs_on is only valid with multi-server mode (service: #{name})"
              end
            end

            config.app_config&.processes&.each do |name, proc|
              if proc.runs_on
                raise ConfigurationError, "runs_on is only valid with multi-server mode (process: #{name})"
              end
            end
          end
      end
    end
  end
end
