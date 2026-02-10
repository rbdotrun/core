# frozen_string_literal: true

module RbrunCore
  module Config
    class Process
      attr_accessor :command, :port, :subdomain, :replicas, :env, :setup, :instance_type
      attr_reader :name

      def initialize(name)
        @name = name.to_sym
        @command = nil
        @port = nil
        @subdomain = nil
        @replicas = nil
        @instance_type = nil
        @env = {}
        @setup = []
      end

      def effective_replicas
        return @replicas if @replicas

        subdomain && !subdomain.empty? ? 2 : 1
      end
    end
  end
end
