# frozen_string_literal: true

module KamalContrib
  module Steps
    class GenerateSecrets
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run
        @on_step&.call("Secrets", :in_progress)

        builder = KamalConfigBuilder.new(@ctx)
        @secrets_content = builder.to_secrets

        @on_step&.call("Secrets", :done)
      end

      def secrets_content
        @secrets_content
      end
    end
  end
end
