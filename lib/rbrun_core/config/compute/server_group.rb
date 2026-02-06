# frozen_string_literal: true

module RbrunCore
  module Config
    module Compute
      class ServerGroup
        attr_accessor :type, :count
        attr_reader :name

        def initialize(name:, type:, count: 1)
          @name = name.to_sym
          @type = type
          @count = count
        end
      end
    end
  end
end
