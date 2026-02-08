# frozen_string_literal: true

require "open3"

module RbrunCore
  module Commands
    class Deploy
      # Cleans up old local Docker images, keeping the N most recent.
      class CleanupImages
        KEEP_IMAGES = 3

        def initialize(ctx, logger: nil)
          @ctx = ctx
          @logger = logger
        end

        def run
          log("cleanup_images", "Cleaning up old local images")
          prefix = @ctx.prefix

          output, _status = Open3.capture2("docker", "images", prefix, "--format", "{{.Tag}}")
          return if output.nil? || output.empty?

          tags = output.each_line
            .map(&:strip)
            .reject { |t| [ "latest", "<none>" ].include?(t) }
            .sort
            .reverse
            .drop(KEEP_IMAGES)

          tags.each { |tag| system("docker", "rmi", "#{prefix}:#{tag}") }
        end

        private

          def log(category, message = nil)
            @logger&.log(category, message)
          end
      end
    end
  end
end
