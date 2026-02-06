# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Config
    module Compute
      class ScalewayTest < Minitest::Test
        def setup
          super
          @config = Scaleway.new
        end

        # Basic tests
        def test_provider_name_is_scaleway
          assert_equal :scaleway, @config.provider_name
        end

        def test_default_zone
          assert_equal "fr-par-1", @config.zone
        end

        def test_default_image
          assert_equal "ubuntu_jammy", @config.image
        end

        # Location alias tests
        def test_location_returns_zone
          @config.zone = "nl-ams-1"

          assert_equal "nl-ams-1", @config.location
        end

        def test_location_setter_sets_zone
          @config.location = "pl-waw-1"

          assert_equal "pl-waw-1", @config.zone
        end

        # Server group tests
        def test_add_server_group
          @config.add_server_group(:web, type: "DEV1-M", count: 3)

          assert_equal "DEV1-M", @config.servers[:web].type
          assert_equal 3, @config.servers[:web].count
        end

        def test_multi_server_returns_false_without_groups
          refute_predicate @config, :multi_server?
        end

        def test_multi_server_returns_true_with_groups
          @config.add_server_group(:api, type: "DEV1-S", count: 2)

          assert_predicate @config, :multi_server?
        end

        # SSH key tests
        def test_ssh_keys_configured_returns_false_without_path
          refute_predicate @config, :ssh_keys_configured?
        end

        def test_ssh_keys_configured_returns_true_with_valid_path
          @config.ssh_key_path = TEST_SSH_KEY_PATH

          assert_predicate @config, :ssh_keys_configured?
        end

        def test_read_ssh_keys_returns_keys
          @config.ssh_key_path = TEST_SSH_KEY_PATH
          keys = @config.read_ssh_keys

          assert keys[:private_key].start_with?("-----BEGIN")
          assert keys[:public_key].start_with?("ssh-rsa")
        end

        def test_ssh_private_key_returns_key_content
          @config.ssh_key_path = TEST_SSH_KEY_PATH
          key = @config.ssh_private_key

          assert key.start_with?("-----BEGIN")
        end

        def test_ssh_public_key_returns_key_content
          @config.ssh_key_path = TEST_SSH_KEY_PATH
          key = @config.ssh_public_key

          assert key.start_with?("ssh-rsa")
        end

        # Validation tests
        def test_validate_raises_without_api_key
          @config.project_id = "test-project"
          @config.ssh_key_path = TEST_SSH_KEY_PATH

          error = assert_raises(RbrunCore::ConfigurationError) { @config.validate! }
          assert_match(/api_key/, error.message)
        end

        def test_validate_raises_without_project_id
          @config.api_key = "test-key"
          @config.ssh_key_path = TEST_SSH_KEY_PATH

          error = assert_raises(RbrunCore::ConfigurationError) { @config.validate! }
          assert_match(/project_id/, error.message)
        end

        def test_validate_raises_without_ssh_key_path
          @config.api_key = "test-key"
          @config.project_id = "test-project"

          error = assert_raises(RbrunCore::ConfigurationError) { @config.validate! }
          assert_match(/ssh_key_path/, error.message)
        end

        def test_validate_passes_with_all_credentials
          @config.api_key = "test-key"
          @config.project_id = "test-project"
          @config.ssh_key_path = TEST_SSH_KEY_PATH

          assert_nil @config.validate!
        end

        # Client test
        def test_client_returns_scaleway_client
          @config.api_key = "test-key"
          @config.project_id = "test-project"
          @config.zone = "fr-par-1"

          assert_instance_of Clients::Compute::Scaleway, @config.client
        end

        # supports_self_hosted test
        def test_supports_self_hosted
          assert_predicate @config, :supports_self_hosted?
        end
      end
    end
  end
end
