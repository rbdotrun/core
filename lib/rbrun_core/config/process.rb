# frozen_string_literal: true

module RbrunCore
  module Config
    class Process
      attr_accessor :command, :port, :subdomain, :runs_on, :replicas, :env, :setup
      attr_reader :name

      def initialize(name)
        @name = name.to_sym
        @command = nil
        @port = nil
        @subdomain = nil
        @runs_on = nil
        @replicas = 2
        @env = {}
        @setup = []
      end
    end
  end
end
