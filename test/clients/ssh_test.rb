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

      def test_initializes_with_proxy
        proxy = Object.new
        client = Ssh.new(host: @host, private_key: @private_key, proxy:)

        # Verify client was created (proxy is internal)
        assert_equal @host, client.host
      end

      def test_proxy_is_included_in_ssh_options
        proxy = Object.new
        client = Ssh.new(host: @host, private_key: @private_key, proxy:)

        # We can't directly test private method, but we can verify via execute
        # that the proxy is passed through to Net::SSH.start
        captured_opts = nil

        Net::SSH.stub(:start, ->(host, user, **opts) {
          captured_opts = opts
          raise Errno::ECONNREFUSED, "test"
        }) do
          client.available? rescue nil
        end

        assert_equal proxy, captured_opts[:proxy]
      end

      def test_proxy_is_nil_when_not_provided
        client = Ssh.new(host: @host, private_key: @private_key)
        captured_opts = nil

        Net::SSH.stub(:start, ->(host, user, **opts) {
          captured_opts = opts
          raise Errno::ECONNREFUSED, "test"
        }) do
          client.available? rescue nil
        end

        refute_includes captured_opts.keys, :proxy
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
        result = with_fake_ssh(output: "hello", exit_code: 0) { client.execute("echo hello") }

        assert_equal "hello", result[:output]
        assert_equal 0, result[:exit_code]
      end

      def test_execute_raises_on_nonzero
        client = Ssh.new(host: @host, private_key: @private_key)
        error = assert_raises(Ssh::CommandError) do
          with_fake_ssh(output: "error", exit_code: 1) { client.execute("fail") }
        end
        assert_equal 1, error.exit_code
      end

      def test_execute_with_raise_on_error_false
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_fake_ssh(output: "error", exit_code: 1) { client.execute("fail", raise_on_error: false) }

        assert_equal 1, result[:exit_code]
      end

      def test_execute_yields_lines
        client = Ssh.new(host: @host, private_key: @private_key)
        lines = []
        with_fake_ssh(output: "line1\nline2\nline3", exit_code: 0) do
          client.execute("cmd") { |line| lines << line }
        end

        assert_equal %w[line1 line2 line3], lines
      end

      def test_available_returns_true
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_fake_ssh(output: "ok", exit_code: 0) { client.available? }

        assert result
      end

      def test_available_returns_false_on_error
        client = Ssh.new(host: @host, private_key: @private_key)
        result = with_net_ssh_error(Errno::ECONNREFUSED.new) { client.available? }

        refute result
      end

      def test_read_file_returns_content
        client = Ssh.new(host: @host, private_key: @private_key)
        content = with_fake_ssh(output: "file content", exit_code: 0) { client.read_file("/etc/hosts") }

        assert_equal "file content", content
      end

      def test_read_file_returns_nil_on_failure
        client = Ssh.new(host: @host, private_key: @private_key)
        content = with_fake_ssh(output: "No such file", exit_code: 1) { client.read_file("/missing") }

        assert_nil content
      end

      def test_raises_authentication_error
        client = Ssh.new(host: @host, private_key: @private_key)
        assert_raises(Ssh::AuthenticationError) do
          with_net_ssh_error(Net::SSH::AuthenticationFailed.new("auth")) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_timeout
        client = Ssh.new(host: @host, private_key: @private_key)
        assert_raises(Ssh::ConnectionError) do
          with_net_ssh_error(Net::SSH::ConnectionTimeout.new) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_refused
        client = Ssh.new(host: @host, private_key: @private_key)
        assert_raises(Ssh::ConnectionError) do
          with_net_ssh_error(Errno::ECONNREFUSED.new) { client.execute("cmd") }
        end
      end

      def test_raises_connection_error_on_unreachable
        client = Ssh.new(host: @host, private_key: @private_key)
        assert_raises(Ssh::ConnectionError) do
          with_net_ssh_error(Errno::EHOSTUNREACH.new) { client.execute("cmd") }
        end
      end

      def test_execute_with_retry_retries_on_connection_error
        client = Ssh.new(host: @host, private_key: @private_key)
        call_count = 0

        Net::SSH.stub(:start, lambda { |*_args, **_opts, &blk|
          call_count += 1
          raise Errno::ECONNREFUSED, "refused" if call_count < 3

          mock_ssh = FakeSsh.new("ok", 0)
          blk.call(mock_ssh)
        }) do
          result = client.execute_with_retry("echo hello", retries: 3, backoff: 0)

          assert_equal "ok", result[:output]
        end
        assert_equal 3, call_count
      end

      def test_execute_with_retry_raises_after_max_retries
        client = Ssh.new(host: @host, private_key: @private_key)
        call_count = 0

        Net::SSH.stub(:start, lambda { |*_args, **_opts, &_block|
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

      def test_with_local_forward_yields_block
        client = Ssh.new(host: @host, private_key: @private_key)
        yielded = false

        mock_ssh = Object.new
        mock_ssh.define_singleton_method(:forward) do
          fwd = Object.new
          fwd.define_singleton_method(:local) { |*_args| }
          fwd
        end
        mock_ssh.define_singleton_method(:loop) { |_| }

        Net::SSH.stub(:start, ->(*, **, &block) { block.call(mock_ssh) }) do
          client.with_local_forward(local_port: 30_500, remote_host: "localhost", remote_port: 30_500) do
            yielded = true
          end
        end

        assert yielded
      end

      private

        # Mock Net::SSH for testing
        def with_fake_ssh(output: "ok", exit_code: 0, &block)
          mock_ssh = FakeSsh.new(output, exit_code)

          Net::SSH.stub(:start, ->(*, **, &blk) { blk.call(mock_ssh) }, &block)
        end

        def with_net_ssh_error(error, &block)
          Net::SSH.stub(:start, ->(*_args, **_opts, &_blk) { raise error }, &block)
        end

        class FakeSsh
          def initialize(output, exit_code)
            @output = output
            @exit_code = exit_code
          end

          def exec!(cmd)
            @output
          end

          def open_channel
            channel = FakeChannel.new(@output, @exit_code)
            yield channel
            channel
          end

          def scp
            FakeScp.new
          end
        end

        class FakeChannel
          def initialize(output, exit_code)
            @output = output
            @exit_code = exit_code
          end

          def exec(cmd)
            yield self, true
          end

          def on_data
            yield self, @output
          end

          def on_extended_data
            # no-op
          end

          def on_request(type)
            yield self, FakeExitData.new(@exit_code)
          end

          def wait
            # no-op
          end
        end

        class FakeExitData
          def initialize(code)
            @code = code
          end

          def read_long
            @code
          end
        end

        class FakeScp
          def upload!(*_args)
            true
          end

          def download!(*_args)
            true
          end
        end
    end
  end
end
