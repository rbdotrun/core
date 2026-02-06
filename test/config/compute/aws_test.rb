# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Config
    module Compute
      class AwsTest < Minitest::Test
        def setup
          super
          @config = Aws.new
        end

        def test_provider_name_is_aws
          assert_equal :aws, @config.provider_name
        end

        def test_default_region
          assert_equal "us-east-1", @config.region
        end

        def test_default_server
          assert_equal "t3.micro", @config.server
        end

        def test_default_image
          assert_equal "ubuntu-22.04", @config.image
        end

        def test_location_returns_region
          @config.region = "us-west-2"

          assert_equal "us-west-2", @config.location
        end

        def test_location_setter_sets_region
          @config.location = "eu-west-1"

          assert_equal "eu-west-1", @config.region
        end

        def test_validate_raises_without_access_key_id
          @config.secret_access_key = "secret"
          @config.ssh_key_path = TEST_SSH_KEY_PATH

          error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
          assert_match(/access_key_id/, error.message)
        end

        def test_validate_raises_without_secret_access_key
          @config.access_key_id = "AKIAIOSFODNN7EXAMPLE"
          @config.ssh_key_path = TEST_SSH_KEY_PATH

          error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
          assert_match(/secret_access_key/, error.message)
        end

        def test_validate_raises_without_ssh_key_path
          @config.access_key_id = "AKIAIOSFODNN7EXAMPLE"
          @config.secret_access_key = "secret"

          error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
          assert_match(/ssh_key_path/, error.message)
        end

        def test_validate_passes_with_credentials
          @config.access_key_id = "AKIAIOSFODNN7EXAMPLE"
          @config.secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
          @config.ssh_key_path = TEST_SSH_KEY_PATH

          assert_nil @config.validate!
        end

        def test_client_returns_aws_client
          @config.access_key_id = "AKIAIOSFODNN7EXAMPLE"
          @config.secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
          @config.region = "us-east-1"

          assert_instance_of Clients::Compute::Aws, @config.client
        end

        def test_supports_self_hosted
          assert_predicate @config, :supports_self_hosted?
        end

        def test_add_server_group
          @config.add_server_group(:web, type: "t3.medium", count: 2)

          assert_predicate @config, :multi_server?
          assert_equal "t3.medium", @config.servers[:web].type
          assert_equal 2, @config.servers[:web].count
        end
      end
    end
  end
end
