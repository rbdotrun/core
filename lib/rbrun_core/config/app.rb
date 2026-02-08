# frozen_string_literal: true

module RbrunCore
  module Config
    class App
      attr_reader :processes
      attr_accessor :dockerfile, :platform

      def initialize
        @processes = {}
        @dockerfile = "Dockerfile"
        @platform = "linux/amd64"
      end

      def process(name)
        config = Process.new(name)
        yield config if block_given?
        @processes[name.to_sym] = config
      end

      def web?
        @processes.key?(:web)
      end
    end
  end
end
