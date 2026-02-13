# frozen_string_literal: true

module RbrunCore
  # Single source of truth for all naming conventions.
  # All methods that accept a slug validate format and raise ArgumentError if invalid.
  # Slugs are 6 lowercase hex characters (e.g., "a1b2c3").
  module Naming
    PREFIX = "rbrun-sandbox"
    SLUG_LENGTH = 6
    SLUG_REGEX = /\A[a-f0-9]{#{SLUG_LENGTH}}\z/

    # Server group constants
    MASTER_GROUP = "master"

    # Backend bucket prefixes
    POSTGRES_BACKUPS_PREFIX = "postgres-backups/"
    DOCKER_REGISTRY_PREFIX = "docker-registry"

    # Kubernetes label keys
    LABEL_APP = "app.kubernetes.io/name"
    LABEL_INSTANCE = "app.kubernetes.io/instance"
    LABEL_MANAGED_BY = "app.kubernetes.io/managed-by"
    LABEL_SERVER_GROUP = "rb.run/server-group"
    LABEL_BUILDER = "rb.run/builder"

    class << self
      # Generate a new slug for sandbox identification.
      # Output: 6 lowercase hex characters (e.g., "a1b2c3").
      def generate_slug
        SecureRandom.hex(SLUG_LENGTH / 2)
      end

      # Check if slug matches expected format.
      # Output: true if valid 6-char hex string, false otherwise.
      def valid_slug?(slug)
        SLUG_REGEX.match?(slug.to_s)
      end

      # Validate slug format, raise if invalid.
      # Raises: ArgumentError with descriptive message.
      def validate_slug!(slug)
        return if valid_slug?(slug)

        raise ArgumentError, "Invalid slug format: #{slug.inspect}. Expected #{SLUG_LENGTH} hex chars."
      end

      # Default SSH user for VM provisioning.
      def default_user
        "deploy"
      end

      # Cookie name for preview authentication.
      def auth_cookie
        "#{PREFIX}-auth"
      end

      # Infrastructure resource name (servers, firewalls, networks, tunnels).
      def resource(slug)
        validate_slug!(slug)
        "#{PREFIX}-#{slug}"
      end

      # Release K8s resource prefix for deployments, services, etc.
      # Format: appname-environment (e.g., "myapp-staging", "myapp-production")
      def release_prefix(app_name, environment)
        "#{app_name}-#{environment}"
      end

      # Regex to extract slug from resource name.
      # Captures slug in match group 1.
      def resource_regex
        /^#{PREFIX}-([a-f0-9]{#{SLUG_LENGTH}})/
      end

      # Container name with role suffix.
      def container(slug, role)
        validate_slug!(slug)
        "#{PREFIX}-#{slug}-#{role}"
      end

      # Git branch name for sandbox isolation.
      def branch(slug)
        validate_slug!(slug)
        "#{PREFIX}/#{slug}"
      end

      # Preview hostname for Cloudflare tunnel DNS.
      def hostname(slug, domain)
        validate_slug!(slug)
        "#{PREFIX}-#{slug}.#{domain}"
      end

      # Regex to extract slug from hostname.
      def hostname_regex
        /^#{PREFIX}-([a-f0-9]{#{SLUG_LENGTH}})\./
      end

      # Self-hosted preview URL via Cloudflare tunnel.
      def self_hosted_preview_url(slug, domain)
        validate_slug!(slug)
        "https://#{hostname(slug, domain)}"
      end

      # Cloudflare Worker name for widget injection.
      def worker(slug)
        validate_slug!(slug)
        "#{PREFIX}-widget-#{slug}"
      end

      # Regex to extract slug from worker name.
      def worker_regex
        /^#{PREFIX}-widget-([a-f0-9]{#{SLUG_LENGTH}})/
      end

      # Worker route pattern for Cloudflare.
      def worker_route(slug, domain)
        validate_slug!(slug)
        "#{hostname(slug, domain)}/*"
      end

      # SSH key comment for identification.
      def ssh_comment(slug)
        validate_slug!(slug)
        "#{PREFIX}-#{slug}"
      end

      # R2 backend bucket name for release deployments (registry, backups, etc).
      def backend_bucket(app_name, environment)
        "#{app_name}-#{environment}-backend"
      end

      # R2 storage bucket name for app storage.
      def storage_bucket(app_name, environment, bucket_name)
        "#{app_name}-#{environment}-#{bucket_name}"
      end

      # Volume name for cloud block storage.
      def volume(prefix, name)
        "#{prefix}-#{name}-data"
      end

      # Database volume name for K8s (alias for volume).
      def database_volume(prefix, type)
        volume(prefix, type)
      end

      # Docker Compose volume name (local development).
      def compose_volume(name)
        "#{name}_data"
      end

      # Manual job name from cronjob (max 63 chars for k8s label).
      def manual_job(cronjob_name)
        suffix = Time.now.to_i.to_s[-6..]
        base = cronjob_name.slice(0, 63 - 8) # leave room for "-m" + 6 digits
        "#{base}-m#{suffix}"
      end

      # ── K8s Resource Names ──

      def deployment(prefix, name)
        "#{prefix}-#{name}"
      end

      def secret_for(name)
        "#{name}-secret"
      end

      def app_secret(prefix)
        "#{prefix}-app-secret"
      end

      def postgres(prefix)
        "#{prefix}-postgres"
      end

      def postgres_backup(prefix)
        "#{prefix}-postgres-backup"
      end

      def cloudflared(prefix)
        "#{prefix}-cloudflared"
      end

      def service_url(prefix, name, port, protocol: "http")
        "#{protocol}://#{prefix}-#{name}:#{port}"
      end

      def postgres_url(prefix, user, password, database)
        "postgresql://#{user}:#{password}@#{postgres(prefix)}:5432/#{database}"
      end

      def storage_env_prefix(bucket_name)
        "STORAGE_#{bucket_name.to_s.upcase}"
      end

      def service_env_var(name)
        "#{name.to_s.upcase}_URL"
      end

      def fqdn(subdomain, zone)
        "#{subdomain}.#{zone}"
      end

      # Builder resource names
      def builder_server(prefix)
        "#{prefix}-builder"
      end

      def builder_image(prefix)
        "#{prefix}-builder-image"
      end

      def builder_volume(prefix)
        "#{prefix}-builder-cache"
      end
    end
  end
end
