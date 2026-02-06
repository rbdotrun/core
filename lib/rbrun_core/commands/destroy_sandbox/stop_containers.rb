# frozen_string_literal: true

module RbrunCore
  module Commands
    class DestroySandbox
      class StopContainers
        WORKSPACE = "/home/deploy/workspace"
        COMPOSE_FILE = "docker-compose.generated.yml"

        def initialize(ctx, on_log: nil)
          @ctx = ctx
          @on_log = on_log
        end

        def run
          log("stop_containers", "Stopping containers")
          begin
            @ctx.ssh_client.execute(
              "cd #{WORKSPACE} && docker compose -f #{COMPOSE_FILE} down",
              raise_on_error: false
            )
          rescue Clients::Ssh::Error
            # Server may already be gone
          end
        end

        private

          def log(category, message = nil)
            @on_log&.call(category, message)
          end
      end
    end
  end
end
