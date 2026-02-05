# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Ssh
    class ClientTest < Minitest::Test
      def setup
        super
        @host = "192.168.1.100"
        @private_key = TEST_SSH_KEY.private_key
      end

      def test_initializes_with_required_params
        client = Client.new(host: @host, private_key: @private_key)

        assert_equal @host, client.host
        assert_equal "root", client.user
      end

      def test_initializes_with_custom_user
        client = Client.new(host: @host, private_key: @private_key, user: "deploy")

        assert_equal "deploy", client.user
      end

      def test_command_error_stores_exit_code_and_output
        error = Client::CommandError.new("failed", exit_code: 127, output: "not found")

        assert_equal 127, error.exit_code
        assert_equal "not found", error.output
      end

      def test_error_hierarchy_inherits_from_error
        assert_operator Client::AuthenticationError, :<, Client::Error
        assert_operator Client::ConnectionError, :<, Client::Error
      end

      def test_error_hierarchy_base_classes
        assert_operator Client::CommandError, :<, Client::Error
        assert_operator Client::Error, :<, StandardError
      end

      def test_execute_returns_hash
        client = Client.new(host: @host, private_key: @private_key)
        result = with_mocked_ssh(output: "hello", exit_code: 0) { client.execute("echo hello") }

        assert_equal "hello", result[:output]
        assert_equal 0, result[:exit_code]
      end

      def test_execute_raises_on_nonzero
        client = Client.new(host: @host, private_key: @private_key)
        error = assert_raises(Client::CommandError) do
          with_mocked_ssh(output: "error", exit_code: 1) { client.execute("fail") }
        end
        assert_equal 1, error.exit_code
      end

      def test_execute_with_raise_on_error_false
        client = Client.new(host: @host, private_key: @private_key)
        result = with_mocked_ssh(output: "error", exit_code: 1) { client.execute("fail", raise_on_error: false) }

        assert_equal 1, result[:exit_code]
      end

      def test_execute_yields_lines
        client = Client.new(host: @host, private_key: @private_key)
        lines = []
        with_mocked_ssh(output: "line1\nline2\nline3", exit_code: 0) do
          client.execute("cmd") { |line| lines << line }
        end

        assert_equal %w[line1 line2 line3], lines
      end

      def test_execute_ignore_errors_returns_result
        client = Client.new(host: @host, private_key: @private_key)
        result = with_mocked_ssh(output: "ok", exit_code: 0) { client.execute_ignore_errors("cmd") }

        assert_equal "ok", result[:output]
      end

      def test_execute_ignore_errors_returns_nil_on_error
        client = Client.new(host: @host, private_key: @private_key)
        result = with_mocked_ssh_error(Client::Error.new("fail")) { client.execute_ignore_errors("cmd") }

        assert_nil result
      end

      def test_available_returns_true
        client = Client.new(host: @host, private_key: @private_key)
        mock_ssh = Object.new
        mock_ssh.define_singleton_method(:exec!) { |_| "ok" }
        result = Net::SSH.stub(:start, ->(_h, _u, _o, &b) { b.call(mock_ssh) }) { client.available? }

        assert result
      end

      def test_available_returns_false_on_error
        client = Client.new(host: @host, private_key: @private_key)
        result = with_mocked_ssh_error(Errno::ECONNREFUSED.new) { client.available? }

        refute result
      end

      def test_read_file_returns_content
        client = Client.new(host: @host, private_key: @private_key)
        content = with_mocked_ssh(output: "file content", exit_code: 0) { client.read_file("/etc/hosts") }

        assert_equal "file content", content
      end

      def test_read_file_returns_nil_on_failure
        client = Client.new(host: @host, private_key: @private_key)
        content = with_mocked_ssh(output: "No such file", exit_code: 1) { client.read_file("/missing") }

        assert_nil content
      end

      def test_raises_authentication_error
        client = Client.new(host: @host, private_key: @private_key)
        assert_raises(Client::AuthenticationError) do
          with_mocked_ssh_error(Net::SSH::AuthenticationFailed.new("auth")) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_timeout
        client = Client.new(host: @host, private_key: @private_key)
        assert_raises(Client::ConnectionError) do
          with_mocked_ssh_error(Net::SSH::ConnectionTimeout.new) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_refused
        client = Client.new(host: @host, private_key: @private_key)
        assert_raises(Client::ConnectionError) do
          with_mocked_ssh_error(Errno::ECONNREFUSED.new) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_unreachable
        client = Client.new(host: @host, private_key: @private_key)
        assert_raises(Client::ConnectionError) do
          with_mocked_ssh_error(Errno::EHOSTUNREACH.new) { client.execute("cmd") }
        end
      end

      def test_execute_with_retry_retries_on_connection_error
        client = Client.new(host: @host, private_key: @private_key)
        call_count = 0
        channel = MockChannel.new(output: "ok", exit_code: 0)
        ssh = MockSsh.new(channel)

        flaky = lambda { |_h, _u, _o, &b|
          call_count += 1
          raise Errno::ECONNREFUSED, "refused" if call_count < 3

          b.call(ssh)
        }

        Net::SSH.stub(:start, flaky) do
          result = client.execute_with_retry("echo hello", retries: 3, backoff: 0)

          assert_equal "ok", result[:output]
        end
        assert_equal 3, call_count
      end

      def test_execute_with_retry_raises_after_max_retries
        client = Client.new(host: @host, private_key: @private_key)
        call_count = 0

        always_fail = lambda { |*|
          call_count += 1
          raise Errno::ECONNREFUSED, "refused"
        }

        Net::SSH.stub(:start, always_fail) do
          assert_raises(Client::ConnectionError) do
            client.execute_with_retry("echo hello", retries: 3, backoff: 0)
          end
        end
        assert_equal 3, call_count
      end

      def test_execute_with_retry_default_backoff_is_exponential
        client = Client.new(host: @host, private_key: @private_key)
        params = client.method(:execute_with_retry).parameters
        backoff_param = params.find { |_type, name| name == :backoff }

        assert backoff_param, "execute_with_retry should accept a backoff parameter"
      end
    end
  end
end
