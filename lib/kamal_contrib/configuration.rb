# frozen_string_literal: true

module KamalContrib
  class Configuration
    attr_accessor :app_name, :domain, :region, :server_type, :server_count,
                  :db_enabled, :db_server_type, :lb_type,
                  :registry_server, :registry_username_env, :registry_password_env,
                  :cloudflare_zone

    def initialize
      @server_count = 2
      @server_type = "cpx21"
      @db_enabled = true
      @db_server_type = nil
      @lb_type = "lb11"
      @region = "ash"
      @registry_server = "ghcr.io"
      @registry_username_env = "KAMAL_REGISTRY_USERNAME"
      @registry_password_env = "KAMAL_REGISTRY_PASSWORD"
    end

    def self.from_file(path, env: ENV)
      yaml = YAML.safe_load(File.read(path), permitted_classes: [ Symbol ]) || {}
      from_hash(yaml, env:)
    end

    def self.from_hash(data, env: ENV)
      config = new
      config.app_name = data["app"]
      config.domain = data["domain"]
      config.region = data["region"] || "ash"
      config.server_count = data.dig("servers", "web") || 2
      config.db_enabled = data.dig("servers", "db") != false
      config.server_type = data.dig("servers", "type") || "cpx21"
      config.lb_type = data.dig("load_balancer", "type") || "lb11"
      config.cloudflare_zone = data.dig("cloudflare", "zone")

      if data["registry"]
        config.registry_server = data.dig("registry", "server") || "ghcr.io"
        config.registry_username_env = data.dig("registry", "username_env") || "KAMAL_REGISTRY_USERNAME"
        config.registry_password_env = data.dig("registry", "password_env") || "KAMAL_REGISTRY_PASSWORD"
      end

      config
    end

    # Build from an existing rbrun-core Configuration object.
    # Reads what it can, user overrides the rest via CLI options.
    def self.from_rbrun_config(rbrun_config, overrides: {})
      config = new
      config.app_name = overrides[:app] || rbrun_config.name
      config.domain = overrides[:domain]
      config.region = rbrun_config.compute_config&.location || "ash"
      config.server_count = overrides[:servers]&.to_i || 2
      config.cloudflare_zone = rbrun_config.cloudflare_config&.domain
      config
    end

    def validate!
      raise RbrunCore::Error::Configuration, "app name is required" unless app_name && !app_name.empty?
      raise RbrunCore::Error::Configuration, "domain is required" unless domain && !domain.empty?
    end

    def compute_client(api_key:)
      RbrunCore::Clients::Compute::Hetzner.new(api_key:)
    end

    def cloudflare_client(api_token:, account_id:)
      RbrunCore::Clients::Cloudflare.new(api_token:, account_id:)
    end

    def prefix
      "#{app_name}-kamal"
    end
  end
end
