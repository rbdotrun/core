# frozen_string_literal: true

module KamalContrib
  module Steps
    class Deploy
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run(config_file:, first_deploy: false)
        @on_step&.call("Deploy", :in_progress)

        command = first_deploy ? "setup" : "deploy"
        args = [ command, "--config-file=#{config_file}", "-y" ]

        # TODO: Invoke Kamal programmatically when kamal gem is available
        # Kamal::Cli::Main.start(args)
        @kamal_args = args

        @on_step&.call("Deploy", :done)
      end

      def kamal_args
        @kamal_args
      end
    end
  end
end
