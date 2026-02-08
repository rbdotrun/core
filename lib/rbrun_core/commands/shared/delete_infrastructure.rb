# frozen_string_literal: true

module RbrunCore
  module Commands
    module Shared
      class DeleteInfrastructure

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          detach_volumes!
          delete_servers!
          delete_network!
          delete_firewall_with_retry!
        end

        private

          def detach_volumes!
            return unless @ctx.compute_client.respond_to?(:list_volumes)

            @on_step&.call("Volumes", :in_progress)

            prefix = @ctx.prefix
            volumes = @ctx.compute_client.list_volumes
            matching = volumes.select { |v| v.name&.start_with?("#{prefix}-") }

            matching.each do |volume|
              @ctx.compute_client.detach_volume(volume_id: volume.id)
            rescue StandardError
              # best effort
            end

            @on_step&.call("Volumes", :done)
          end

          def delete_servers!
            @on_step&.call("Servers", :in_progress)

            all_servers = @ctx.compute_client.list_servers
            prefix = @ctx.prefix

            # Match both new naming (prefix-group-N) and legacy bare name (prefix)
            matching = all_servers.select { |s| s.name == prefix || s.name.start_with?("#{prefix}-") }

            # Delete all servers (delete_server waits for action to complete)
            matching.each do |server|
              @ctx.compute_client.delete_server(server.id)
            end

            @on_step&.call("Servers", :done)
          end

          def delete_network!
            @on_step&.call("Network", :in_progress)
            resource = @ctx.compute_client.find_network(@ctx.prefix)
            @ctx.compute_client.delete_network(resource.id) if resource
            @on_step&.call("Network", :done)
          end

          def delete_firewall_with_retry!(max_attempts: 5, interval: 3)
            @on_step&.call("Firewall", :in_progress)

            firewall = @ctx.compute_client.find_firewall(@ctx.prefix)
            return @on_step&.call("Firewall", :done) unless firewall

            max_attempts.times do |i|
              @ctx.compute_client.delete_firewall(firewall.id)
              @on_step&.call("Firewall", :done)
              return
            rescue Error::Api => e
              raise unless e.message.include?("resource_in_use") || e.message.include?("precondition")

              if i < max_attempts - 1
                sleep(interval)
              else
                raise
              end
            end
          end
      end
    end
  end
end
