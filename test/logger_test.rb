# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"

class LoggerTest < Minitest::Test
  def test_log_writes_to_stdout
    output = StringIO.new
    logger = RbrunCore::Logger.new(stdout: output, color: false)

    logger.log(:server, "Creating myserver")

    assert_equal "[server] Creating myserver\n", output.string
  end

  def test_emit_writes_single_line
    output = StringIO.new
    logger = RbrunCore::Logger.new(stdout: output, color: false)

    logger.emit(:docker_build, "Step 1/10: FROM ruby:3.2")

    assert_equal "[docker_build] Step 1/10: FROM ruby:3.2\n", output.string
  end

  def test_streamer_returns_callable
    output = StringIO.new
    logger = RbrunCore::Logger.new(stdout: output, color: false)

    streamer = logger.streamer(:docker_build)
    streamer.call("Step 1/10")
    streamer.call("Step 2/10")

    assert_equal "[docker_build] Step 1/10\n[docker_build] Step 2/10\n", output.string
  end

  def test_writes_to_file_and_stdout
    stdout = StringIO.new
    file = Tempfile.new("test_log")

    logger = RbrunCore::Logger.new(stdout: stdout, file: file.path, color: false)
    logger.log(:server, "Creating myserver")
    logger.close

    assert_equal "[server] Creating myserver\n", stdout.string
    assert_equal "[server] Creating myserver\n", File.read(file.path)
  ensure
    file.close
    file.unlink
  end

  def test_same_format_to_stdout_and_file
    stdout = StringIO.new
    file = Tempfile.new("test_log")

    logger = RbrunCore::Logger.new(stdout: stdout, file: file.path, color: false)
    logger.log(:deploy, "Starting deployment")
    logger.emit(:k3s, "Installing k3s")
    logger.log(:deploy, "Done")
    logger.close

    expected = <<~LOG
      [deploy] Starting deployment
      [k3s] Installing k3s
      [deploy] Done
    LOG

    assert_equal expected, stdout.string
    assert_equal expected, File.read(file.path)
  ensure
    file.close
    file.unlink
  end

  def test_color_auto_detects_tty
    # StringIO is not a TTY, so color should be off
    output = StringIO.new
    logger = RbrunCore::Logger.new(stdout: output, color: :auto)

    logger.log(:server, "test")

    # No ANSI codes
    refute_includes output.string, "\e["
  end

  def test_color_false_disables_colors
    output = StringIO.new
    logger = RbrunCore::Logger.new(stdout: output, color: false)

    logger.log(:server, "test")

    refute_includes output.string, "\e["
  end

  def test_no_stdout_when_nil
    file = Tempfile.new("test_log")

    logger = RbrunCore::Logger.new(stdout: nil, file: file.path)
    logger.log(:server, "only to file")
    logger.close

    assert_equal "[server] only to file\n", File.read(file.path)
  ensure
    file.close
    file.unlink
  end
end
