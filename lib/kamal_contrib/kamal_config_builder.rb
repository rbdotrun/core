# frozen_string_literal: true

module KamalContrib
  class KamalConfigBuilder
    def initialize(ctx)
      @ctx = ctx
      @config = ctx.config
    end

    def to_deploy_yml
      {
        "service" => @config.app_name,
        "image" => @config.app_name,
        "servers" => servers_section,
        "proxy" => proxy_section,
        "registry" => registry_section,
        "builder" => { "arch" => "amd64" },
        "ssh" => { "user" => "root" },
        "env" => env_section,
        "accessories" => accessories_section
      }.compact
    end

    def to_yaml
      to_deploy_yml.to_yaml
    end

    def to_secrets
      lines = []
      lines << "KAMAL_REGISTRY_PASSWORD=$#{@config.registry_password_env}"
      lines << "RAILS_MASTER_KEY=$(cat config/master.key)"
      lines << "DATABASE_PASSWORD=#{SecureRandom.hex(32)}"
      lines.join("\n") + "\n"
    end

    private

      def servers_section
        hosts = @ctx.app_server_ips
        return {} if hosts.empty?

        { "web" => { "hosts" => hosts } }
      end

      def proxy_section
        {
          "ssl" => true,
          "host" => @config.domain,
          "app_port" => 80
        }
      end

      def registry_section
        {
          "server" => @config.registry_server,
          "username" => [ @config.registry_username_env ],
          "password" => [ @config.registry_password_env ]
        }
      end

      def env_section
        {
          "clear" => {
            "RAILS_ENV" => "production",
            "DB_HOST" => @ctx.db_server_ip
          }.compact,
          "secret" => %w[RAILS_MASTER_KEY DATABASE_PASSWORD]
        }
      end

      def accessories_section
        return nil unless @config.db_enabled

        {
          "db" => {
            "image" => "postgres:17",
            "host" => @ctx.db_server_ip,
            "port" => 5432,
            "env" => {
              "secret" => %w[DATABASE_PASSWORD]
            },
            "directories" => [ "data:/var/lib/postgresql/data" ]
          }
        }.compact
      end
  end
end
