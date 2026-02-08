# frozen_string_literal: true

module RbrunCore
  module Error
    class Standard < StandardError; end
    class Configuration < StandardError; end

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

  # Shared HTTP error handling for API clients.
  module HttpErrors
    HTTP_STATUS_MESSAGES = {
      400 => "Bad request",
      401 => "Unauthorized - check credentials",
      403 => "Forbidden",
      404 => "Not found",
      408 => "Timeout",
      409 => "Conflict",
      422 => "Unprocessable entity",
      429 => "Rate limited",
      500 => "Server error",
      502 => "Bad gateway",
      503 => "Service unavailable",
      504 => "Timeout"
    }.freeze

    def error_message_for_status(status)
      HTTP_STATUS_MESSAGES[status] || server_error_message(status) || "Request failed"
    end

    def raise_api_error(response)
      body_info = extract_error_body(response)
      raise Error::Api.new(
        "[#{response.status}] #{error_message_for_status(response.status)}: #{body_info}",
        status: response.status,
        body: response.body
      )
    end

    private

      def server_error_message(status)
        "Server error" if (500..599).cover?(status)
      end

      def extract_error_body(response)
        return response.body.to_s[0..200] unless response.body.is_a?(Hash)

        response.body["message"] || response.body["error"] || response.body.to_s[0..200]
      end
  end
end
