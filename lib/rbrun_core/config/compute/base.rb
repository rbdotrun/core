# frozen_string_literal: true

module RbrunCore
  module Config
    module Compute
      class MasterConfig
        attr_accessor :instance_type, :count

        def initialize
          @instance_type = nil
          @count = 1
        end

        # Alias for consistency with ServerGroup
        def type
          @instance_type
        end
      end

      class Base
        attr_accessor :location, :image
        attr_reader :master

        def initialize
          @master = MasterConfig.new
          @location = nil
          @image = nil
        end

        def provider_name
          raise NotImplementedError
        end

        def validate!
          raise NotImplementedError
        end

        def client
          raise NotImplementedError
        end

        def supports_self_hosted?
          false
        end
      end
    end
  end
end
