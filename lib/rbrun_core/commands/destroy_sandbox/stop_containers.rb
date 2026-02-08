# frozen_string_literal: true

module RbrunCore
  module Commands
    class DestroySandbox
      class StopContainers

        WORKSPACE = "/home/deploy/workspace"
        COMPOSE_FILE = "docker-compose.generated.yml"

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          @on_step&.call(Step::Id::STOP_CONTAINERS, Step::IN_PROGRESS)
          begin
            @ctx.ssh_client.execute(
              "cd #{WORKSPACE} && docker compose -f #{COMPOSE_FILE} down",
              raise_on_error: false
            )
          rescue Clients::Ssh::Error
            # Server may already be gone
          end
          @on_step&.call(Step::Id::STOP_CONTAINERS, Step::DONE)
        end
      end
    end
  end
end
