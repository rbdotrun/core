# frozen_string_literal: true

module RbrunCore
  class Configuration
    attr_reader :compute_config, :cloudflare_config, :claude_config, :database_configs, :service_configs,
                :app_config, :env_vars, :storage_config
    attr_accessor :target, :name

    def initialize
      @claude_config = Config::Claude.new
      @storage_config = Config::Storage.new
      @database_configs = {}
      @service_configs = {}
      @app_config = nil
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
    # Claude DSL
    # ─────────────────────────────────────────────────────────────

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
    # Storage DSL
    # ─────────────────────────────────────────────────────────────

    def storage
      yield @storage_config if block_given?
      @storage_config
    end

    def storage?
      @storage_config.any?
    end

    # ─────────────────────────────────────────────────────────────
    # Environment DSL
    # ─────────────────────────────────────────────────────────────

    def env(vars = {})
      @env_vars = vars
    end

    # ─────────────────────────────────────────────────────────────
    # Validation
    # ─────────────────────────────────────────────────────────────

    def validate!
      raise Error::Configuration, "Compute provider not configured" unless @compute_config
      raise Error::Configuration, "target is required" unless @target
      raise Error::Configuration, "name is required (e.g., name: myapp)" unless @name
      raise Error::Configuration, "name must start with a lowercase letter (got: #{@name})" unless @name.match?(/\A[a-z]/)

      @compute_config.validate!
      @cloudflare_config&.validate!
      validate_cloudflare_required!
      validate_replicas!
      nil
    end

    def validate_sandbox_mode!
      return unless @target == :sandbox

      @service_configs.each do |name, svc|
        if svc.runs_on
          raise Error::Configuration, "runs_on is not supported in sandbox mode (service: #{name})"
        end
      end

      return unless @app_config&.processes

      @app_config.processes.each do |name, proc|
        if proc.runs_on
          raise Error::Configuration, "runs_on is not supported in sandbox mode (process: #{name})"
        end
      end
    end

    def cloudflare_configured?
      @cloudflare_config&.configured? || false
    end

    def claude_configured?
      @claude_config&.configured? || false
    end

    private

      def validate_replicas!
        return unless @app_config&.processes

        @app_config.processes.each do |name, p|
          next unless p.subdomain && !p.subdomain.empty?

          if p.replicas < 2
            raise(
              Error::Configuration,
              "Process #{name} has a subdomain and requires at least 2 replicas for zero-downtime deploys"
            )
          end
        end
      end

      def validate_cloudflare_required!
        has_subdomain = false
        has_subdomain ||= @app_config&.processes&.any? { |_, p| p.subdomain && !p.subdomain.empty? }
        has_subdomain ||= @service_configs.any? { |_, s| s.subdomain && !s.subdomain.empty? }

        return unless has_subdomain

        unless cloudflare_configured?
          raise(
            Error::Configuration,
            "Cloudflare configuration required when processes or services have subdomains"
          )
        end
      end
  end
end
