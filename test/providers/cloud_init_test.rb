# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Providers
    class CloudInitTest < Minitest::Test
      def test_generate_returns_cloud_config
        result = CloudInit.generate(ssh_public_key: "ssh-rsa AAAA...")

        assert result.start_with?("#cloud-config")
      end

      def test_generate_creates_user_with_custom_name
        result = CloudInit.generate(ssh_public_key: "ssh-rsa AAAA...", user: "customuser")

        assert_includes result, "name: customuser"
      end

      def test_generate_adds_groups
        result = CloudInit.generate(ssh_public_key: "ssh-rsa AAAA...")

        assert_includes result, "groups: sudo,docker"
      end

      def test_generate_sets_bash_shell
        result = CloudInit.generate(ssh_public_key: "ssh-rsa AAAA...")

        assert_includes result, "shell: /bin/bash"
      end

      def test_generate_allows_passwordless_sudo
        result = CloudInit.generate(ssh_public_key: "ssh-rsa AAAA...")

        assert_includes result, "sudo: ALL=(ALL) NOPASSWD:ALL"
      end

      def test_generate_adds_ssh_key
        result = CloudInit.generate(ssh_public_key: "ssh-rsa TESTKEY123")

        assert_includes result, "ssh-rsa TESTKEY123"
      end

      def test_generate_disables_root_and_password
        result = CloudInit.generate(ssh_public_key: "ssh-rsa AAAA...")

        assert_includes result, "disable_root: true"
        assert_includes result, "ssh_pwauth: false"
      end

      def test_default_user_from_naming
        result = CloudInit.generate(ssh_public_key: "ssh-rsa AAAA...")

        assert_includes result, "name: #{RbrunCore::Naming.default_user}"
      end
    end
  end
end
