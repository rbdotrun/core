# frozen_string_literal: true

module RbrunCore
  module Commands
    class DestroySandbox
      WORKSPACE = "/home/deploy/workspace"
      COMPOSE_FILE = "docker-compose.generated.yml"

      def initialize(ctx, on_log: nil, on_state_change: nil)
        @ctx = ctx
        @on_log = on_log
        @on_state_change = on_state_change
      end

      def run
        change_state(:destroying)

        cleanup_tunnel! if @ctx.cloudflare_configured?
        stop_containers! if @ctx.server_ip
        delete_infrastructure!

        change_state(:destroyed)
      end

      private

        def cleanup_tunnel!
          log("delete_tunnel", "Cleaning up tunnel")
          cf_client = @ctx.cloudflare_client
          tunnel = cf_client.find_tunnel(@ctx.prefix)
          return unless tunnel

          zone_id = begin
            cf_client.get_zone_id(@ctx.zone)
          rescue StandardError
            nil
          end
          if zone_id
            record = cf_client.find_dns_record(zone_id, @ctx.prefix)
            cf_client.delete_dns_record(zone_id, record["id"]) if record
          end

          cf_client.delete_tunnel(tunnel[:id])
        end

        def stop_containers!
          log("stop_containers", "Stopping containers")
          begin
            @ctx.ssh_client.execute(
              "cd #{WORKSPACE} && docker compose -f #{COMPOSE_FILE} down",
              raise_on_error: false
            )
          rescue Ssh::Client::Error
            # Server may already be gone
          end
        end

        def delete_infrastructure!
          delete_resource(:server)
          delete_resource(:network)
          delete_resource(:firewall)
        end

        def delete_resource(type)
          log("delete_#{type}", "Deleting #{type}")
          finder = "find_#{type}"
          deleter = "delete_#{type}"
          resource = @ctx.compute_client.public_send(finder, @ctx.prefix)
          @ctx.compute_client.public_send(deleter, resource.id) if resource
        end

        def change_state(state)
          @ctx.state = state
          @on_state_change&.call(state)
        end

        def log(category, message = nil)
          @on_log&.call(category, message)
        end
    end
  end
end
