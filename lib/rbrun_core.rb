# frozen_string_literal: true

require "zeitwerk"

module RbrunCore
  class << self
    def loader
      @loader ||= Zeitwerk::Loader.for_gem
    end
  end
end

# External dependencies (stdlib)
require "json"
require "securerandom"
require "yaml"
require "base64"
require "shellwords"
require "logger"

# External dependencies (gems)
require "faraday"
require "faraday/net_http"

# Setup and eager load
RbrunCore.loader.setup
RbrunCore.loader.eager_load
