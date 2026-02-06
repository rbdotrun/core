# frozen_string_literal: true

module RbrunCore
  module Error
    class Api < Standard
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end

      def not_found? = status == 404
      def unauthorized? = status == 401
      def rate_limited? = status == 429
    end
  end
end
