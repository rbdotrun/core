# frozen_string_literal: true

module RbrunCore
  module Commands
    module Shared
      class DeleteInfrastructure
        FIREWALL_RETRY_ATTEMPTS = 5
        FIREWALL_RETRY_INTERVAL = 3

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          detach_volumes!
          delete_servers!
          delete_network!
          delete_firewall!
        end

        private

          def detach_volumes!
            return unless compute_client.respond_to?(:list_volumes)

            @on_step&.call("Volumes", :in_progress)
            detach_matching_volumes!
            @on_step&.call("Volumes", :done)
          end

          def detach_matching_volumes!
            matching_volumes.each do |volume|
              compute_client.detach_volume(volume_id: volume.id)
            rescue StandardError
              # best effort
            end
          end

          def matching_volumes
            compute_client.list_volumes.select { |v| v.name&.start_with?("#{@ctx.prefix}-") }
          end

          def delete_servers!
            @on_step&.call("Servers", :in_progress)
            matching_servers.each { |server| compute_client.delete_server(server.id) }
            @on_step&.call("Servers", :done)
          end

          def matching_servers
            compute_client.list_servers.select { |s| server_matches?(s.name) }
          end

          def server_matches?(name)
            name == @ctx.prefix || name.start_with?("#{@ctx.prefix}-")
          end

          def delete_network!
            @on_step&.call("Network", :in_progress)
            network = compute_client.find_network(@ctx.prefix)
            compute_client.delete_network(network.id) if network
            @on_step&.call("Network", :done)
          end

          def delete_firewall!
            @on_step&.call("Firewall", :in_progress)

            firewall = compute_client.find_firewall(@ctx.prefix)
            delete_firewall_with_retry!(firewall) if firewall

            @on_step&.call("Firewall", :done)
          end

          def delete_firewall_with_retry!(firewall)
            FIREWALL_RETRY_ATTEMPTS.times do |attempt|
              compute_client.delete_firewall(firewall.id)
              return
            rescue Error::Api => e
              raise unless retryable_firewall_error?(e)
              raise if last_attempt?(attempt)

              sleep(FIREWALL_RETRY_INTERVAL)
            end
          end

          def retryable_firewall_error?(error)
            error.message.include?("resource_in_use") || error.message.include?("precondition")
          end

          def last_attempt?(attempt)
            attempt >= FIREWALL_RETRY_ATTEMPTS - 1
          end

          def compute_client
            @ctx.compute_client
          end
      end
    end
  end
end
