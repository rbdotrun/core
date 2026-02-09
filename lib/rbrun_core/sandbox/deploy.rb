# frozen_string_literal: true

module RbrunCore
  module Sandbox
    class Deploy
      def initialize(ctx, on_step: nil, on_state_change: nil)
        @ctx = ctx
        @on_step = on_step
        @on_state_change = on_state_change
      end

      def run
        change_state(:provisioning)

        Shared::CreateInfrastructure.new(@ctx, on_step: @on_step).run
        Steps::SetupApplication.new(@ctx, on_step: @on_step).run

        change_state(:running)
      rescue StandardError
        change_state(:failed)
        raise
      end

      private

        def change_state(state)
          @ctx.state = state
          @on_state_change&.call(state)
        end
    end
  end
end
