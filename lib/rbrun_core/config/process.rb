# frozen_string_literal: true

module RbrunCore
  module Config
    class Process
      attr_accessor :command, :port, :subdomain, :runs_on, :replicas, :env, :setup, :resources
      attr_reader :name

      def initialize(name)
        @name = name.to_sym
        @command = nil
        @port = nil
        @subdomain = nil
        @runs_on = nil
        @replicas = nil
        @resources = nil
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
