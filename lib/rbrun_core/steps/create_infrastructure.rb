# frozen_string_literal: true

module RbrunCore
  module Steps
    class CreateInfrastructure
      def initialize(ctx, on_log: nil)
        @ctx = ctx
        @on_log = on_log
      end

      def run
        log("firewall", "Finding or creating firewall")
        firewall = create_firewall!

        log("network", "Finding or creating network")
        network = compute_client.find_or_create_network(
          @ctx.prefix,
          location: location
        )

        log("ssh_key", "Finding or creating SSH key")
        ssh_key = compute_client.find_or_create_ssh_key(
          name: @ctx.prefix,
          public_key: @ctx.ssh_public_key
        )

        log("server", "Finding or creating server")
        server = create_server!(firewall_id: firewall.id, network_id: network.id, ssh_key_ids: [ssh_key.id])

        @ctx.server_id = server.id
        @ctx.server_ip = server.public_ipv4

        log("ssh_wait", "Waiting for SSH")
        wait_for_ssh!
      end

      private

        def create_firewall!
          rules = [
            { direction: "in", protocol: "tcp", port: "22", source_ips: ["0.0.0.0/0", "::/0"] },
            { direction: "in", protocol: "tcp", port: "6443", source_ips: ["10.0.0.0/16"] }
          ]
          compute_client.find_or_create_firewall(@ctx.prefix, rules:)
        end

        def create_server!(firewall_id:, network_id:, ssh_key_ids:)
          user_data = Providers::CloudInit.generate(ssh_public_key: @ctx.ssh_public_key)
          server_type = @ctx.config.resolve(@ctx.config.compute_config.server_type, target: @ctx.target)

          compute_client.find_or_create_server(
            name: @ctx.prefix,
            server_type:,
            location: location,
            image: @ctx.config.compute_config.image,
            user_data:,
            labels: { purpose: @ctx.target.to_s },
            firewalls: [firewall_id],
            networks: [network_id],
            ssh_keys: ssh_key_ids
          )
        end

        def wait_for_ssh!(timeout: 180)
          @ctx.ssh_client.wait_until_ready(max_attempts: timeout / 5, interval: 5)
        end

        def compute_client
          @ctx.compute_client
        end

        def location
          @ctx.config.compute_config.location
        end

        def log(category, message = nil)
          @on_log&.call(category, message)
        end
    end
  end
end
