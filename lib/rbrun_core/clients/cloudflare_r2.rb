# frozen_string_literal: true

require "aws-sdk-s3"
require "digest"
require "faraday"

module RbrunCore
  module Clients
    class CloudflareR2
      def initialize(api_token:, account_id:)
        @api_token = api_token
        @account_id = account_id
      end

      def credentials
        @credentials ||= {
          access_key_id: token_id,
          secret_access_key: Digest::SHA256.hexdigest(@api_token),
          endpoint: "https://#{@account_id}.r2.cloudflarestorage.com",
          region: "auto"
        }
      end

      def client
        @client ||= Aws::S3::Client.new(
          endpoint: credentials[:endpoint],
          region: credentials[:region],
          credentials: Aws::Credentials.new(
            credentials[:access_key_id],
            credentials[:secret_access_key]
          ),
          force_path_style: true,
          http_handler: FaradayHandler.new
        )
      end

      class FaradayHandler < Seahorse::Client::Handler
        def call(context)
          req = context.http_request
          resp = context.http_response

          conn = Faraday.new(ssl: { verify: false }) do |f|
            f.adapter Faraday.default_adapter
          end

          method = req.http_method.downcase.to_sym
          url = req.endpoint.to_s
          headers = req.headers.to_h
          body = req.body.respond_to?(:read) ? req.body.read : req.body

          faraday_resp = conn.run_request(method, url, body, headers)

          resp.status_code = faraday_resp.status
          resp.headers = faraday_resp.headers
          resp.body = StringIO.new(faraday_resp.body || "")

          Seahorse::Client::Response.new(context: context)
        end
      end

      def ensure_bucket(bucket_name)
        client.head_bucket(bucket: bucket_name)
      rescue Aws::S3::Errors::NotFound
        client.create_bucket(bucket: bucket_name)
      end

      def set_cors(bucket_name, cors_config)
        client.put_bucket_cors(
          bucket: bucket_name,
          cors_configuration: {
            cors_rules: [
              {
                allowed_origins: cors_config[:allowed_origins],
                allowed_methods: cors_config[:allowed_methods],
                allowed_headers: cors_config[:allowed_headers] || [ "*" ],
                expose_headers: cors_config[:expose_headers] || [],
                max_age_seconds: cors_config[:max_age_seconds] || 3600
              }
            ]
          }
        )
      end

      def upload_file(bucket:, key:, body:, content_type: nil)
        options = { bucket:, key:, body: }
        options[:content_type] = content_type if content_type
        client.put_object(options)
      end

      def download_file(bucket:, key:)
        response = client.get_object(bucket:, key:)
        response.body.read
      end

      def list_objects(bucket:, prefix: nil)
        options = { bucket: }
        options[:prefix] = prefix if prefix
        response = client.list_objects_v2(options)
        response.contents.map do |obj|
          { key: obj.key, size: obj.size, last_modified: obj.last_modified }
        end
      end

      private

        def token_id
          @token_id ||= cloudflare_client.token_id
        end

        def cloudflare_client
          @cloudflare_client ||= Cloudflare.new(api_token: @api_token, account_id: @account_id)
        end
    end
  end
end
