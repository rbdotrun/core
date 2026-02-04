# frozen_string_literal: true

module RbrunCore
  class GitConfig
    attr_accessor :pat, :repo, :username, :email

    def initialize
      @username = "rbrun"
      @email = "sandbox@rbrun.dev"
    end

    def validate!
      raise ConfigurationError, "git.pat is required" if pat.nil? || pat.empty?
      raise ConfigurationError, "git.repo is required" if repo.nil? || repo.empty?
    end

    # Derive app name from repo (e.g., "org/myapp" → "myapp")
    def app_name
      repo&.split("/")&.last
    end
  end
end
