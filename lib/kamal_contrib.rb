# frozen_string_literal: true

require "zeitwerk"

module KamalContrib
  class << self
    def loader
      @loader ||= begin
        loader = Zeitwerk::Loader.new
        loader.tag = "kamal_contrib"
        loader.push_dir("#{__dir__}/kamal_contrib", namespace: KamalContrib)
        loader.ignore("#{__dir__}/kamal_contrib/version.rb")
        loader
      end
    end
  end
end

require_relative "kamal_contrib/version"

# Core dependency
require_relative "rbrun_core"

# Setup and eager load
KamalContrib.loader.setup
KamalContrib.loader.eager_load
