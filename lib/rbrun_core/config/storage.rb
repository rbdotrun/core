# frozen_string_literal: true

module RbrunCore
  module Config
    class Storage
      attr_reader :buckets

      def initialize
        @buckets = {}
      end

      def bucket(name)
        config = StorageBucket.new(name)
        yield config if block_given?
        @buckets[name.to_sym] = config
      end

      def any?
        @buckets.any?
      end

      def each(&)
        @buckets.each(&)
      end
    end

    class StorageBucket
      attr_reader :name
      attr_accessor :public, :cors

      def initialize(name)
        @name = name.to_sym
        @public = false
        @cors = nil
      end

      def cors?
        @cors == true || @cors.is_a?(Hash)
      end

      def cors_inferred?
        @cors == true
      end

      def cors_config(inferred_origins: [])
        return nil unless cors?

        origins = if cors_inferred?
          inferred_origins
        else
          @cors[:origins] || []
        end

        {
          allowed_origins: origins,
          allowed_methods: @cors.is_a?(Hash) ? (@cors[:methods] || default_methods) : default_methods,
          allowed_headers: [ "*" ],
          expose_headers: %w[ETag Content-Length Content-Type],
          max_age_seconds: 3600
        }
      end

      private

        def default_methods
          %w[GET PUT POST DELETE HEAD]
        end
    end
  end
end
