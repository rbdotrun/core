# frozen_string_literal: true

module RbrunCore
  module Commands
    class Destroy
      def initialize(ctx, on_step: nil, on_state_change: nil)
        @ctx = ctx
        @on_step = on_step
        @on_state_change = on_state_change
      end

      def run
        change_state(:destroying)

        Shared::CleanupTunnel.new(@ctx, on_step: @on_step).run if @ctx.cloudflare_configured?
        Shared::DeleteInfrastructure.new(@ctx, on_step: @on_step).run

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
