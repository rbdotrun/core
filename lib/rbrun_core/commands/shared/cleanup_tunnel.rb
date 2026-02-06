# frozen_string_literal: true

module RbrunCore
  module Commands
    module Shared
      class CleanupTunnel
        def initialize(ctx, on_log: nil)
          @ctx = ctx
          @on_log = on_log
        end

        def run
          log("delete_tunnel", "Cleaning up tunnel")
          cf_client = @ctx.cloudflare_client

          zone_id = begin
            cf_client.get_zone_id(@ctx.zone)
          rescue StandardError
            nil
          end

          cleanup_dns_records!(cf_client, zone_id) if zone_id

          tunnel = cf_client.find_tunnel(@ctx.prefix)
          cf_client.delete_tunnel(tunnel[:id]) if tunnel
        end

        private

          def cleanup_dns_records!(cf_client, zone_id)
            config = @ctx.config
            zone = @ctx.zone

            if config.app?
              config.app_config.processes.each_value do |process|
                next unless process.subdomain

                record = cf_client.find_dns_record(zone_id, "#{process.subdomain}.#{zone}")
                cf_client.delete_dns_record(zone_id, record["id"]) if record
              end
            end

            config.service_configs.each_value do |svc_config|
              next unless svc_config.subdomain

              record = cf_client.find_dns_record(zone_id, "#{svc_config.subdomain}.#{zone}")
              cf_client.delete_dns_record(zone_id, record["id"]) if record
            end
          end

          def log(category, message = nil)
            @on_log&.call(category, message)
          end
      end
    end
  end
end
