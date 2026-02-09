# frozen_string_literal: true

require "digest"
require "httpx"
require "aws-sigv4"

module RbrunCore
  module Clients
    class CloudflareR2
      def initialize(api_token:, account_id:)
        @api_token = api_token
        @account_id = account_id
      end

      def ensure_bucket(bucket_name)
        resp = request(:head, "/#{bucket_name}")
        return if resp.status == 200

        request(:put, "/#{bucket_name}")
      end

      def set_cors(bucket_name, cors_config)
        xml = build_cors_xml(cors_config)
        request(:put, "/#{bucket_name}?cors", body: xml, headers: { "content-type" => "application/xml" })
      end

      def upload_file(bucket:, key:, body:, content_type: nil)
        headers = {}
        headers["content-type"] = content_type if content_type
        request(:put, "/#{bucket}/#{key}", body: body, headers: headers)
      end

      def download_file(bucket:, key:)
        resp = request(:get, "/#{bucket}/#{key}")
        resp.body.to_s
      end

      def list_objects(bucket:, prefix: nil)
        path = "/#{bucket}?list-type=2"
        path += "&prefix=#{prefix}" if prefix
        resp = request(:get, path)
        parse_list_objects(resp.body.to_s)
      end

      def credentials
        {
          access_key_id: access_key_id,
          secret_access_key: secret_access_key,
          endpoint: endpoint
        }
      end

      private

        def request(method, path, body: nil, headers: {})
          url = "#{endpoint}#{path}"
          uri = URI.parse(url)

          sig_headers = signer.sign_request(
            http_method: method.to_s.upcase,
            url: url,
            headers: headers.merge("host" => uri.host),
            body: body || ""
          ).headers

          all_headers = headers.merge(sig_headers)

          http.request(method, url, headers: all_headers, body: body, ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
        end

        def http
          @http ||= HTTPX
        end

        def signer
          @signer ||= Aws::Sigv4::Signer.new(
            service: "s3",
            region: "auto",
            access_key_id: access_key_id,
            secret_access_key: secret_access_key
          )
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
