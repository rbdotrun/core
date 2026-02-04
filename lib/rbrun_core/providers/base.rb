# frozen_string_literal: true

module RbrunCore
  module Providers
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

      def vm_based?
        true
      end
    end
  end
end
