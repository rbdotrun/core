# frozen_string_literal: true

module RbrunCore
  # Include this module in command classes that need to report step progress.
  # The command must set @on_step in its initializer.
  module Stepable
    private

      def report_step(id, status, message: nil, parent: nil)
        @on_step&.call(id, status, message:, parent:)
      end
  end
end
