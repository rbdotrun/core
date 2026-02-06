# frozen_string_literal: true

module RbrunCore
  module Commands
    class Destroy
      def initialize(ctx, on_log: nil, on_state_change: nil)
        @ctx = ctx
        @on_log = on_log
        @on_state_change = on_state_change
      end

      def run
        change_state(:destroying)

        Shared::CleanupTunnel.new(@ctx, on_log: @on_log).run if @ctx.cloudflare_configured?
        Shared::DeleteInfrastructure.new(@ctx, on_log: @on_log).run

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
