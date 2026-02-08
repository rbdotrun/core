# frozen_string_literal: true

module RbrunCore
  module Commands
    module Shared
      class DeleteInfrastructure
        include Stepable

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

            report_step(Step::Id::DETACH_VOLUMES, Step::IN_PROGRESS)

            prefix = @ctx.prefix
            volumes = @ctx.compute_client.list_volumes
            matching = volumes.select { |v| v.name&.start_with?("#{prefix}-") }

            matching.each do |volume|
              @ctx.compute_client.detach_volume(volume_id: volume.id)
            rescue StandardError
              # best effort
            end

            report_step(Step::Id::DETACH_VOLUMES, Step::DONE)
          end

          def delete_servers!
            report_step(Step::Id::DELETE_SERVERS, Step::IN_PROGRESS)

            all_servers = @ctx.compute_client.list_servers
            prefix = @ctx.prefix

            # Match both new naming (prefix-group-N) and legacy bare name (prefix)
            matching = all_servers.select { |s| s.name == prefix || s.name.start_with?("#{prefix}-") }

            # Delete all servers (delete_server waits for action to complete)
            matching.each do |server|
              @ctx.compute_client.delete_server(server.id)
            end

            report_step(Step::Id::DELETE_SERVERS, Step::DONE)
          end

          def delete_network!
            report_step(Step::Id::DELETE_NETWORK, Step::IN_PROGRESS)
            resource = @ctx.compute_client.find_network(@ctx.prefix)
            @ctx.compute_client.delete_network(resource.id) if resource
            report_step(Step::Id::DELETE_NETWORK, Step::DONE)
          end

          def delete_firewall_with_retry!(max_attempts: 5, interval: 3)
            report_step(Step::Id::DELETE_FIREWALL, Step::IN_PROGRESS)

            firewall = @ctx.compute_client.find_firewall(@ctx.prefix)
            return report_step(Step::Id::DELETE_FIREWALL, Step::DONE) unless firewall

            max_attempts.times do |i|
              @ctx.compute_client.delete_firewall(firewall.id)
              report_step(Step::Id::DELETE_FIREWALL, Step::DONE)
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
