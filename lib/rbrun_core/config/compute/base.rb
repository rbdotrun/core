# frozen_string_literal: true

module RbrunCore
  module Config
    module Compute
      class Base
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
