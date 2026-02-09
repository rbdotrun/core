# frozen_string_literal: true

require "open3"

module RbrunCore
  module Commands
    module K3s
      class CleanupImages
        KEEP_IMAGES = 3

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          @on_step&.call("Images", :in_progress)

          prefix = @ctx.prefix

          output, _status = Open3.capture2("docker", "images", prefix, "--format", "{{.Tag}}")
          if output && !output.empty?
            tags = output.each_line
              .map(&:strip)
              .reject { |t| [ "latest", "<none>" ].include?(t) }
              .sort
              .reverse
              .drop(KEEP_IMAGES)

            tags.each { |tag| system("docker", "rmi", "#{prefix}:#{tag}") }
          end

          @on_step&.call("Images", :done)
        end
      end
    end
  end
end
