# frozen_string_literal: true

require "net/ssh"
require "net/scp"
require "shellwords"
require "base64"

module RbrunCore
  module Clients
    # SSH utility for remote command execution and file transfers.
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
      def execute(command, cwd: nil, timeout: nil, raise_on_error: true, &)
        full_command = build_command(command, cwd:)

        with_ssh_session(timeout:) do |ssh|
          output = String.new
          exit_code = nil

          channel = ssh.open_channel do |ch|
            ch.exec(full_command) do |ch2, success|
              raise Error, "Failed to execute command" unless success

              ch2.eof!

              ch2.on_data do |_, data|
                output << data
                yield_lines(data, &) if block_given?
              end

              ch2.on_extended_data do |_, _, data|
                output << data
                yield_lines(data, &) if block_given?
              end

              ch2.on_request("exit-status") do |_, data|
                exit_code = data.read_long
              end
            end
          end

          channel.wait
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
        with_ssh_session(timeout:) do |ssh|
          result = ssh.exec!("echo ok")
          result&.strip == "ok"
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
        with_ssh_session do |ssh|
          ssh.scp.upload!(local_path, remote_path)
        end
        true
      end

      # Upload content directly to a remote file.
      def upload_content(content, remote_path, mode: "0644")
        with_ssh_session do |ssh|
          dir = File.dirname(remote_path)
          ssh.exec!("mkdir -p #{Shellwords.escape(dir)}")

          encoded = Base64.strict_encode64(content)
          ssh.exec!("echo #{Shellwords.escape(encoded)} | base64 -d > #{Shellwords.escape(remote_path)}")
          ssh.exec!("chmod #{mode} #{Shellwords.escape(remote_path)}")
        end
        true
      end

      # Download a file from the remote server.
      def download(remote_path, local_path)
        with_ssh_session do |ssh|
          ssh.scp.download!(remote_path, local_path)
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

      private

        def build_command(command, cwd: nil)
          if cwd
            "cd #{Shellwords.escape(cwd)} && #{command}"
          else
            command
          end
        end

        def yield_lines(data)
          data.each_line do |line|
            yield line.chomp
          end
        end

        def with_ssh_session(timeout: nil, &)
          options = {
            key_data: [ @private_key ],
            non_interactive: true,
            verify_host_key: @strict_mode ? :accept_new : :never,
            logger: Logger.new(IO::NULL),
            timeout: timeout || 30
          }

          Net::SSH.start(@host, @user, options, &)
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
        end
    end
  end
end
