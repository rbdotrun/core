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
    #
    # Transient failures (5xx from upstream, connection errors, SSL flaps) are
    # retried automatically via Faraday's :retry middleware. Configured in
    # RETRY_OPTIONS below. Only idempotent HTTP methods are retried.
    class Base
      include HttpErrors

      # Retry configuration applied to every API client connection.
      #
      # Scope: transient upstream failures only — gateway 5xx, rate limits, and
      # network-level exceptions. 4xx stays hard-failing so real application
      # errors surface immediately.
      #
      # Methods are restricted to idempotent verbs (GET/HEAD/PUT). rbrun's PUTs
      # are always explicit resource upserts (configurations, DNS records
      # addressed by id), so replaying them is safe. POST/PATCH/DELETE are
      # excluded to avoid double-write on a 5xx-after-commit.
      RETRY_OPTIONS = {
        max: 3,
        interval: 0.5,
        interval_randomness: 0.5,
        backoff_factor: 2,
        retry_statuses: [ 429, 500, 502, 503, 504 ],
        methods: %i[get head put],
        # Faraday::RetriableResponse is the synthetic exception the middleware
        # raises internally when a response matches retry_statuses. It MUST be
        # in this list or status-based retries silently escape as uncaught.
        exceptions: [
          Faraday::RetriableResponse,
          Faraday::ConnectionFailed,
          Faraday::TimeoutError,
          Faraday::SSLError
        ]
      }.freeze

      def initialize(timeout: 120, open_timeout: 30)
        @timeout = timeout
        @open_timeout = open_timeout
      end

      protected

        def get(path, params = {})
          normalized = normalize_path(path)
          handle_response(connection.get(normalized, params), method: :get, path: normalized, body: params)
        end

        def post(path, body = {})
          normalized = normalize_path(path)
          handle_response(connection.post(normalized, body), method: :post, path: normalized, body:)
        end

        def put(path, body = {})
          normalized = normalize_path(path)
          handle_response(connection.put(normalized, body), method: :put, path: normalized, body:)
        end

        def patch(path, body = {}, content_type: nil)
          normalized = normalize_path(path)
          if content_type
            response = raw_connection.patch(normalized) do |req|
              req.headers["Content-Type"] = content_type
              auth_headers.each { |k, v| req.headers[k] = v }
              req.body = body
            end
            unless response.success?
              raise_api_error(response, request_method: :patch, request_path: normalized, request_body: body)
            end
            response.body
          else
            handle_response(connection.patch(normalized, body), method: :patch, path: normalized, body:)
          end
        end

        def delete(path)
          normalized = normalize_path(path)
          response = connection.delete(normalized)
          return nil if [ 204, 404 ].include?(response.status)

          handle_response(response, method: :delete, path: normalized, body: nil)
        end

        def normalize_path(path)
          path.sub(%r{^/}, "")
        end

        def handle_response(response, method: nil, path: nil, body: nil)
          return response.body if response.success?

          raise_api_error(response, request_method: method, request_path: path, request_body: body)
        end

        def connection
          @connection ||= Faraday.new(url: base_url) do |f|
            f.request :retry, RETRY_OPTIONS
            f.request :json
            f.response :json
            auth_headers.each { |k, v| f.headers[k] = v }
            f.options.timeout = @timeout
            f.options.open_timeout = @open_timeout
            f.adapter Faraday.default_adapter
          end
        end

        def raw_connection
          @raw_connection ||= Faraday.new(url: base_url) do |f|
            f.request :retry, RETRY_OPTIONS
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
