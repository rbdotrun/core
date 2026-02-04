# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Cloudflare
    class WorkerTest < Minitest::Test
      def test_generates_worker_script_with_access_token
        script = Worker.generate(slug: "a1b2c3", access_token: "secret-token")
        assert_includes script, "ACCESS_TOKEN"
      end

      def test_script_contains_cookie_name
        script = Worker.script
        assert_includes script, RbrunCore::Naming.auth_cookie
      end
    end
  end
end
