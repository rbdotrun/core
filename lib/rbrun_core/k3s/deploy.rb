# frozen_string_literal: true

module RbrunCore
  module K3s
    class Deploy
      def initialize(ctx, on_step: nil, on_state_change: nil, on_rollout_progress: nil)
        @ctx = ctx
        @on_step = on_step
        @on_state_change = on_state_change
        @on_rollout_progress = on_rollout_progress
      end

      def run
        change_state(:provisioning)

        Shared::CreateInfrastructure.new(@ctx, on_step: @on_step).run
        Steps::SetupK3s.new(@ctx, on_step: @on_step).run
        Steps::ProvisionVolumes.new(@ctx, on_step: @on_step).run if needs_volumes?
        Steps::SetupTunnel.new(@ctx, on_step: @on_step).run if needs_tunnel?
        Steps::SetupRegistry.new(@ctx, on_step: @on_step).run if needs_registry?
        deploy_app! if has_app?
        Steps::DeployManifests.new(@ctx, on_step: @on_step, on_rollout_progress: @on_rollout_progress).run
        remove_excess_servers!

        change_state(:deployed)
      rescue StandardError
        change_state(:failed)
        raise
      end

      private

        def deploy_app!
          Steps::BuildImage.new(@ctx, on_step: @on_step).run
          Steps::CleanupImages.new(@ctx, on_step: @on_step).run
        end

        def remove_excess_servers!
          @ctx.servers_to_remove.each { |server_name| remove_server!(server_name) }
        end

        def remove_server!(server_name)
          drain_node(server_name)
          delete_node(server_name)
          @ctx.compute_client.delete_server_by_name(server_name)
        end

        def drain_node(server_name)
          kubectl = Clients::Kubectl.new(@ctx.ssh_client)
          kubectl.drain(server_name, max_attempts: 1, interval: 0)
        rescue RbrunCore::Error
          # best effort
        end

        def delete_node(server_name)
          kubectl = Clients::Kubectl.new(@ctx.ssh_client)
          kubectl.delete_node(server_name, max_attempts: 1, interval: 0)
        rescue RbrunCore::Error
          # best effort
        end

        def needs_tunnel?
          @ctx.cloudflare_configured?
        end

        def needs_registry?
          @ctx.cloudflare_configured? && has_app?
        end

        def needs_volumes?
          @ctx.config.database? || @ctx.config.service_configs.any? { |_, svc| svc.mount_path }
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
