# frozen_string_literal: true

module KamalContrib
  module Steps
    class ConfigureDns
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run
        return unless @ctx.cloudflare_client
        return unless @ctx.lb_public_ip

        @on_step&.call("DNS", :in_progress)

        zone_domain = @ctx.config.cloudflare_zone || extract_zone(@ctx.config.domain)
        zone_id = @ctx.cloudflare_client.get_zone_id(zone_domain)

        record = @ctx.cloudflare_client.ensure_a_record(
          zone_id, @ctx.config.domain, @ctx.lb_public_ip, proxied: true
        )
        @ctx.dns_records << record if record

        # Set Cloudflare SSL to Full (Strict) for kamal-proxy TLS
        @ctx.cloudflare_client.set_ssl_mode(zone_id, "full")

        @on_step&.call("DNS", :done)
      end

      private

        def extract_zone(domain)
          parts = domain.split(".")
          parts.length > 2 ? parts.last(2).join(".") : domain
        end
    end
  end
end
