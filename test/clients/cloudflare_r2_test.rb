# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Clients
    class CloudflareR2Test < Minitest::Test
      def setup
        super
        WebMock.reset!
        stub_cloudflare_token_id
        @http = MockHttp.new
        @client = CloudflareR2.new(api_token: "test-token", account_id: "test-account", http: @http)
      end

      def test_credentials_returns_hash_with_required_keys
        creds = @client.credentials

        assert_equal "token-123", creds[:access_key_id]
        assert_kind_of String, creds[:secret_access_key]
        assert_equal "https://test-account.r2.cloudflarestorage.com", creds[:endpoint]
      end

      def test_credentials_secret_is_sha256_of_token
        creds = @client.credentials

        expected = Digest::SHA256.hexdigest("test-token")
        assert_equal expected, creds[:secret_access_key]
      end

      def test_ensure_bucket_skips_create_when_exists
        @http.stub_response(status: 200)

        @client.ensure_bucket("my-bucket")

        assert_equal 1, @http.requests.size
        assert_equal :head, @http.requests[0][:method]
        assert_includes @http.requests[0][:url], "/my-bucket"
      end

      def test_ensure_bucket_creates_when_not_found
        @http.stub_response(status: 404)

        @client.ensure_bucket("my-bucket")

        assert_equal 2, @http.requests.size
        assert_equal :head, @http.requests[0][:method]
        assert_equal :put, @http.requests[1][:method]
      end

      def test_upload_file_sends_put_request
        @http.stub_response(status: 200)

        @client.upload_file(bucket: "bucket", key: "path/to/file.txt", body: "content")

        assert_equal 1, @http.requests.size
        assert_equal :put, @http.requests[0][:method]
        assert_includes @http.requests[0][:url], "/bucket/path/to/file.txt"
      end

      def test_upload_file_sets_content_type
        @http.stub_response(status: 200)

        @client.upload_file(bucket: "bucket", key: "file.json", body: "{}", content_type: "application/json")

        assert_equal "application/json", @http.requests[0][:headers]["content-type"]
      end

      def test_download_file_returns_body
        @http.stub_response(status: 200, body: "file content")

        result = @client.download_file(bucket: "bucket", key: "file.txt")

        assert_equal "file content", result
      end

      def test_list_objects_parses_xml_response
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <ListBucketResult>
            <Contents>
              <Key>file1.txt</Key>
              <Size>100</Size>
              <LastModified>2024-01-01T00:00:00Z</LastModified>
            </Contents>
            <Contents>
              <Key>file2.txt</Key>
              <Size>200</Size>
              <LastModified>2024-01-02T00:00:00Z</LastModified>
            </Contents>
          </ListBucketResult>
        XML
        @http.stub_response(status: 200, body: xml)

        result = @client.list_objects(bucket: "bucket")

        assert_equal 2, result.size
        assert_equal "file1.txt", result[0][:key]
        assert_equal 100, result[0][:size]
      end

      def test_list_objects_with_prefix
        @http.stub_response(status: 200, body: empty_list_xml)

        @client.list_objects(bucket: "bucket", prefix: "docker/")

        assert_includes @http.requests[0][:url], "prefix=docker/"
      end

      def test_set_cors_sends_xml_config
        @http.stub_response(status: 200)

        @client.set_cors("bucket", {
          allowed_origins: ["https://example.com"],
          allowed_methods: %w[GET PUT]
        })

        assert_equal :put, @http.requests[0][:method]
        assert_includes @http.requests[0][:url], "?cors"
        assert_includes @http.requests[0][:body], "<AllowedOrigin>https://example.com</AllowedOrigin>"
      end

      private

        def stub_cloudflare_token_id
          stub_request(:get, "https://api.cloudflare.com/client/v4/user/tokens/verify")
            .to_return(status: 200, body: { success: true, result: { id: "token-123" } }.to_json, headers: json_headers)
        end

        def empty_list_xml
          '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult></ListBucketResult>'
        end

        class MockHttp
          attr_reader :requests

          def initialize
            @requests = []
            @response = MockResponse.new(200, "")
          end

          def stub_response(status:, body: "")
            @response = MockResponse.new(status, body)
          end

          def request(method, url, headers: {}, body: nil, **_opts)
            @requests << { method:, url:, headers:, body: }
            @response
          end

          MockResponse = Struct.new(:status, :body)
        end
    end
  end
end
