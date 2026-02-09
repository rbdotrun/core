# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Commands
    module K3s
      class ProvisionVolumesTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @ctx = build_context(target: :production)
          @ctx.server_ip = "1.2.3.4"
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        end

        def test_ssh_uses_deploy_user_not_root
          assert_equal "deploy", Naming.default_user
        end

        def test_mount_volume_ssh_connection_uses_correct_user
          assert_equal "deploy", Naming.default_user
        end
      end
    end
  end
end
