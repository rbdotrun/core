# frozen_string_literal: true

module RbrunCore
  module Generators
    class Compose
      def initialize(config)
        @config = config
      end

      def generate
        {
          "services" => generate_services,
          "volumes" => generate_volumes
        }.compact.to_yaml
      end

      private

        def generate_services
          services = {}

          @config.app_config&.processes&.each do |name, process|
            services[name.to_s] = app_service(name, process)
          end

          @config.database_configs.each do |type, db_config|
            services[type.to_s] = database_service(type, db_config)
          end

          @config.service_configs.each do |name, service_config|
            services[name.to_s] = service_service(name, service_config)
          end

          services
        end

        def app_service(_name, process)
          env = resolved_env_vars.merge(process.env || {})

          service = {
            "build" => ".",
            "volumes" => [ ".:/app" ],
            "environment" => env
          }

          service["command"] = process.command if process.command
          service["ports"] = [ "#{process.port}:#{process.port}" ] if process.port

          depends = build_depends_on
          service["depends_on"] = depends if depends.any?

          service
        end

        def build_depends_on
          depends = []
          depends += @config.database_configs.keys.map(&:to_s)
          depends += @config.service_configs.keys.map(&:to_s)
          depends
        end

        def database_service(type, db_config)
          case type
          when :postgres then postgres_service(db_config)
          when :sqlite then nil
          end
        end

        def postgres_service(db_config)
          {
            "image" => db_config.image,
            "volumes" => [ "#{Naming.compose_volume(:postgres)}:/var/lib/postgresql/data" ],
            "environment" => postgres_environment
          }
        end

        def postgres_environment
          {
            "POSTGRES_USER" => "app",
            "POSTGRES_PASSWORD" => "app",
            "POSTGRES_DB" => "app_development"
          }
        end

        def service_service(name, service_config)
          service = { "image" => service_config.image }
          service["ports"] = [ "#{service_config.port}:#{service_config.port}" ] if service_config.port
          service["volumes"] = [ "#{Naming.compose_volume(name)}:#{service_config.mount_path}" ] if service_config.mount_path
          service
        end

        def generate_volumes
          volumes = {}

          @config.database_configs.each_key do |type|
            volumes[Naming.compose_volume(type)] = nil if type == :postgres
          end

          @config.service_configs.each_key { |name| volumes[Naming.compose_volume(name)] = nil }

          volumes.any? ? volumes : nil
        end

        def resolved_env_vars
          env = {}
          @config.env_vars.each { |key, value| env[key.to_s] = value.to_s }
          env["DATABASE_URL"] = postgres_url if @config.database?(:postgres)
          env["REDIS_URL"] = redis_url if @config.service?(:redis)
          env["BINDING"] = "0.0.0.0"
          env
        end

        def postgres_url
          "postgres://app:app@postgres:5432/app_development"
        end

        def redis_url
          "redis://redis:6379"
        end
    end
  end
end
