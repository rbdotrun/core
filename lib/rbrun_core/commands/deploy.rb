# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      def initialize(ctx, logger: nil, on_log: nil, on_state_change: nil, on_rollout_progress: nil)
        @ctx = ctx
        @logger = logger
        @on_log = on_log
        @on_state_change = on_state_change
        @on_rollout_progress = on_rollout_progress
      end

      def run
        change_state(:provisioning)

        Shared::CreateInfrastructure.new(@ctx, logger: @logger).run
        SetupK3s.new(@ctx, logger: @logger).run
        SetupTunnel.new(@ctx, logger: @logger).run if needs_tunnel?
        if has_app?
          BuildImage.new(@ctx, logger: @logger).run
          CleanupImages.new(@ctx, logger: @logger).run
        end
        DeployManifests.new(@ctx, logger: @logger, on_rollout_progress: @on_rollout_progress).run
        remove_excess_servers!

        change_state(:deployed)
      rescue StandardError
        change_state(:failed)
        raise
      end

      private

        def remove_excess_servers!
          return if @ctx.servers_to_remove.empty?

          @ctx.servers_to_remove.each do |server_name|
            @logger.log("scale_down", "Removing #{server_name}")

            begin
              kubectl = Clients::Kubectl.new(@ctx.ssh_client)
              kubectl.drain(server_name, max_attempts: 1, interval: 0)
            rescue RbrunCore::Error => e
              @logger.log("drain_warning", "Drain failed for #{server_name}: #{e.message}, continuing")
            end

            begin
              kubectl = Clients::Kubectl.new(@ctx.ssh_client)
              kubectl.delete_node(server_name, max_attempts: 1, interval: 0)
            rescue RbrunCore::Error
              # best effort
            end

            @ctx.compute_client.delete_server_by_name(server_name)
          end
        end

        def needs_tunnel?
          @ctx.cloudflare_configured?
        end

        def has_app?
          @ctx.config.app?
        end

        def change_state(state)
          @ctx.state = state
          @on_state_change&.call(state)
        end
    end
  end
end
