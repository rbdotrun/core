# frozen_string_literal: true

module RbrunCore
  module Commands
    module Kamal
      class Destroy
        def initialize(ctx, on_step: nil, on_state_change: nil)
          @ctx = ctx
          @on_step = on_step
          @on_state_change = on_state_change
        end

        def run
          change_state(:destroying)

          delete_load_balancers!
          delete_servers!
          delete_network!
          delete_firewall!

          change_state(:destroyed)
        rescue StandardError
          change_state(:failed)
          raise
        end

        private

          def prefix
            "#{@ctx.config.name}-kamal"
          end

          def delete_load_balancers!
            return unless compute_client.respond_to?(:list_load_balancers)

            @on_step&.call("Load balancer", :in_progress)
            compute_client.list_load_balancers.each do |lb|
              next unless lb.name.start_with?(prefix)

              compute_client.delete_load_balancer(lb.id)
            end
            @on_step&.call("Load balancer", :done)
          end

          def delete_servers!
            @on_step&.call("Servers", :in_progress)
            compute_client.list_servers.each do |server|
              next unless server.name.start_with?(prefix)

              compute_client.delete_server(server.id)
            end
            @on_step&.call("Servers", :done)
          end

          def delete_network!
            @on_step&.call("Network", :in_progress)
            network = compute_client.find_network(prefix)
            compute_client.delete_network(network.id) if network
            @on_step&.call("Network", :done)
          end

          def delete_firewall!
            @on_step&.call("Firewall", :in_progress)
            firewall = compute_client.find_firewall(prefix)
            compute_client.delete_firewall(firewall.id) if firewall
            @on_step&.call("Firewall", :done)
          end

          def compute_client = @ctx.compute_client

          def change_state(state)
            @ctx.state = state
            @on_state_change&.call(state)
          end
      end
    end
  end
end
