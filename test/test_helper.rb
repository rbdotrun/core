# frozen_string_literal: true

# Suppress net-ssh 7.3.0 warning about method redefinition
$VERBOSE = nil
require "net/ssh"
$VERBOSE = true

require "bundler/setup"

require "simplecov"
require "simplecov-cobertura"
SimpleCov.start do
  add_filter "/test/"
  enable_coverage :branch
  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter
  ])
end

require "rbrun_core"
require "minitest/autorun"
require "webmock/minitest"
require "sshkey"

# Pre-generate SSH keypair once (avoids 200-500ms per test)
TEST_SSH_KEY = SSHKey.generate(type: "RSA", bits: 4096, comment: "rbrun-core-test")
TEST_SSH_KEY_DIR = Dir.mktmpdir("rbrun-core-test-keys")
TEST_SSH_KEY_PATH = File.join(TEST_SSH_KEY_DIR, "id_rsa")
File.write(TEST_SSH_KEY_PATH, TEST_SSH_KEY.private_key)
File.write("#{TEST_SSH_KEY_PATH}.pub", TEST_SSH_KEY.ssh_public_key)
Minitest.after_run { FileUtils.rm_rf(TEST_SSH_KEY_DIR) }

# ── SSH mock client ──

class MockSshClient
  attr_reader :host, :user, :commands

  def initialize(host:, private_key:, user: "root", output: "ok",
                 exit_code: 0, exit_code_for: {}, commands: [], **)
    @host = host
    @user = user
    @output = output
    @exit_code = exit_code
    @exit_code_for = exit_code_for
    @commands = commands
  end

  def execute(command, cwd: nil, timeout: nil, raise_on_error: true, &block)
    full_cmd = cwd ? "cd #{Shellwords.escape(cwd)} && #{command}" : command
    @commands << full_cmd

    code = @exit_code_for.find { |p, _| full_cmd.include?(p) }&.last || @exit_code

    if @output && block_given?
      @output.to_s.each_line { |line| block.call(line.chomp) }
    end

    if raise_on_error && code != 0
      raise RbrunCore::Clients::Ssh::CommandError.new(
        "Command failed (exit code: #{code}): #{command}",
        exit_code: code,
        output: @output.to_s.strip
      )
    end

    { output: @output.to_s.strip, exit_code: code }
  end

  def execute_with_retry(command, retries: 3, backoff: 2, **)
    execute(command, **)
  end

  def execute_ignore_errors(command, cwd: nil)
    execute(command, cwd:, raise_on_error: false)
  rescue RbrunCore::Clients::Ssh::Error
    nil
  end

  def available?(timeout: 10)
    true
  end

  def wait_until_ready(max_attempts: 60, interval: 5)
    true
  end

  def upload(local_path, remote_path)
    @commands << "upload:#{local_path}:#{remote_path}"
    true
  end

  def upload_content(content, remote_path, mode: "0644")
    @commands << "upload_content:#{remote_path}"
    true
  end

  def download(remote_path, local_path)
    @commands << "download:#{remote_path}:#{local_path}"
    true
  end

  def read_file(remote_path)
    @commands << "cat #{Shellwords.escape(remote_path)}"
    @output
  end

  def write_file(remote_path, content, append: false)
    @commands << "write_file:#{remote_path}"
    true
  end
end

# Test logger that captures log calls
class TestLogger
  attr_reader :logs

  def initialize
    @logs = []
  end

  def log(category, message)
    @logs << [ category, message ]
  end

  def categories
    @logs.map(&:first)
  end

  def include?(category)
    categories.include?(category)
  end

  def find(category)
    @logs.find { |cat, _| cat == category }
  end
end

module RbrunCoreTestSetup
  def setup
    super
    WebMock.reset!

    stub_request(:get, /api\.hetzner\.cloud/)
      .to_return(status: 200, body: { servers: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })

    stub_request(:get, /api\.cloudflare\.com/)
      .to_return(status: 200, body: { success: true, result: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:delete, /api\.cloudflare\.com/)
      .to_return(status: 200, body: { success: true, result: {} }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  private

    def build_config(target: :production)
      config = RbrunCore::Configuration.new
      config.target = target
      config.compute(:hetzner) do |c|
        c.api_key = "test-hetzner-key"
        c.ssh_key_path = TEST_SSH_KEY_PATH
        c.master.instance_type = "cpx11"
      end
      config.cloudflare do |cf|
        cf.api_token = "test-cloudflare-key"
        cf.account_id = "test-account-id"
        cf.domain = "test.dev"
      end
      config.git do |g|
        g.pat = "test-github-token"
        g.repo = "owner/test-repo"
      end
      config
    end

    def build_context(target: nil, **overrides)
      config = build_config
      # If no explicit target, use config.target (defaults to :production)
      RbrunCore::Context.new(config:, target: target || config.target, **overrides)
    end

    def json_headers
      { "Content-Type" => "application/json" }
    end

    # Stub SSH with MockSshClient. Returns commands array.
    # Pass exit_code_for: { "test -d" => 1 } to vary exit code per command pattern.
    def with_mocked_ssh(output: "ok", exit_code: 0, exit_code_for: nil, &block)
      commands = []
      RbrunCore::Clients::Ssh.stub(:new, ->(**opts) {
        MockSshClient.new(output:, exit_code:, exit_code_for: exit_code_for || {},
                          commands:, **opts)
      }, &block)
      commands
    end

    def with_mocked_ssh_error(error, &block)
      RbrunCore::Clients::Ssh.stub(:new, ->(**) { raise error }, &block)
    end

    # Stub SSH and capture executed commands into the returned array.
    def with_capturing_ssh(output: "ok", exit_code: 0, exit_code_for: nil, &block)
      with_mocked_ssh(output:, exit_code:, exit_code_for:, &block)
    end
end

module Minitest
  class Test
    include RbrunCoreTestSetup
  end
end
