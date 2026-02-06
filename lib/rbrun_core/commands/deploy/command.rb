# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      def initialize(ctx, logger: nil, on_state_change: nil)
        @ctx = ctx
        @logger = logger || RbrunCore::Logger.new
        @on_state_change = on_state_change
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
        DeployManifests.new(@ctx, logger: @logger).run

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
