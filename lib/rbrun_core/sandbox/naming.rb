# frozen_string_literal: true

module RbrunCore
  module Sandbox
    # Naming conventions for sandbox environments.
    # All slug-based: ephemeral resources identified by 6-char hex slugs.
    module Naming
      PREFIX = "rbrun-sandbox"
      SLUG_LENGTH = 6
      SLUG_REGEX = /\A[a-f0-9]{#{SLUG_LENGTH}}\z/

      class << self
        def generate_slug
          SecureRandom.hex(SLUG_LENGTH / 2)
        end

        def valid_slug?(slug)
          SLUG_REGEX.match?(slug.to_s)
        end

        def validate_slug!(slug)
          return if valid_slug?(slug)

          raise ArgumentError, "Invalid slug format: #{slug.inspect}. Expected #{SLUG_LENGTH} hex chars."
        end

        def resource(slug)
          validate_slug!(slug)
          "#{PREFIX}-#{slug}"
        end

        def resource_regex
          /^#{PREFIX}-([a-f0-9]{#{SLUG_LENGTH}})/
        end

        def container(slug, role)
          validate_slug!(slug)
          "#{PREFIX}-#{slug}-#{role}"
        end

        def branch(slug)
          validate_slug!(slug)
          "#{PREFIX}/#{slug}"
        end

        def hostname(slug, domain)
          validate_slug!(slug)
          "#{PREFIX}-#{slug}.#{domain}"
        end

        def hostname_regex
          /^#{PREFIX}-([a-f0-9]{#{SLUG_LENGTH}})\./
        end

        def self_hosted_preview_url(slug, domain)
          validate_slug!(slug)
          "https://#{hostname(slug, domain)}"
        end

        def worker(slug)
          validate_slug!(slug)
          "#{PREFIX}-widget-#{slug}"
        end

        def worker_regex
          /^#{PREFIX}-widget-([a-f0-9]{#{SLUG_LENGTH}})/
        end

        def worker_route(slug, domain)
          validate_slug!(slug)
          "#{hostname(slug, domain)}/*"
        end

        def ssh_comment(slug)
          validate_slug!(slug)
          "#{PREFIX}-#{slug}"
        end

        def auth_cookie
          "#{PREFIX}-auth"
        end
      end
    end
  end
end
