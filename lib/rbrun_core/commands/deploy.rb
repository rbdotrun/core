# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      def initialize(ctx, on_log: nil, on_state_change: nil)
        @ctx = ctx
        @on_log = on_log
        @on_state_change = on_state_change
      end

      def run
        change_state(:provisioning)

        Steps::CreateInfrastructure.new(@ctx, on_log: @on_log).run
        Steps::SetupK3s.new(@ctx, on_log: @on_log).run
        Steps::ProvisionVolume.new(@ctx, on_log: @on_log).run if needs_volume?
        Steps::SetupTunnel.new(@ctx, on_log: @on_log).run if needs_tunnel?
        Steps::BuildImage.new(@ctx, on_log: @on_log).run if has_app?
        Steps::DeployManifests.new(@ctx, on_log: @on_log).run

        change_state(:deployed)
      end

      private

        def needs_volume?
          @ctx.config.database?
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
