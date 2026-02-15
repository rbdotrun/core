# frozen_string_literal: true

module RbrunCore
  module Config
    class Builder
      attr_accessor :enabled, :machine_type, :volume_size

      DEFAULT_MACHINE_TYPE = "cpx31"
      DEFAULT_VOLUME_SIZE = 50

      def initialize
        @enabled = false
        @machine_type = DEFAULT_MACHINE_TYPE
        @volume_size = DEFAULT_VOLUME_SIZE
      end

      def enabled?
        @enabled == true
      end
    end
  end
end
