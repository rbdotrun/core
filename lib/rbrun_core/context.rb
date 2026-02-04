# frozen_string_literal: true

module RbrunCore
  # In-memory state carrier passed through steps and commands.
  # No persistence — just a struct holding resolved config + credentials + mutable state.
  class Context
    attr_reader :config, :target, :branch
    attr_accessor :server_id, :server_ip, :ssh_private_key, :ssh_public_key,
                  :registry_tag, :tunnel_id, :tunnel_token, :slug, :state,
                  :db_password

    def initialize(config:, target:, slug: nil, branch: nil)
      @config = config
      @target = target.to_sym
      @slug = slug || Naming.generate_slug
      @branch = branch
      @state = :pending
    end

    def prefix
      case target
      when :sandbox then Naming.resource(slug)
      else Naming.release_prefix(config.git_config.app_name, target)
      end
    end

    def zone
      config.cloudflare_config&.domain
    end

    def ssh_client
      Ssh::Client.new(host: server_ip, private_key: ssh_private_key, user: Naming.default_user)
    end

    def compute_client
      config.compute_config.client
    end

    def cloudflare_client
      config.cloudflare_config&.client
    end

    def cloudflare_configured?
      config.cloudflare_configured?
    end
  end
end
