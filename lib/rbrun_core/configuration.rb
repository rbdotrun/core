# frozen_string_literal: true

module RbrunCore
  class Configuration
    attr_reader :compute_config, :cloudflare_config, :git_config, :claude_config, :database_configs, :service_configs,
                :app_config, :setup_commands, :env_vars
    attr_accessor :target

    def initialize
      @git_config = Config::Git.new
      @claude_config = Config::Claude.new
      @database_configs = {}
      @service_configs = {}
      @app_config = nil
      @setup_commands = []
      @env_vars = {}
    end

    # ─────────────────────────────────────────────────────────────
    # Compute Provider DSL
    # ─────────────────────────────────────────────────────────────

    def compute(provider, &)
      @compute_config = Config::Compute::Registry.build(provider, &)
    end

    # ─────────────────────────────────────────────────────────────
    # Cloudflare DSL
    # ─────────────────────────────────────────────────────────────

    def cloudflare
      @cloudflare_config ||= Config::Cloudflare.new
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
      config = Config::Database.new(type)
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
      config = Config::Service.new(name)
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
      @app_config ||= Config::App.new
      yield @app_config if block_given?
      @app_config
    end

    def app?
      @app_config&.processes&.any?
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
    # Validation
    # ─────────────────────────────────────────────────────────────

    def validate!
      raise Error::Configuration, "Compute provider not configured" unless @compute_config

      @compute_config.validate!
      @cloudflare_config&.validate!
      @git_config.validate!
      validate_cloudflare_required!
      validate_replicas!
    end

    def cloudflare_configured?
      @cloudflare_config&.configured? || false
    end

    def claude_configured?
      @claude_config&.configured? || false
    end

    private

      def validate_replicas!
        @app_config&.processes&.each do |name, p|
          next unless p.subdomain && !p.subdomain.empty?

          if p.replicas < 2
            raise Error::Configuration,
                  "Process #{name} has a subdomain and requires at least 2 replicas for zero-downtime deploys"
          end
        end
        nil
      end

      def validate_cloudflare_required!
        has_subdomain = false
        has_subdomain ||= @app_config&.processes&.any? { |_, p| p.subdomain && !p.subdomain.empty? }
        has_subdomain ||= @service_configs.any? { |_, s| s.subdomain && !s.subdomain.empty? }

        return unless has_subdomain

        unless cloudflare_configured?
          raise Error::Configuration,
                "Cloudflare configuration required when processes or services have subdomains"
        end
      end
  end

  # ─────────────────────────────────────────────────────────────
  # Inline config structs under Config namespace
  # ─────────────────────────────────────────────────────────────

  module Config
    class Database
      attr_accessor :password, :username, :database, :runs_on
      attr_reader :type, :backup_config
      attr_writer :image

      DEFAULT_IMAGES = {
        postgres: "postgres:16-alpine",
        sqlite: nil
      }.freeze

      def initialize(type)
        @type = type.to_sym
        @image = nil
        @password = nil
        @username = "app"
        @database = "app"
        @runs_on = nil
      end

      def backup
        @backup_config = Backup.new
        yield @backup_config if block_given?
        @backup_config
      end

      def image
        @image || DEFAULT_IMAGES[@type]
      end
    end

    class Backup
      attr_accessor :schedule, :retention

      def initialize
        @schedule = "@daily"
        @retention = 30
      end
    end

    class Service
      attr_accessor :subdomain, :env, :runs_on, :port, :mount_path
      attr_reader :name
      attr_writer :image

      def initialize(name)
        @name = name.to_sym
        @subdomain = nil
        @env = {}
        @image = nil
        @runs_on = nil
        @mount_path = nil
        @port = nil
      end

      def image
        @image
      end
    end

    class App
      attr_reader :processes
      attr_accessor :dockerfile, :platform

      def initialize
        @processes = {}
        @dockerfile = "Dockerfile"
        @platform = "linux/amd64"
      end

      def process(name)
        config = Process.new(name)
        yield config if block_given?
        @processes[name.to_sym] = config
      end

      def web?
        @processes.key?(:web)
      end
    end

    class Process
      attr_accessor :command, :port, :subdomain, :runs_on, :replicas
      attr_reader :name

      def initialize(name)
        @name = name.to_sym
        @command = nil
        @port = nil
        @subdomain = nil
        @runs_on = nil
        @replicas = 2
      end
    end
  end
end
