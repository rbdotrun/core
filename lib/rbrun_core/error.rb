# frozen_string_literal: true

module RbrunCore
  module Error
    class Standard < StandardError; end
    class Configuration < StandardError; end

    class Api < Standard
      attr_reader :status, :body, :request_method, :request_path, :request_body

      def initialize(message, status: nil, body: nil, request_method: nil, request_path: nil, request_body: nil)
        super(message)
        @status = status
        @body = body
        @request_method = request_method
        @request_path = request_path
        @request_body = request_body
      end

      def not_found? = status == 404
      def unauthorized? = status == 401
      def rate_limited? = status == 429

      def verbose_message
        parts = [message]
        if request_method && request_path
          parts << "  Request: #{request_method.to_s.upcase} #{request_path}"
        end
        if request_body && !request_body.empty?
          formatted = request_body.is_a?(String) ? request_body : JSON.pretty_generate(request_body)
          parts << "  Payload: #{formatted}"
        end
        parts.join("\n")
      end
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

    def raise_api_error(response, request_method: nil, request_path: nil, request_body: nil)
      body_info = extract_error_body(response)
      raise Error::Api.new(
        "[#{response.status}] #{error_message_for_status(response.status)}: #{body_info}",
        status: response.status,
        body: response.body,
        request_method:,
        request_path:,
        request_body:
      )
    end

    private

      def server_error_message(status)
        "Server error" if (500..599).cover?(status)
      end

      def extract_error_body(response)
        body = response.body
        return body.to_s[0..1000] unless body.is_a?(Hash)

        parts = []
        parts << body["message"] if body["message"]
        parts << "(#{body["type"]})" if body["type"]

        if body["fields"].is_a?(Hash) && body["fields"].any?
          parts << "=> invalid fields:"
          body["fields"].each do |field, errors|
            error_list = errors.is_a?(Array) ? errors.join(", ") : errors.to_s
            parts << "  - #{field}: #{error_list}"
          end
        end

        if body["details"].is_a?(Array) && body["details"].any?
          parts << "=> details:"
          body["details"].each { |d| parts << "  - #{d}" }
        elsif body["details"].is_a?(String) && !body["details"].empty?
          parts << "=> #{body["details"]}"
        end

        parts.any? ? parts.join("\n") : body.to_s[0..1000]
      end
  end
end
