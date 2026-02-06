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

        Shared::CreateInfrastructure.new(@ctx, on_log: @on_log).run
        SetupK3s.new(@ctx, on_log: @on_log).run
        SetupTunnel.new(@ctx, on_log: @on_log).run if needs_tunnel?
        if has_app?
          BuildImage.new(@ctx, on_log: @on_log).run
          CleanupImages.new(@ctx, on_log: @on_log).run
        end
        DeployManifests.new(@ctx, on_log: @on_log).run

        change_state(:deployed)
      rescue StandardError
        change_state(:failed)
        raise
      end

      private

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
