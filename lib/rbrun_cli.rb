# frozen_string_literal: true

require "zeitwerk"

module RbrunCli
  class << self
    def loader
      @loader ||= begin
        loader = Zeitwerk::Loader.new
        loader.tag = "rbrun_cli"
        loader.push_dir("#{__dir__}/rbrun_cli", namespace: RbrunCli)
        loader.ignore("#{__dir__}/rbrun_cli/version.rb")
        loader
      end
    end
  end
end

require_relative "rbrun_cli/version"

# External dependencies
require_relative "rbrun_core"
require "thor"

# Setup and eager load
RbrunCli.loader.setup
RbrunCli.loader.eager_load
