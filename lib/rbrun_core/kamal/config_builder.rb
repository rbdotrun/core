# frozen_string_literal: true

module RbrunCore::Kamal
  # Builds Kamal deploy.yml and .kamal/secrets from rbrun-core config.
  # No SSH, no Naming — just config translation.
  class ConfigBuilder
    def initialize(config:, servers:, domain:)
      @config = config
      @servers = servers
      @domain = domain
    end

    def to_deploy_yml
      {
        "service" => @config.name,
        "image" => @config.name,
        "servers" => servers_section,
        "proxy" => proxy_section,
        "registry" => registry_section,
        "builder" => { "arch" => platform_arch },
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
      lines << "KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD"
      lines << "RAILS_MASTER_KEY=$(cat config/master.key)"
      lines << "DATABASE_PASSWORD=#{SecureRandom.hex(32)}" if has_postgres?
      lines.join("\n") + "\n"
    end

    private

      def servers_section
        hosts = web_server_ips
        return {} if hosts.empty?

        { "web" => { "hosts" => hosts } }
      end

      def proxy_section
        {
          "ssl" => true,
          "host" => @domain,
          "app_port" => 80
        }
      end

      def registry_section
        {
          "server" => "ghcr.io",
          "username" => [ "KAMAL_REGISTRY_USERNAME" ],
          "password" => [ "KAMAL_REGISTRY_PASSWORD" ]
        }
      end

      def env_section
        clear = { "RAILS_ENV" => "production" }
        clear["DB_HOST"] = db_server_ip if has_postgres?

        secret = [ "RAILS_MASTER_KEY" ]
        secret << "DATABASE_PASSWORD" if has_postgres?

        { "clear" => clear, "secret" => secret }
      end

      def accessories_section
        return nil unless has_postgres?

        {
          "db" => {
            "image" => "postgres:17",
            "host" => db_server_ip,
            "port" => 5432,
            "env" => { "secret" => [ "DATABASE_PASSWORD" ] },
            "directories" => [ "data:/var/lib/postgresql/data" ]
          }
        }
      end

      def web_server_ips
        @servers.values
                .select { |s| s[:role] == :web }
                .map { |s| s[:ip] } # Kamal SSHes to public IPs
                .compact
      end

      def db_server_ip
        db = @servers.values.find { |s| s[:role] == :db }
        db ? db[:private_ip] : web_server_ips.first
      end

      def has_postgres?
        @config.database?(:postgres)
      end

      def platform_arch
        @config.app_config&.platform&.split("/")&.last || "amd64"
      end
  end
end
