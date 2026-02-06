# frozen_string_literal: true

module RbrunCore
  module Commands
    module Shared
      class DeleteInfrastructure
        def initialize(ctx, on_log: nil)
          @ctx = ctx
          @on_log = on_log
        end

        def run
          delete_servers!
          delete_resource(:network)
          delete_resource(:firewall)
        end

        private

          def delete_servers!
            if multi_server?
              all_servers = @ctx.compute_client.list_servers
              prefix = @ctx.prefix
              matching = all_servers.select { |s| s.name.start_with?("#{prefix}-") }
              matching.each do |server|
                log("delete_server", "Deleting server #{server.name}")
                @ctx.compute_client.delete_server(server.id)
              end
            else
              delete_resource(:server)
            end
          end

          def multi_server?
            @ctx.config.compute_config.respond_to?(:multi_server?) && @ctx.config.compute_config.multi_server?
          end

          def delete_resource(type)
            log("delete_#{type}", "Deleting #{type}")
            finder = "find_#{type}"
            deleter = "delete_#{type}"
            resource = @ctx.compute_client.public_send(finder, @ctx.prefix)
            @ctx.compute_client.public_send(deleter, resource.id) if resource
          end

          def log(category, message = nil)
            @on_log&.call(category, message)
          end
      end
    end
  end
end
