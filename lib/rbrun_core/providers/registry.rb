# frozen_string_literal: true

module RbrunCore
  module Providers
    class Registry
      PROVIDERS = {
        hetzner: "RbrunCore::Providers::Hetzner::Config",
        scaleway: "RbrunCore::Providers::Scaleway::Config"
      }.freeze

      def self.build(provider, &block)
        klass_name = PROVIDERS[provider]
        raise ArgumentError, "Unknown compute provider: #{provider}" unless klass_name

        klass = Object.const_get(klass_name)
        config = klass.new
        yield config if block_given?
        config
      end
    end
  end
end
