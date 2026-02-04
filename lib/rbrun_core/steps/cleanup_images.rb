# frozen_string_literal: true

require "open3"

module RbrunCore
  module Steps
    class CleanupImages
      REGISTRY_PORT = 30500
      KEEP_IMAGES = 3

      def initialize(ctx, on_log: nil)
        @ctx = ctx
        @on_log = on_log
      end

      def run
        log("cleanup_images", "Cleaning up old images")
        env = { "DOCKER_HOST" => "ssh://#{Naming.default_user}@#{@ctx.server_ip}" }
        prefix = @ctx.prefix

        output, _status = Open3.capture2(env, "docker", "images", prefix, "--format", "{{.Tag}} {{.ID}}")
        return if output.nil? || output.empty?

        output.each_line do |line|
          tag, _id = line.strip.split
          next if tag == "latest" || tag == "<none>"
          system(env, "docker", "rmi", "#{prefix}:#{tag}")
        end
      end

      private

        def log(category, message = nil)
          @on_log&.call(category, message)
        end
    end
  end
end
