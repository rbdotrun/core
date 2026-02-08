# frozen_string_literal: true

module RbrunCore
  module Config
    class Service
      attr_accessor :subdomain, :env, :runs_on, :port, :mount_path, :setup
      attr_reader :name
      attr_writer :image

      def initialize(name)
        @name = name.to_sym
        @subdomain = nil
        @env = {}
        @image = nil
        @runs_on = nil
        @mount_path = nil
        @port = nil
        @setup = []
      end

      def image
        @image
      end
    end
  end
end
