# frozen_string_literal: true

module RbrunCore
  # Shared naming conventions used across strategies.
  # Strategy-specific naming lives in Commands::K3s::Naming and Commands::Sandbox::Naming.
  module Naming
    MASTER_GROUP = "master"

    class << self
      def default_user
        "deploy"
      end

      def release_prefix(app_name, environment)
        "#{app_name}-#{environment}"
      end

      def backend_bucket(app_name, environment)
        "#{app_name}-#{environment}-backend"
      end

      def storage_bucket(app_name, environment, bucket_name)
        "#{app_name}-#{environment}-#{bucket_name}"
      end

      def compose_volume(name)
        "#{name}_data"
      end
    end
  end
end
