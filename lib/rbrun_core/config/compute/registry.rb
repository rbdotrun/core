# frozen_string_literal: true

module RbrunCore
  module Config
    module Compute
      class Registry
        PROVIDERS = {
          hetzner: "RbrunCore::Config::Compute::Hetzner",
          scaleway: "RbrunCore::Config::Compute::Scaleway",
          aws: "RbrunCore::Config::Compute::Aws"
        }.freeze

        def self.build(provider)
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
end
