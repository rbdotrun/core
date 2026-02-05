# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    super
    @config = RbrunCore::Configuration.new
  end

  # ── Compute Provider ──

  def test_compute_creates_hetzner_config_with_correct_provider
    @config.compute(:hetzner) { |c| c.api_key = "key" }

    assert_equal :hetzner, @config.compute_config.provider_name
    assert_equal "cpx11", @config.compute_config.server_type
  end

  def test_compute_creates_hetzner_config_with_default_location_and_image
    @config.compute(:hetzner) { |c| c.api_key = "key" }

    assert_equal "ash", @config.compute_config.location
    assert_equal "ubuntu-22.04", @config.compute_config.image
  end

  def test_compute_creates_scaleway_config
    @config.compute(:scaleway) do |c|
      c.api_key = "key"
      c.project_id = "proj"
    end

    assert_equal :scaleway, @config.compute_config.provider_name
  end

  def test_compute_raises_for_unknown_provider
    assert_raises(ArgumentError) { @config.compute(:unknown) }
  end

  # ── Database ──

  def test_database_creates_postgres_config
    @config.database(:postgres)

    assert @config.database?(:postgres)
    assert_equal "postgres:16-alpine", @config.database_configs[:postgres].image
  end

  def test_database_postgres_default_credentials
    @config.database(:postgres)

    assert_equal "app", @config.database_configs[:postgres].username
    assert_equal "app", @config.database_configs[:postgres].database
  end

  def test_database_creates_redis_config
    @config.database(:redis)

    assert_equal "redis:7-alpine", @config.database_configs[:redis].image
  end

  def test_database_allows_overriding_image_and_volume
    @config.database(:postgres) do |db|
      db.image = "pgvector/pgvector:pg17"
      db.volume_size = "50Gi"
    end
    pg = @config.database_configs[:postgres]

    assert_equal "pgvector/pgvector:pg17", pg.image
    assert_equal "50Gi", pg.volume_size
  end

  def test_database_allows_overriding_credentials
    @config.database(:postgres) do |db|
      db.password = "secret"
      db.username = "myuser"
      db.database = "mydb"
    end
    pg = @config.database_configs[:postgres]

    assert_equal "secret", pg.password
    assert_equal "myuser", pg.username
    assert_equal "mydb", pg.database
  end

  def test_database_returns_false_when_none
    refute_predicate @config, :database?
  end

  # ── Service ──

  def test_service_creates_config_with_subdomain
    @config.service(:meilisearch) { |s| s.subdomain = "search" }

    assert @config.service?(:meilisearch)
    assert_equal "search", @config.service_configs[:meilisearch].subdomain
  end

  def test_service_returns_false_when_none
    refute_predicate @config, :service?
  end

  # ── App ──

  def test_app_creates_processes
    @config.app do |a|
      a.process(:web) do |p|
        p.command = "bin/rails server"
        p.port = 3000
      end
      a.process(:worker) { |p| p.command = "bin/jobs" }
    end

    assert_predicate @config, :app?
    assert_equal 2, @config.app_config.processes.size
    assert_equal 3000, @config.app_config.processes[:web].port
  end

  def test_app_allows_replicas_with_hash
    @config.app do |a|
      a.process(:web) { |p| p.replicas = { sandbox: 1, release: 2 } }
    end

    assert_equal({ sandbox: 1, release: 2 }, @config.app_config.processes[:web].replicas)
  end

  # ── Storage ──

  def test_storage_creates_config
    @config.storage { |s| s.subdomain = "assets" }

    assert_predicate @config, :storage?
    assert_equal "assets", @config.storage_config.subdomain
  end

  # ── Value Resolution ──

  def test_resolve_returns_direct_value
    assert_equal "foo", @config.resolve("foo", target: :sandbox)
  end

  def test_resolve_extracts_target_key
    value = { sandbox: "dev", production: "prod" }

    assert_equal "dev", @config.resolve(value, target: :sandbox)
    assert_equal "prod", @config.resolve(value, target: :production)
  end

  def test_resolve_returns_nil_for_missing_target
    assert_nil @config.resolve({ sandbox: "dev" }, target: :staging)
  end

  # ── validate_for_target! ──

  def test_validate_for_target_passes
    @config.compute(:hetzner) do |h|
      h.api_key = "test"
      h.server_type = { sandbox: "cpx11", staging: "cpx21" }
    end

    assert_nil @config.validate_for_target!(:staging)
  end

  def test_validate_for_target_raises_for_missing_server_type
    @config.compute(:hetzner) do |h|
      h.api_key = "test"
      h.server_type = { sandbox: "cpx11", production: "cpx31" }
    end
    error = assert_raises(RbrunCore::ConfigurationError) { @config.validate_for_target!(:staging) }
    assert_includes error.message, "compute.server_type missing key :staging"
  end

  def test_validate_for_target_raises_for_missing_env_var
    @config.compute(:hetzner) do |h|
      h.api_key = "test"
      h.server_type = { sandbox: "cpx11", staging: "cpx21" }
    end
    @config.env(RAILS_ENV: { sandbox: "dev", production: "prod" })
    error = assert_raises(RbrunCore::ConfigurationError) { @config.validate_for_target!(:staging) }
    assert_includes error.message, "env.RAILS_ENV missing key :staging"
  end

  def test_validate_for_target_raises_for_missing_subdomain
    @config.compute(:hetzner) do |h|
      h.api_key = "test"
      h.server_type = { staging: "cpx21", production: "cpx31" }
    end
    @config.app { |a| a.process(:web) { |p| p.subdomain = { production: "www" } } }
    error = assert_raises(RbrunCore::ConfigurationError) { @config.validate_for_target!(:staging) }
    assert_includes error.message, "app.process(:web).subdomain missing key :staging"
  end

  # ── Cloudflare ──

  def test_cloudflare_yields_and_stores
    @config.cloudflare do |cf|
      cf.api_token = "cf-token"
      cf.account_id = "cf-account"
      cf.domain = "example.com"
    end

    assert_equal "cf-token", @config.cloudflare_config.api_token
    assert_predicate @config, :cloudflare_configured?
  end

  def test_cloudflare_configured_false_when_not_set
    refute_predicate @config, :cloudflare_configured?
  end

  # ── Git ──

  def test_git_yields_and_stores_pat
    @config.git do |g|
      g.pat = "token"
      g.repo = "owner/repo"
    end

    assert_equal "token", @config.git_config.pat
    assert_equal "repo", @config.git_config.app_name
  end

  def test_git_defaults_for_username_and_email
    @config.git do |g|
      g.pat = "token"
      g.repo = "owner/repo"
    end

    assert_equal "rbrun", @config.git_config.username
    assert_equal "sandbox@rbrun.dev", @config.git_config.email
  end

  # ── Claude ──

  def test_claude_yields_and_stores
    @config.claude { |c| c.auth_token = "key" }

    assert_equal "key", @config.claude_config.auth_token
    assert_equal "https://api.anthropic.com", @config.claude_config.base_url
    assert_predicate @config, :claude_configured?
  end

  # ── Setup & Env ──

  def test_defaults_to_empty
    assert_empty @config.setup_commands
    assert_empty(@config.env_vars)
  end

  def test_setup_collects_commands
    @config.setup("bundle install", "rails db:prepare")

    assert_equal [ "bundle install", "rails db:prepare" ], @config.setup_commands
  end

  def test_env_collects_variables
    @config.env(RAILS_ENV: { sandbox: "dev", release: "production" })

    assert_equal({ sandbox: "dev", release: "production" }, @config.env_vars[:RAILS_ENV])
  end

  # ── Validation ──

  def test_validate_raises_without_compute
    @config.git do |g|
      g.pat = "t"
      g.repo = "r"
    end
    assert_raises(RbrunCore::ConfigurationError) { @config.validate! }
  end

  def test_validate_raises_without_api_key
    @config.compute(:hetzner)
    @config.git do |g|
      g.pat = "t"
      g.repo = "r"
    end
    assert_raises(RbrunCore::ConfigurationError) { @config.validate! }
  end

  def test_validate_raises_without_git_pat
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.git { |g| g.repo = "r" }
    assert_raises(RbrunCore::ConfigurationError) { @config.validate! }
  end

  def test_validate_passes_with_minimal_config
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.git do |g|
      g.pat = "t"
      g.repo = "r"
    end

    assert_nil @config.validate!
  end
end
