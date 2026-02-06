# frozen_string_literal: true

module RbrunCore
  module Config
    class Cloudflare
      attr_accessor :api_token, :account_id, :domain, :storage_bucket

      def configured?
        !api_token.nil? && !api_token.empty? &&
          !account_id.nil? && !account_id.empty? &&
          !domain.nil? && !domain.empty?
      end

      def validate!
        return unless configured?
        raise Error::Configuration, "cloudflare.api_token is required" if api_token.nil? || api_token.empty?
        raise Error::Configuration, "cloudflare.account_id is required" if account_id.nil? || account_id.empty?
        raise Error::Configuration, "cloudflare.domain is required" if domain.nil? || domain.empty?
      end

      def client
        @client ||= Clients::Cloudflare.new(api_token:, account_id:)
      end

      def r2
        @r2 ||= Clients::CloudflareR2.new(api_token:, account_id:)
      end

      def zone_id
        @zone_id ||= client.get_zone_id(domain)
      end
    end
  end
end
