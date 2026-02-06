# frozen_string_literal: true

module RbrunCore
  module LocalGit
    class << self
      def current_branch
        branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
        raise Error, "Not in a git repository" if branch.empty?

        branch
      end

      def repo_from_remote
        url = `git remote get-url origin 2>/dev/null`.strip
        raise Error, "No git remote 'origin' found" if url.empty?

        extract_repo(url)
      end

      def gh_auth_token
        token = `gh auth token 2>/dev/null`.strip
        raise Error, "GitHub CLI not authenticated — run `gh auth login`" if token.empty?

        token
      end

      private

        def extract_repo(url)
          # SSH: git@github.com:org/repo.git
          if url.match?(%r{^git@})
            url.sub(/^git@[^:]+:/, "").sub(/\.git$/, "")
          # HTTPS: https://github.com/org/repo.git
          else
            uri_path = url.sub(%r{^https?://[^/]+/}, "")
            uri_path.sub(/\.git$/, "")
          end
        end
    end
  end
end
