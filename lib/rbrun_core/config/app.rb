# frozen_string_literal: true

module RbrunCore
  module Config
    class App
      DEFAULT_KEEP_IMAGES = 3

      attr_reader :processes
      attr_accessor :dockerfile, :platform, :keep_images

      def initialize
        @processes = {}
        @dockerfile = "Dockerfile"
        @platform = "linux/amd64"
        @keep_images = DEFAULT_KEEP_IMAGES
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
