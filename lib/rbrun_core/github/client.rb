# frozen_string_literal: true

module RbrunCore
  module Github
    class Client < RbrunCore::BaseClient
      BASE_URL = "https://api.github.com"

      def initialize(token:)
        @token = token
        raise RbrunCore::Error, "GitHub token is required" if @token.nil? || @token.empty?
        super()
      end

      def list_repos(sort: "pushed", per_page: 100, page: 1)
        get("/user/repos", sort:, per_page:, page:, visibility: "all",
            affiliation: "owner,collaborator,organization_member")
      end

      def search_repos(query:, per_page: 10)
        scoped_query = "#{query} user:#{username}"
        get("/search/repositories", q: scoped_query, per_page:)
      end

      def username
        @username ||= get("/user")["login"]
      end

      def get_repo(owner:, repo:)
        get("/repos/#{owner}/#{repo}")
      end

      def get_contents(owner:, repo:, path:, ref: nil)
        params = {}
        params[:ref] = ref if ref
        get("/repos/#{owner}/#{repo}/contents/#{path}", params)
      end

      private

        def auth_headers
          { "Authorization" => "Bearer #{@token}", "Accept" => "application/vnd.github.v3+json" }
        end
    end
  end
end
