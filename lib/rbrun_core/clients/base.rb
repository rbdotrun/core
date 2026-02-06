# frozen_string_literal: true

module RbrunCore
  module Clients
    # Base HTTP client for all API integrations.
    #
    # Subclasses must:
    #   - Define BASE_URL constant
    #   - Override #auth_headers to return authentication headers
    #
    # Error handling uses HttpErrors module (ApiError with status/body).
    class Base
      include HttpErrors

      def initialize(timeout: 120, open_timeout: 30)
        @timeout = timeout
        @open_timeout = open_timeout
      end

      protected

        def get(path, params = {})
          handle_response(connection.get(normalize_path(path), params))
        end

        def post(path, body = {})
          handle_response(connection.post(normalize_path(path), body))
        end

        def put(path, body = {})
          handle_response(connection.put(normalize_path(path), body))
        end

        def delete(path)
          response = connection.delete(normalize_path(path))
          return nil if [ 204, 404 ].include?(response.status)

          handle_response(response)
        end

        def normalize_path(path)
          path.sub(%r{^/}, "")
        end

        def handle_response(response)
          return response.body if response.success?

          raise_api_error(response)
        end

        def connection
          @connection ||= Faraday.new(url: base_url, ssl: { verify: false }) do |f|
            f.request :json
            f.response :json
            auth_headers.each { |k, v| f.headers[k] = v }
            f.options.timeout = @timeout
            f.options.open_timeout = @open_timeout
            f.adapter Faraday.default_adapter
          end
        end

      private

        def base_url
          self.class::BASE_URL
        end

        def auth_headers
          {}
        end
    end
  end
end
