# frozen_string_literal: true

module RbrunCore
  module Config
    class Git
      attr_accessor :pat, :repo, :username, :email

      def initialize
        @username = "rbrun"
        @email = "sandbox@rbrun.dev"
      end

      def validate!
        # pat and repo are now auto-populated at runtime via LocalGit
      end

      # Derive app name from repo (e.g., "org/myapp" → "myapp")
      def app_name
        repo&.split("/")&.last
      end
    end
  end
end
