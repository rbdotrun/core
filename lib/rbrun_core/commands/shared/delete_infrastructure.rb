# frozen_string_literal: true

module RbrunCore
  module Commands
    module Shared
      class DeleteInfrastructure
        def initialize(ctx, logger: nil)
          @ctx = ctx
          @logger = logger
        end

        def run
          detach_volumes!
          delete_servers!
          delete_resource(:network)
          delete_firewall_with_retry!
        end

        private

          def detach_volumes!
            return unless @ctx.compute_client.respond_to?(:list_volumes)

            prefix = @ctx.prefix
            volumes = @ctx.compute_client.list_volumes
            matching = volumes.select { |v| v.name&.start_with?("#{prefix}-") }

            matching.each do |volume|
              log("detach_volume", "Detaching volume #{volume.name}")
              @ctx.compute_client.detach_volume(volume_id: volume.id)
            rescue StandardError => e
              log("detach_volume", "Warning: Could not detach #{volume.name}: #{e.message}")
            end
          end

          def delete_servers!
            all_servers = @ctx.compute_client.list_servers
            prefix = @ctx.prefix

            # Match both new naming (prefix-group-N) and legacy bare name (prefix)
            matching = all_servers.select { |s| s.name == prefix || s.name.start_with?("#{prefix}-") }

            # Delete all servers (delete_server waits for action to complete)
            matching.each do |server|
              log("delete_server", "Deleting server #{server.name}")
              @ctx.compute_client.delete_server(server.id)
            end
          end

          def delete_resource(type)
            log("delete_#{type}", "Deleting #{type}")
            finder = "find_#{type}"
            deleter = "delete_#{type}"
            resource = @ctx.compute_client.public_send(finder, @ctx.prefix)
            @ctx.compute_client.public_send(deleter, resource.id) if resource
          end

          def delete_firewall_with_retry!(max_attempts: 5, interval: 3)
            log("delete_firewall", "Deleting firewall")
            firewall = @ctx.compute_client.find_firewall(@ctx.prefix)
            return unless firewall

            max_attempts.times do |i|
              @ctx.compute_client.delete_firewall(firewall.id)
              return # Success
            rescue HttpErrors::ApiError => e
              raise unless e.message.include?("resource_in_use")

              if i < max_attempts - 1
                log("delete_firewall_retry", "Firewall still in use, retrying in #{interval}s (attempt #{i + 1}/#{max_attempts})")
                sleep(interval)
              else
                raise
              end
            end
          end

          def log(category, message = nil)
            @logger&.log(category, message)
          end
      end
    end
  end
end
