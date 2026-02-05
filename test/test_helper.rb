# frozen_string_literal: true

require "bundler/setup"
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

# ── SSH mock objects ──

class MockExitData
  def initialize(code) = @code = code
  def read_long = @code
end

class MockSubChannel
  attr_reader :output, :exit_code

  def initialize(output, exit_code)
    @output = output
    @exit_code = exit_code
  end

  def eof! = nil

  def on_data
    yield(nil, @output) unless @output.nil? || @output.empty?
  end

  def on_extended_data = nil

  def on_request(type)
    yield(nil, MockExitData.new(@exit_code)) if type == "exit-status"
  end
end

class MockChannel
  attr_reader :commands

  def initialize(output: "ok", exit_code: 0, exit_code_for: nil)
    @output = output
    @exit_code = exit_code
    @exit_code_for = exit_code_for || {}
    @commands = []
  end

  def wait = nil

  def exec(cmd, &block)
    @commands << cmd
    code = @exit_code_for.find { |pattern, _| cmd.include?(pattern) }&.last || @exit_code
    block.call(MockSubChannel.new(@output, code), true)
  end
end

class MockSsh
  attr_reader :channel

  def initialize(channel)
    @channel = channel
  end

  def open_channel(&block)
    block.call(@channel)
    @channel
  end

  def exec!(_) = "ok"
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

    def build_config
      config = RbrunCore::Configuration.new
      config.compute(:hetzner) do |c|
        c.api_key = "test-hetzner-key"
        c.ssh_key_path = TEST_SSH_KEY_PATH
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

    def build_context(target: :production, **overrides)
      RbrunCore::Context.new(config: build_config, target:, **overrides)
    end

    def json_headers
      { "Content-Type" => "application/json" }
    end

    # Stub SSH with fixed output. Yields block with Net::SSH stubbed.
    # Pass exit_code_for: { "test -d" => 1 } to vary exit code per command pattern.
    def with_mocked_ssh(output: "ok", exit_code: 0, exit_code_for: nil, &)
      channel = MockChannel.new(output:, exit_code:, exit_code_for:)
      ssh = MockSsh.new(channel)
      Net::SSH.stub(:start, ->(_, _, _, &b) { b.call(ssh) }, &)
    end

    def with_mocked_ssh_error(error, &)
      Net::SSH.stub(:start, ->(*) { raise error }, &)
    end

    # Stub SSH and capture executed commands into the returned array.
    def with_capturing_ssh(output: "ok", exit_code: 0, exit_code_for: nil, &)
      channel = MockChannel.new(output:, exit_code:, exit_code_for:)
      ssh = MockSsh.new(channel)
      Net::SSH.stub(:start, ->(_, _, _, &b) { b.call(ssh) }, &)
      channel.commands
    end
end

module Minitest
  class Test
    include RbrunCoreTestSetup
  end
end
