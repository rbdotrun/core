# frozen_string_literal: true

module RbrunCore
  module Commands
    class Destroy
      def initialize(ctx, on_log: nil, on_state_change: nil)
        @ctx = ctx
        @on_log = on_log
        @on_state_change = on_state_change
      end

      def run
        change_state(:destroying)

        cleanup_tunnel! if @ctx.cloudflare_configured?
        cleanup_volumes!
        delete_infrastructure!

        change_state(:destroyed)
      end

      private

        def cleanup_tunnel!
          log("delete_tunnel", "Cleaning up tunnel")
          cf_client = @ctx.cloudflare_client
          tunnel = cf_client.find_tunnel(@ctx.prefix)
          cf_client.delete_tunnel(tunnel[:id]) if tunnel
        end

        def cleanup_volumes!
          @ctx.config.database_configs.each_key do |type|
            volume_name = "#{@ctx.prefix}-#{type}"
            volume = compute_client.find_volume(volume_name)
            next unless volume

            log("delete_volume_#{type}", "Deleting volume #{type}")
            compute_client.detach_volume(volume_id: volume.id) if volume.server_id && !volume.server_id.empty?
            compute_client.delete_volume(volume.id)
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
          resource = compute_client.public_send(finder, @ctx.prefix)
          compute_client.public_send(deleter, resource.id) if resource
        end

        def compute_client
          @ctx.compute_client
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
