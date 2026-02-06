# frozen_string_literal: true

module RbrunCore
  module Commands
    class DestroySandbox
      def initialize(ctx, logger: nil, on_log: nil, on_state_change: nil)
        @ctx = ctx
        @logger = logger
        @on_log = on_log
        @on_state_change = on_state_change
      end

      def run
        change_state(:destroying)

        Shared::CleanupTunnel.new(@ctx, logger: @logger).run if @ctx.cloudflare_configured?
        StopContainers.new(@ctx, logger: @logger).run if @ctx.server_ip
        Shared::DeleteInfrastructure.new(@ctx, logger: @logger).run

        change_state(:destroyed)
      end

      private

        def change_state(state)
          @ctx.state = state
          @on_state_change&.call(state)
        end
    end
  end
end
