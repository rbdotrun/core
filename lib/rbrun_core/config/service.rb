# frozen_string_literal: true

module RbrunCore
  module Config
    class Service
      attr_accessor :subdomain, :env, :port, :mount_path, :setup, :instance_type, :replicas
      attr_reader :name
      attr_writer :image

      def initialize(name)
        @name = name.to_sym
        @subdomain = nil
        @env = {}
        @image = nil
        @mount_path = nil
        @port = nil
        @setup = []
        @instance_type = nil
        @replicas = nil
      end

      def image
        @image
      end

      def effective_replicas
        @replicas || 1
      end
    end
  end
end
