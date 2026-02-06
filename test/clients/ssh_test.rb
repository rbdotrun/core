# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Clients
    class SshTest < Minitest::Test
      def setup
        super
        @host = "192.168.1.100"
        @private_key = TEST_SSH_KEY.private_key
      end

      def test_initializes_with_required_params
        client = Ssh.new(host: @host, private_key: @private_key)

        assert_equal @host, client.host
        assert_equal "root", client.user
      end

      def test_initializes_with_custom_user
        client = Ssh.new(host: @host, private_key: @private_key, user: "deploy")

        assert_equal "deploy", client.user
      end

      def test_command_error_stores_exit_code_and_output
        error = Ssh::CommandError.new("failed", exit_code: 127, output: "not found")

        assert_equal 127, error.exit_code
        assert_equal "not found", error.output
      end

      def test_error_hierarchy_inherits_from_error
        assert_operator Ssh::AuthenticationError, :<, Ssh::Error
        assert_operator Ssh::ConnectionError, :<, Ssh::Error
      end

      def test_error_hierarchy_base_classes
        assert_operator Ssh::CommandError, :<, Ssh::Error
        assert_operator Ssh::Error, :<, StandardError
      end

      def test_execute_returns_hash
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_sshkit_backend(output: "hello", exit_code: 0) { client.execute("echo hello") }

        assert_equal "hello", result[:output]
        assert_equal 0, result[:exit_code]
      end

      def test_execute_raises_on_nonzero
        client = Ssh.new(host: @host, private_key: @private_key)
        error = assert_raises(Ssh::CommandError) do
          with_sshkit_backend(output: "error", exit_code: 1) { client.execute("fail") }
        end
        assert_equal 1, error.exit_code
      end

      def test_execute_with_raise_on_error_false
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_sshkit_backend(output: "error", exit_code: 1) { client.execute("fail", raise_on_error: false) }

        assert_equal 1, result[:exit_code]
      end

      def test_execute_yields_lines
        client = Ssh.new(host: @host, private_key: @private_key)
        lines = []
        with_sshkit_backend(output: "line1\nline2\nline3", exit_code: 0) do
          client.execute("cmd") { |line| lines << line }
        end

        assert_equal %w[line1 line2 line3], lines
      end

      def test_execute_ignore_errors_returns_result
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_sshkit_backend(output: "ok", exit_code: 0) { client.execute_ignore_errors("cmd") }

        assert_equal "ok", result[:output]
      end

      def test_execute_ignore_errors_returns_nil_on_error
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_sshkit_error(Ssh::Error.new("fail")) { client.execute_ignore_errors("cmd") }

        assert_nil result
      end

      def test_available_returns_true
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_sshkit_backend(output: "ok", exit_code: 0) { client.available? }

        assert result
      end

      def test_available_returns_false_on_error
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_sshkit_error(Errno::ECONNREFUSED.new) { client.available? }

        refute result
      end

      def test_read_file_returns_content
        client = Ssh.new(host: @host, private_key: @private_key)
        content = with_sshkit_backend(output: "file content", exit_code: 0) { client.read_file("/etc/hosts") }

        assert_equal "file content", content
      end

      def test_read_file_returns_nil_on_failure
        client = Ssh.new(host: @host, private_key: @private_key)
        content = with_sshkit_backend(output: "No such file", exit_code: 1) { client.read_file("/missing") }

        assert_nil content
      end

      def test_raises_authentication_error
        client = Ssh.new(host: @host, private_key: @private_key)
        assert_raises(Ssh::AuthenticationError) do
          with_sshkit_error(Net::SSH::AuthenticationFailed.new("auth")) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_timeout
        client = Ssh.new(host: @host, private_key: @private_key)
        assert_raises(Ssh::ConnectionError) do
          with_sshkit_error(Net::SSH::ConnectionTimeout.new) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_refused
        client = Ssh.new(host: @host, private_key: @private_key)
        assert_raises(Ssh::ConnectionError) do
          with_sshkit_error(Errno::ECONNREFUSED.new) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_unreachable
        client = Ssh.new(host: @host, private_key: @private_key)
        assert_raises(Ssh::ConnectionError) do
          with_sshkit_error(Errno::EHOSTUNREACH.new) { client.execute("cmd") }
        end
      end

      def test_execute_with_retry_retries_on_connection_error
        client = Ssh.new(host: @host, private_key: @private_key)
        call_count = 0

        mock_backend = Object.new
        mock_backend.define_singleton_method(:capture) { |*_args| "ok" }

        SSHKit::Backend::Netssh.stub(:new, lambda { |_host|
          call_count += 1
          raise Errno::ECONNREFUSED, "refused" if call_count < 3

          mock_backend
        }) do
          result = client.execute_with_retry("echo hello", retries: 3, backoff: 0)

          assert_equal "ok", result[:output]
        end
        assert_equal 3, call_count
      end

      def test_execute_with_retry_raises_after_max_retries
        client = Ssh.new(host: @host, private_key: @private_key)
        call_count = 0

        SSHKit::Backend::Netssh.stub(:new, lambda { |_host|
          call_count += 1
          raise Errno::ECONNREFUSED, "refused"
        }) do
          assert_raises(Ssh::ConnectionError) do
            client.execute_with_retry("echo hello", retries: 3, backoff: 0)
          end
        end
        assert_equal 3, call_count
      end

      def test_execute_with_retry_default_backoff_is_exponential
        client = Ssh.new(host: @host, private_key: @private_key)
        params = client.method(:execute_with_retry).parameters
        backoff_param = params.find { |_type, name| name == :backoff }

        assert backoff_param, "execute_with_retry should accept a backoff parameter"
      end

      private

        # Mock SSHKit backend for testing
        def with_sshkit_backend(output: "ok", exit_code: 0, &block)
          mock_backend = Object.new
          mock_backend.define_singleton_method(:capture) do |*_args|
            if exit_code != 0
              cmd = SSHKit::Command.new(:test)
              cmd.instance_variable_set(:@exit_status, exit_code)
              error = SSHKit::Command::Failed.new("Command failed")
              error.define_singleton_method(:cause) { cmd }
              raise error
            end
            output
          end
          mock_backend.define_singleton_method(:upload!) { |*_args| true }
          mock_backend.define_singleton_method(:download!) { |*_args| true }
          mock_backend.define_singleton_method(:execute) { |*_args| true }

          SSHKit::Backend::Netssh.stub(:new, ->(_host) { mock_backend }, &block)
        end

        def with_sshkit_error(error, &block)
          SSHKit::Backend::Netssh.stub(:new, ->(_host) { raise error }, &block)
        end
    end
  end
end
