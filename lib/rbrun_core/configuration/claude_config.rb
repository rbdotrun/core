# frozen_string_literal: true

module RbrunCore
  class ClaudeConfig
    attr_accessor :auth_token, :base_url

    def initialize
      @base_url = "https://api.anthropic.com"
    end

    def configured?
      !auth_token.nil? && !auth_token.empty?
    end

    def validate!
      # Optional - no required fields
    end
  end
end
