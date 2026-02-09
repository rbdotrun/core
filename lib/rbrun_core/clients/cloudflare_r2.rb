# frozen_string_literal: true

require "digest"
require "faraday"
require "faraday_middleware/aws_sigv4"

module RbrunCore
  module Clients
    class CloudflareR2
      def initialize(api_token:, account_id:)
        @api_token = api_token
        @account_id = account_id
      end

      def ensure_bucket(bucket_name)
        resp = connection.head("/#{bucket_name}")
        return if resp.status == 200

        connection.put("/#{bucket_name}")
      end

      def set_cors(bucket_name, cors_config)
        xml = build_cors_xml(cors_config)
        connection.put("/#{bucket_name}?cors") do |req|
          req.headers["Content-Type"] = "application/xml"
          req.body = xml
        end
      end

      def upload_file(bucket:, key:, body:, content_type: nil)
        connection.put("/#{bucket}/#{key}") do |req|
          req.headers["Content-Type"] = content_type if content_type
          req.body = body
        end
      end

      def download_file(bucket:, key:)
        resp = connection.get("/#{bucket}/#{key}")
        resp.body
      end

      def list_objects(bucket:, prefix: nil)
        path = "/#{bucket}?list-type=2"
        path += "&prefix=#{prefix}" if prefix
        resp = connection.get(path)
        parse_list_objects(resp.body)
      end

      private

        def connection
          @connection ||= Faraday.new(url: endpoint, ssl: { verify: false }) do |f|
            f.request :aws_sigv4,
              service: "s3",
              region: "auto",
              access_key_id: access_key_id,
              secret_access_key: secret_access_key
            f.adapter Faraday.default_adapter
          end
        end

        def endpoint
          "https://#{@account_id}.r2.cloudflarestorage.com"
        end

        def access_key_id
          @access_key_id ||= cloudflare_client.token_id
        end

        def secret_access_key
          @secret_access_key ||= Digest::SHA256.hexdigest(@api_token)
        end

        def cloudflare_client
          @cloudflare_client ||= Cloudflare.new(api_token: @api_token, account_id: @account_id)
        end

        def build_cors_xml(config)
          rules = config[:allowed_origins].map do |origin|
            <<~XML
              <CORSRule>
                <AllowedOrigin>#{origin}</AllowedOrigin>
                #{config[:allowed_methods].map { |m| "<AllowedMethod>#{m}</AllowedMethod>" }.join}
                #{(config[:allowed_headers] || ["*"]).map { |h| "<AllowedHeader>#{h}</AllowedHeader>" }.join}
                #{(config[:expose_headers] || []).map { |h| "<ExposeHeader>#{h}</ExposeHeader>" }.join}
                <MaxAgeSeconds>#{config[:max_age_seconds] || 3600}</MaxAgeSeconds>
              </CORSRule>
            XML
          end.join

          <<~XML
            <?xml version="1.0" encoding="UTF-8"?>
            <CORSConfiguration>#{rules}</CORSConfiguration>
          XML
        end

        def parse_list_objects(xml_body)
          require "rexml/document"
          doc = REXML::Document.new(xml_body)
          contents = []
          doc.elements.each("ListBucketResult/Contents") do |el|
            contents << {
              key: el.elements["Key"]&.text,
              size: el.elements["Size"]&.text&.to_i,
              last_modified: el.elements["LastModified"]&.text
            }
          end
          contents
        end
    end
  end
end
