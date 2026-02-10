# frozen_string_literal: true

module RbrunCore
  module Config
    class Database
      attr_accessor :password, :username, :database
      attr_reader :type
      attr_writer :image

      DEFAULT_IMAGES = {
        postgres: "postgres:16-alpine",
        sqlite: nil
      }.freeze

      def initialize(type)
        @type = type.to_sym
        @image = nil
        @password = nil
        @username = "app"
        @database = "app"
      end

      def image
        @image || DEFAULT_IMAGES[@type]
      end
    end
  end
end
