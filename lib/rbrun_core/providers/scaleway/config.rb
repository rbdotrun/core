# frozen_string_literal: true

module RbrunCore
  module Providers
    module Scaleway
      class Config < Base
        attr_accessor :api_key, :project_id, :zone

        def initialize
          @zone = "fr-par-1"
        end

        def provider_name
          :scaleway
        end

        def supports_self_hosted?
          true
        end

        def validate!
          raise ConfigurationError, "compute.api_key is required for Scaleway" if api_key.nil? || api_key.empty?

          return unless project_id.nil? || project_id.empty?

          raise ConfigurationError,
                "compute.project_id is required for Scaleway"
        end

        def client
          @client ||= Client.new(api_key: @api_key, project_id: @project_id, zone: @zone)
        end
      end
    end
  end
end
