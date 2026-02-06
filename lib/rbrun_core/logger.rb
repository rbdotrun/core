# frozen_string_literal: true

module RbrunCore
  # Unified logger with multi-destination output.
  #
  # Writes identical formatted output to all destinations (stdout, file, etc).
  # Handles color/TTY detection per-destination.
  #
  # Usage:
  #   logger = RbrunCore::Logger.new
  #   logger = RbrunCore::Logger.new(file: "/var/log/deploy.log")
  #   logger = RbrunCore::Logger.new(color: false)
  #
  #   logger.log(:server, "Creating myserver")
  #   logger.emit(:docker_build, "Step 1/10: FROM ruby:3.2")
  #
  class Logger
    COLORS = {
      cyan: "\e[36m",
      reset: "\e[0m"
    }.freeze

    def initialize(stdout: $stdout, file: nil, color: :auto)
      @outputs = []
      add_output(stdout, color:) if stdout
      add_output(File.open(file, "a"), color: false) if file
    end

    # Log a status message with category prefix.
    def log(category, message)
      write("[#{category}] #{message}")
    end

    # Emit a single line (for streaming command output).
    # Same as log but semantically for line-by-line output.
    def emit(category, line)
      log(category, line)
    end

    # Create a proc that emits lines for a given category.
    # Useful for passing to execute blocks.
    #
    #   ssh.execute("docker build ..", &logger.streamer(:docker_build))
    #
    def streamer(category)
      ->(line) { emit(category, line) }
    end

    # Close any file handles opened by the logger.
    def close
      @outputs.each do |output|
        output.io.close if output.io.respond_to?(:close) && output.io != $stdout && output.io != $stderr
      end
    end

    private

      def add_output(io, color:)
        use_color = case color
                    when :auto then io.respond_to?(:tty?) && io.tty?
                    else color
                    end
        @outputs << Output.new(io, color: use_color)
      end

      def write(line)
        @outputs.each { |o| o.puts(line) }
      end

      # Internal output destination wrapper.
      class Output
        attr_reader :io

        def initialize(io, color:)
          @io = io
          @color = color
        end

        def puts(line)
          formatted = @color ? colorize(line) : line
          @io.puts(formatted)
          @io.flush if @io.respond_to?(:flush)
        end

        private

          def colorize(line)
            # Color the [category] prefix
            line.sub(/\A(\[[^\]]+\])/) { "#{COLORS[:cyan]}#{$1}#{COLORS[:reset]}" }
          end
      end
  end
end
