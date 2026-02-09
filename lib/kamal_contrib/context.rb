# frozen_string_literal: true

module KamalContrib
  class Context
    attr_reader :config, :compute_client, :cloudflare_client
    attr_accessor :servers, :network, :firewall, :load_balancer,
                  :certificates, :dns_records, :state, :ssh_private_key, :ssh_public_key

    def initialize(config:, compute_client:, cloudflare_client: nil)
      @config = config
      @compute_client = compute_client
      @cloudflare_client = cloudflare_client
      @servers = {}
      @certificates = []
      @dns_records = []
      @state = :pending
    end

    def prefix
      config.prefix
    end

    def app_server_ips
      servers.values
             .select { |s| s[:role] == :web }
             .map { |s| s[:private_ip] }
             .compact
    end

    def db_server_ip
      db = servers.values.find { |s| s[:role] == :db }
      db ? db[:private_ip] : app_server_ips.first
    end

    def lb_public_ip
      load_balancer&.public_ipv4
    end
  end
end
