# frozen_string_literal: true

module KamalContrib
  module Steps
    class ProvisionServers
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run
        create_network!
        create_firewall!
        create_servers!
      end

      private

        def create_network!
          @on_step&.call("Network", :in_progress)
          @ctx.network = compute_client.find_or_create_network(
            @ctx.prefix, location: @ctx.config.region
          )
          @on_step&.call("Network", :done)
        end

        def create_firewall!
          @on_step&.call("Firewall", :in_progress)
          @ctx.firewall = compute_client.find_or_create_firewall(
            @ctx.prefix, rules: firewall_rules
          )
          @on_step&.call("Firewall", :done)
        end

        def create_servers!
          @ctx.config.server_count.times do |i|
            name = "#{@ctx.prefix}-web-#{i + 1}"
            @on_step&.call("Server", :in_progress, name)

            server = compute_client.find_or_create_server(
              name:,
              instance_type: @ctx.config.server_type,
              location: @ctx.config.region,
              image: "ubuntu-22.04",
              labels: { purpose: "kamal", role: "web" },
              firewall_ids: [ @ctx.firewall.id ],
              network_ids: [ @ctx.network.id ]
            )

            @ctx.servers[name] = {
              id: server.id,
              ip: server.public_ipv4,
              private_ip: server.private_ipv4,
              role: :web
            }

            @on_step&.call("Server", :done, name)
          end

          create_db_server! if @ctx.config.db_enabled && @ctx.config.db_server_type
        end

        def create_db_server!
          name = "#{@ctx.prefix}-db-1"
          @on_step&.call("Server", :in_progress, name)

          server = compute_client.find_or_create_server(
            name:,
            instance_type: @ctx.config.db_server_type,
            location: @ctx.config.region,
            image: "ubuntu-22.04",
            labels: { purpose: "kamal", role: "db" },
            firewall_ids: [ @ctx.firewall.id ],
            network_ids: [ @ctx.network.id ]
          )

          @ctx.servers[name] = {
            id: server.id,
            ip: server.public_ipv4,
            private_ip: server.private_ipv4,
            role: :db
          }

          @on_step&.call("Server", :done, name)
        end

        def firewall_rules
          [
            # SSH from anywhere (operator access; tighten in production)
            { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0", "::/0" ] },
            # All traffic from private network
            { direction: "in", protocol: "tcp", port: "any", source_ips: [ "10.0.0.0/16" ] },
            { direction: "in", protocol: "udp", port: "any", source_ips: [ "10.0.0.0/16" ] }
          ]
        end

        def compute_client
          @ctx.compute_client
        end
    end
  end
end
