# frozen_string_literal: true

module KamalContrib
  module Steps
    class GenerateKamalConfig
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run
        @on_step&.call("Kamal config", :in_progress)

        builder = KamalConfigBuilder.new(@ctx)

        @deploy_yml = builder.to_yaml
        @secrets = builder.to_secrets

        @on_step&.call("Kamal config", :done)
      end

      def deploy_yml
        @deploy_yml
      end

      def secrets
        @secrets
      end
    end
  end
end
