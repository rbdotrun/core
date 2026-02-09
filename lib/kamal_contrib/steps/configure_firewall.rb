# frozen_string_literal: true

module KamalContrib
  module Steps
    class ConfigureFirewall
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run
        return unless @ctx.firewall

        @on_step&.call("Firewall rules", :in_progress)

        compute_client.set_firewall_rules(@ctx.firewall.id, locked_down_rules)

        @on_step&.call("Firewall rules", :done)
      end

      private

        def locked_down_rules
          [
            # SSH from operator (anywhere for now; could restrict to specific IP)
            { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0", "::/0" ] },
            # Private network: all traffic
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
