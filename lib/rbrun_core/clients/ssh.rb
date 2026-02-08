# frozen_string_literal: true

require "sshkit"
require "shellwords"
require "base64"
require "stringio"
require "concurrent/atomic/count_down_latch"

module RbrunCore
  module Clients
    # SSH utility for remote command execution and file transfers.
    # Wraps SSHKit while maintaining the original API.
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

        @sshkit_host = SSHKit::Host.new("#{@user}@#{@host}:#{@port}").tap do |h|
          h.ssh_options = ssh_options
        end
      end

      # Execute a command on the remote server.
      def execute(command, cwd: nil, timeout: nil, raise_on_error: true, &block)
        full_command = build_command(command, cwd:)
        output = String.new
        exit_code = nil

        with_backend(timeout:) do |backend|
          # Use capture to get output, but we need to handle exit codes
          begin
            result = backend.capture(full_command, verbosity: :debug, strip: false)
            output = result.to_s
            exit_code = 0

            yield_lines(output, &block) if block_given?
          rescue SSHKit::Command::Failed => e
            # SSHKit wraps the command, extract exit code from it
            exit_code = e.cause.is_a?(SSHKit::Command) ? e.cause.exit_status : 1
            output = e.message
            yield_lines(output, &block) if block_given?

            if raise_on_error
              raise CommandError.new(
                "Command failed (exit code: #{exit_code}): #{command}",
                exit_code:,
                output: output.strip
              )
            end
          end
        end

        { output: output.strip, exit_code: exit_code || 0 }
      end

      # Execute a command with retry on ConnectionError.
      def execute_with_retry(command, retries: 3, backoff: 2, **)
        Waiter.retry_with_backoff(retries:, backoff:, on: ConnectionError) do
          execute(command, **)
        end
      end

      # Execute a command, ignoring errors.
      def execute_ignore_errors(command, cwd: nil)
        execute(command, cwd:, raise_on_error: false)
      rescue Error
        nil
      end

      # Check if SSH connection is available.
      def available?(timeout: 10)
        with_backend(timeout:) do |backend|
          result = backend.capture("echo ok", verbosity: :debug)
          result.strip == "ok"
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
        with_backend do |backend|
          backend.upload!(local_path, remote_path)
        end
        true
      end

      # Upload content directly to a remote file.
      def upload_content(content, remote_path, mode: "0644")
        with_backend do |backend|
          dir = File.dirname(remote_path)
          backend.execute(:mkdir, "-p", dir)

          # Upload via StringIO
          io = StringIO.new(content)
          backend.upload!(io, remote_path)
          backend.execute(:chmod, mode, remote_path)
        end
        true
      end

      # Download a file from the remote server.
      def download(remote_path, local_path)
        with_backend do |backend|
          backend.download!(remote_path, local_path)
        end
        true
      end

      # Read a remote file's content.
      def read_file(remote_path)
        result = execute("cat #{Shellwords.escape(remote_path)}", raise_on_error: false)
        result[:exit_code].zero? ? result[:output] : nil
      end

      # Write content to a remote file.
      def write_file(remote_path, content, append: false)
        upload_content(content, remote_path)
      end

      # Establish an SSH local port forward and yield while the tunnel is active.
      # Follows Kamal's pattern for SSH tunneling.
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

        def yield_lines(data)
          data.to_s.each_line do |line|
            yield line.chomp
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

        def with_backend(timeout: nil)
          # Create a backend with custom timeout if specified
          backend = SSHKit::Backend::Netssh.new(@sshkit_host)

          if timeout
            original_options = @sshkit_host.ssh_options.dup
            @sshkit_host.ssh_options = original_options.merge(timeout:)
          end

          yield backend
        rescue Net::SSH::AuthenticationFailed => e
          raise AuthenticationError, "SSH authentication failed for #{@user}@#{@host}: #{e.message}"
        rescue Net::SSH::ConnectionTimeout => e
          raise ConnectionError, "SSH connection timeout to #{@host}: #{e.message}"
        rescue Errno::ECONNREFUSED => e
          raise ConnectionError, "SSH connection refused by #{@host}: #{e.message}"
        rescue Errno::EHOSTUNREACH => e
          raise ConnectionError, "Host unreachable: #{@host}: #{e.message}"
        rescue SocketError => e
          raise ConnectionError, "Socket error connecting to #{@host}: #{e.message}"
        ensure
          @sshkit_host.ssh_options = original_options if timeout && original_options
        end
    end
  end
end
