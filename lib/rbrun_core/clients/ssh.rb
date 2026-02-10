# frozen_string_literal: true

require "net/ssh"
require "net/scp"
require "shellwords"
require "stringio"
require "concurrent/atomic/count_down_latch"

module RbrunCore
  module Clients
    # SSH utility for remote command execution and file transfers.
    # Uses Net::SSH directly for streaming support.
    class Ssh
      class Error < StandardError; end
      class AuthenticationError < Error; end
      class ConnectionError < Error; end

      class CommandError < Error
        attr_reader :exit_code, :output

        def initialize(message, exit_code:, output:)
          @exit_code = exit_code
          @output = output
          super(message)
        end
      end

      attr_reader :host, :user

      def initialize(host:, private_key:, user: "root", port: 22, strict_host_key_checking: false)
        @host = host
        @private_key = private_key
        @user = user
        @port = port
        @strict_mode = strict_host_key_checking
      end

      # Execute a command on the remote server.
      def execute(command, cwd: nil, timeout: nil, raise_on_error: true)
        full_command = build_command(command, cwd:)
        output = String.new
        exit_code = nil
        line_buffer = String.new

        with_connection(timeout:) do |ssh|
          channel = ssh.open_channel do |ch|
            ch.exec(full_command) do |_, success|
              raise ConnectionError, "Failed to execute command" unless success

              handle_data = ->(data) do
                if block_given?
                  line_buffer << data
                  while (idx = line_buffer.index("\n"))
                    yield line_buffer.slice!(0..idx).chomp
                  end
                else
                  output << data
                end
              end

              ch.on_data { |_, data| handle_data.call(data) }
              ch.on_extended_data { |_, _, data| handle_data.call(data) }
              ch.on_request("exit-status") { |_, data| exit_code = data.read_long }
            end
          end
          channel.wait
          yield line_buffer.chomp if block_given? && !line_buffer.empty?
        end

        exit_code ||= 0
        if raise_on_error && exit_code != 0
          raise CommandError.new(
            "Command failed (exit code: #{exit_code}): #{command}",
            exit_code:,
            output: output.strip
          )
        end

        { output: output.strip, exit_code: }
      end

      # Execute a command with retry on ConnectionError.
      def execute_with_retry(command, retries: 3, backoff: 2, **)
        Waiter.retry_with_backoff(retries:, backoff:, on: ConnectionError) do
          execute(command, **)
        end
      end

      # Check if SSH connection is available.
      def available?(timeout: 10)
        with_connection(timeout:) do |ssh|
          result = ssh.exec!("echo ok")
          result.to_s.strip == "ok"
        end
      rescue Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError
        false
      end

      # Wait for SSH to become available.
      def wait_until_ready(max_attempts: 60, interval: 5)
        Waiter.poll(max_attempts:, interval:, message: "SSH not available after #{max_attempts} attempts") do
          available?(timeout: 10)
        end
        true
      end

      # Upload a file to the remote server.
      def upload(local_path, remote_path)
        with_connection { |ssh| ssh.scp.upload!(local_path, remote_path) }
        true
      end

      # Download a file from the remote server.
      def download(remote_path, local_path)
        with_connection { |ssh| ssh.scp.download!(remote_path, local_path) }
        true
      end

      # Upload content directly to a remote file.
      def upload_content(content, remote_path, mode: "0644")
        with_connection do |ssh|
          ssh.exec!("mkdir -p #{Shellwords.escape(File.dirname(remote_path))}")
          ssh.scp.upload!(StringIO.new(content), remote_path)
          ssh.exec!("chmod #{mode} #{Shellwords.escape(remote_path)}")
        end
        true
      end

      # Read a remote file's content.
      def read_file(remote_path)
        result = execute("cat #{Shellwords.escape(remote_path)}", raise_on_error: false)
        result[:exit_code].zero? ? result[:output] : nil
      end

      # Establish an SSH local port forward and yield while the tunnel is active.
      def with_local_forward(local_port:, remote_host:, remote_port:)
        ready = Concurrent::CountDownLatch.new(1)
        @forward_done = false

        thread = Thread.new do
          Net::SSH.start(@host, @user, **ssh_options.merge(port: @port)) do |ssh|
            ssh.forward.local(local_port, remote_host, remote_port)
            ready.count_down

            ssh.loop(0.1) { !@forward_done }
          end
        rescue
          ready.count_down # unblock even on error
          raise
        end

        raise ConnectionError, "SSH tunnel not ready after 30s" unless ready.wait(30)

        begin
          yield
        ensure
          @forward_done = true
          thread.join(5)
        end
      end

      private

        def build_command(command, cwd: nil)
          if cwd
            "cd #{Shellwords.escape(cwd)} && #{command}"
          else
            command
          end
        end

        def ssh_options
          {
            keys_only: true,
            keys: [],
            key_data: [ @private_key ],
            verify_host_key: @strict_mode ? :accept_new : :never,
            logger: ::Logger.new(IO::NULL)
          }
        end

        def with_connection(timeout: nil)
          options = ssh_options.merge(port: @port)
          options[:timeout] = timeout if timeout
          Net::SSH.start(@host, @user, **options) { |ssh| yield ssh }
        rescue Net::SSH::AuthenticationFailed => e
          raise AuthenticationError, "SSH auth failed: #{e.message}"
        rescue Net::SSH::ConnectionTimeout, Net::SSH::Disconnect,
               Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, IOError => e
          raise ConnectionError, "SSH connection failed: #{e.message}"
        end
    end
  end
end
