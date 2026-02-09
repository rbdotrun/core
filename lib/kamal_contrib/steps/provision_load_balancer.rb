# frozen_string_literal: true

module KamalContrib
  module Steps
    class ProvisionLoadBalancer
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run
        @on_step&.call("Load Balancer", :in_progress)

        lb = compute_client.find_or_create_load_balancer(
          name: "#{@ctx.prefix}-lb",
          type: @ctx.config.lb_type,
          location: @ctx.config.region,
          network_id: @ctx.network&.id
        )
        @ctx.load_balancer = lb

        attach_to_network!(lb) if @ctx.network
        sync_targets!(lb)
        ensure_service!(lb)

        @on_step&.call("Load Balancer", :done)
      end

      private

        def attach_to_network!(lb)
          compute_client.attach_load_balancer_to_network(
            load_balancer_id: lb.id,
            network_id: @ctx.network.id
          )
        rescue RbrunCore::Error::Api => e
          raise unless e.message.include?("already_added") || e.message.include?("uniqueness")
        end

        def sync_targets!(lb)
          @ctx.servers.each_value do |server|
            next unless server[:role] == :web

            compute_client.add_load_balancer_target(
              load_balancer_id: lb.id,
              server_id: server[:id],
              use_private_ip: true
            )
          rescue RbrunCore::Error::Api => e
            raise unless e.message.include?("target_already_defined")
          end
        end

        def ensure_service!(lb)
          compute_client.add_load_balancer_service(
            load_balancer_id: lb.id,
            protocol: "tcp",
            listen_port: 443,
            destination_port: 443,
            health_check: {
              protocol: "tcp",
              port: 443,
              interval: 15,
              timeout: 10,
              retries: 3
            }
          )
        rescue RbrunCore::Error::Api => e
          raise unless e.message.include?("already") || e.message.include?("uniqueness")
        end

        def compute_client
          @ctx.compute_client
        end
    end
  end
end
