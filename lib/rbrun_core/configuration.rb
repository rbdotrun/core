# frozen_string_literal: true

module RbrunCore
  class Configuration
    attr_reader :compute_config, :cloudflare_config, :git_config, :claude_config, :database_configs, :service_configs,
                :app_config, :storage_config, :setup_commands, :env_vars
    attr_accessor :websocket_url, :api_url

    def initialize
      @git_config = GitConfig.new
      @claude_config = ClaudeConfig.new
      @database_configs = {}
      @service_configs = {}
      @app_config = nil
      @storage_config = nil
      @setup_commands = []
      @env_vars = {}
    end

    # ─────────────────────────────────────────────────────────────
    # Compute Provider DSL
    # ─────────────────────────────────────────────────────────────

    def compute(provider, &)
      @compute_config = Providers::Registry.build(provider, &)
    end

    # ─────────────────────────────────────────────────────────────
    # Cloudflare DSL
    # ─────────────────────────────────────────────────────────────

    def cloudflare
      @cloudflare_config ||= Cloudflare::Config.new
      yield @cloudflare_config if block_given?
      @cloudflare_config
    end

    # ─────────────────────────────────────────────────────────────
    # Git & Claude DSL
    # ─────────────────────────────────────────────────────────────

    def git
      yield @git_config if block_given?
      @git_config
    end

    def claude
      yield @claude_config if block_given?
      @claude_config
    end

    # ─────────────────────────────────────────────────────────────
    # Unified Database DSL
    # ─────────────────────────────────────────────────────────────

    def database(type)
      config = DatabaseConfig.new(type)
      yield config if block_given?
      @database_configs[type.to_sym] = config
    end

    def database?(type = nil)
      type ? @database_configs.key?(type.to_sym) : @database_configs.any?
    end

    # ─────────────────────────────────────────────────────────────
    # Unified Service DSL
    # ─────────────────────────────────────────────────────────────

    def service(name)
      config = ServiceConfig.new(name)
      yield config if block_given?
      @service_configs[name.to_sym] = config
    end

    def service?(name = nil)
      name ? @service_configs.key?(name.to_sym) : @service_configs.any?
    end

    # ─────────────────────────────────────────────────────────────
    # Unified App DSL
    # ─────────────────────────────────────────────────────────────

    def app
      @app_config ||= AppConfig.new
      yield @app_config if block_given?
      @app_config
    end

    def app?
      @app_config&.processes&.any?
    end

    # ─────────────────────────────────────────────────────────────
    # Unified Storage DSL
    # ─────────────────────────────────────────────────────────────

    def storage
      @storage_config ||= StorageConfig.new
      yield @storage_config if block_given?
      @storage_config
    end

    def storage?
      @storage_config&.subdomain && !@storage_config.subdomain.empty?
    end

    # ─────────────────────────────────────────────────────────────
    # Setup & Environment DSL
    # ─────────────────────────────────────────────────────────────

    def setup(*commands)
      @setup_commands = commands.flatten
    end

    def env(vars = {})
      @env_vars = vars
    end

    # ─────────────────────────────────────────────────────────────
    # Value Resolution (handles { env1: x, env2: y } hash syntax)
    # ─────────────────────────────────────────────────────────────

    def resolve(value, target:)
      # If not a hash with symbol keys, return as-is
      return value unless value.is_a?(Hash) && value.keys.all?(Symbol)

      # Extract target key (returns nil if missing - validation catches required values)
      value[target.to_sym]
    end

    # ─────────────────────────────────────────────────────────────
    # Validation
    # ─────────────────────────────────────────────────────────────

    def validate!
      raise ConfigurationError, "Compute provider not configured" unless @compute_config

      @compute_config.validate!
      @cloudflare_config&.validate!
      @git_config.validate!
    end

    def validate_for_target!(target)
      errors = []

      if compute_config&.server_type.is_a?(Hash) && !compute_config.server_type.key?(target)
        errors << "compute.server_type missing key :#{target}"
      end

      env_vars.each do |key, value|
        if value.is_a?(Hash) && value.keys.all? { |k| k.is_a?(Symbol) } && !value.key?(target)
          errors << "env.#{key} missing key :#{target}"
        end
      end

      app_config&.processes&.each do |name, process|
        if process.subdomain.is_a?(Hash) && process.subdomain.keys.all?(Symbol) && !process.subdomain.key?(target)
          errors << "app.process(:#{name}).subdomain missing key :#{target}"
        end
      end

      service_configs.each do |name, svc_config|
        if svc_config.subdomain.is_a?(Hash) && svc_config.subdomain.keys.all?(Symbol) && !svc_config.subdomain.key?(target)
          errors << "service(:#{name}).subdomain missing key :#{target}"
        end
      end

      raise ConfigurationError, errors.join(", ") if errors.any?
    end

    def cloudflare_configured?
      @cloudflare_config&.configured? || false
    end

    def claude_configured?
      @claude_config&.configured? || false
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Unified Database Config
  # ─────────────────────────────────────────────────────────────

  class DatabaseConfig
    attr_accessor :volume_size, :password, :username, :database
    attr_reader :type, :backup_config
    attr_writer :image

    DEFAULT_IMAGES = {
      postgres: "postgres:16-alpine",
      sqlite: nil,
      redis: "redis:7-alpine"
    }.freeze

    def initialize(type)
      @type = type.to_sym
      @volume_size = "10Gi"
      @image = nil
      @password = nil
      @username = "app"
      @database = "app"
    end

    def backup
      @backup_config = BackupConfig.new
      yield @backup_config if block_given?
      @backup_config
    end

    def image
      @image || DEFAULT_IMAGES[@type]
    end
  end

  class BackupConfig
    attr_accessor :schedule, :retention

    def initialize
      @schedule = "@daily"
      @retention = 30
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Unified Service Config
  # ─────────────────────────────────────────────────────────────

  class ServiceConfig
    attr_accessor :subdomain, :env
    attr_reader :name

    DEFAULT_IMAGES = {
      redis: "redis:7-alpine",
      meilisearch: "getmeili/meilisearch:latest"
    }.freeze

    DEFAULT_PORTS = {
      redis: 6379,
      meilisearch: 7700
    }.freeze

    def initialize(name)
      @name = name.to_sym
      @subdomain = nil
      @env = {}
    end

    def image
      DEFAULT_IMAGES[@name]
    end

    def port
      DEFAULT_PORTS[@name]
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Unified App Config
  # ─────────────────────────────────────────────────────────────

  class AppConfig
    attr_reader :processes
    attr_accessor :dockerfile, :platform

    def initialize
      @processes = {}
      @dockerfile = "Dockerfile"
      @platform = "linux/amd64"
    end

    def process(name)
      config = ProcessConfig.new(name)
      yield config if block_given?
      @processes[name.to_sym] = config
    end

    def web?
      @processes.key?(:web)
    end
  end

  class ProcessConfig
    attr_accessor :command, :port, :replicas, :subdomain
    attr_reader :name

    def initialize(name)
      @name = name.to_sym
      @command = nil
      @port = nil
      @replicas = 1
      @subdomain = nil
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Unified Storage Config
  # ─────────────────────────────────────────────────────────────

  class StorageConfig
    attr_accessor :subdomain

    def initialize
      @subdomain = nil
    end
  end
end
