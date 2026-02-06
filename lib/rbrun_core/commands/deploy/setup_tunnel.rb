# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      class SetupTunnel
        HTTP_NODE_PORT = 30_080

        def initialize(ctx, on_log: nil)
          @ctx = ctx
          @on_log = on_log
        end

        def run
          return unless @ctx.cloudflare_configured?

          log("tunnel_setup", "Setting up Cloudflare tunnel")

          cf_client = @ctx.cloudflare_client
          tunnel = cf_client.find_or_create_tunnel(@ctx.prefix)
          @ctx.tunnel_id = tunnel[:id]
          @ctx.tunnel_token = cf_client.get_tunnel_token(tunnel[:id])

          ingress_rules = build_tunnel_ingress_rules
          cf_client.configure_tunnel_ingress(tunnel[:id], ingress_rules)

          create_tunnel_dns_records!(tunnel[:id])
        end

        private

          def build_tunnel_ingress_rules
            rules = []
            config = @ctx.config
            zone = @ctx.zone

            if config.app?
              config.app_config.processes.each_value do |process|
                subdomain = process.subdomain
                next unless subdomain && process.port

                hostname = "#{subdomain}.#{zone}"
                rules << {
                  hostname:,
                  service: "http://localhost:#{HTTP_NODE_PORT}",
                  originRequest: { httpHostHeader: hostname }
                }
              end
            end

            config.service_configs.each_value do |svc_config|
              subdomain = svc_config.subdomain
              next unless subdomain && svc_config.port

              hostname = "#{subdomain}.#{zone}"
              rules << {
                hostname:,
                service: "http://localhost:#{HTTP_NODE_PORT}",
                originRequest: { httpHostHeader: hostname }
              }
            end

            rules << { service: "http_status:404" }
            rules
          end

          def create_tunnel_dns_records!(tunnel_id)
            cf_client = @ctx.cloudflare_client
            zone_id = cf_client.get_zone_id(@ctx.zone)
            config = @ctx.config

            if config.app?
              config.app_config.processes.each_value do |process|
                subdomain = process.subdomain
                next unless subdomain

                cf_client.ensure_dns_record(zone_id, "#{subdomain}.#{@ctx.zone}", tunnel_id)
              end
            end

            config.service_configs.each_value do |svc_config|
              subdomain = svc_config.subdomain
              next unless subdomain

              cf_client.ensure_dns_record(zone_id, "#{subdomain}.#{@ctx.zone}", tunnel_id)
            end
          end

          def log(category, message = nil)
            @on_log&.call(category, message)
          end
      end
    end
  end
end
