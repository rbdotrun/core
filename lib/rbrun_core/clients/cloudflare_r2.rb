# frozen_string_literal: true

require "digest"

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
        require "aws-sdk-s3"

        @client ||= Aws::S3::Client.new(
          endpoint: credentials[:endpoint],
          region: credentials[:region],
          credentials: Aws::Credentials.new(
            credentials[:access_key_id],
            credentials[:secret_access_key]
          ),
          force_path_style: true
        )
      end

      def ensure_bucket(bucket_name)
        client.head_bucket(bucket: bucket_name)
      rescue Aws::S3::Errors::NotFound
        client.create_bucket(bucket: bucket_name)
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
