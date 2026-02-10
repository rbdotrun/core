# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    super
    @config = RbrunCore::Configuration.new
  end

  # ── Target ──

  def test_target_accessor
    @config.target = :production

    assert_equal :production, @config.target
  end

  # ── Compute Provider ──

  def test_compute_creates_hetzner_config_with_correct_provider
    @config.compute(:hetzner) { |c| c.api_key = "key" }

    assert_equal :hetzner, @config.compute_config.provider_name
  end

  def test_compute_creates_hetzner_config_with_default_location_and_image
    @config.compute(:hetzner) { |c| c.api_key = "key" }

    assert_equal "ash", @config.compute_config.location
    assert_equal "ubuntu-22.04", @config.compute_config.image
  end

  def test_compute_master_config
    @config.compute(:hetzner) do |c|
      c.api_key = "key"
      c.master.instance_type = "cpx11"
    end

    assert_equal "cpx11", @config.compute_config.master.instance_type
    assert_equal 1, @config.compute_config.master.count
    refute_predicate @config.compute_config, :multi_server?
  end

  def test_compute_server_groups_enables_multi_server
    @config.compute(:hetzner) do |c|
      c.api_key = "key"
      c.add_server_group(:web, type: "cpx21", count: 2)
      c.add_server_group(:worker, type: "cpx11", count: 1)
    end

    assert_predicate @config.compute_config, :multi_server?
    assert_equal 2, @config.compute_config.servers.size
  end

  def test_compute_server_groups_stores_web_config
    @config.compute(:hetzner) do |c|
      c.api_key = "key"
      c.add_server_group(:web, type: "cpx21", count: 2)
    end

    assert_equal "cpx21", @config.compute_config.servers[:web].type
    assert_equal 2, @config.compute_config.servers[:web].count
  end

  def test_compute_server_groups_stores_worker_config
    @config.compute(:hetzner) do |c|
      c.api_key = "key"
      c.add_server_group(:worker, type: "cpx11", count: 1)
    end

    assert_equal "cpx11", @config.compute_config.servers[:worker].type
  end

  def test_compute_creates_scaleway_config
    @config.compute(:scaleway) do |c|
      c.api_key = "key"
      c.project_id = "proj"
    end

    assert_equal :scaleway, @config.compute_config.provider_name
  end

  def test_compute_creates_aws_config_with_correct_provider
    @config.compute(:aws) do |c|
      c.access_key_id = "AKIAIOSFODNN7EXAMPLE"
      c.secret_access_key = "secret"
    end

    assert_equal :aws, @config.compute_config.provider_name
  end

  def test_compute_creates_aws_config_with_default_region_and_image
    @config.compute(:aws) do |c|
      c.access_key_id = "AKIAIOSFODNN7EXAMPLE"
      c.secret_access_key = "secret"
    end

    assert_equal "us-east-1", @config.compute_config.location
    assert_equal "ubuntu-22.04", @config.compute_config.image
    assert_equal "t3.micro", @config.compute_config.server
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

  def test_database_allows_overriding_image
    @config.database(:postgres) do |db|
      db.image = "pgvector/pgvector:pg17"
    end
    pg = @config.database_configs[:postgres]

    assert_equal "pgvector/pgvector:pg17", pg.image
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

  # Note: database runs_on is no longer supported - databases always run on master

  # ── Service ──

  def test_service_creates_config_with_subdomain
    @config.service(:meilisearch) do |s|
      s.subdomain = "search"
      s.image = "getmeili/meilisearch:v1.6"
    end

    assert @config.service?(:meilisearch)
    assert_equal "search", @config.service_configs[:meilisearch].subdomain
  end

  def test_service_image_is_set_via_writer
    @config.service(:redis) { |s| s.image = "redis:7-alpine" }

    assert_equal "redis:7-alpine", @config.service_configs[:redis].image
  end

  def test_service_returns_false_when_none
    refute_predicate @config, :service?
  end

  def test_service_port_and_mount_path
    @config.service(:meilisearch) do |s|
      s.image = "getmeili/meilisearch:v1.6"
      s.port = 7700
      s.mount_path = "/meili_data"
    end

    svc = @config.service_configs[:meilisearch]

    assert_equal 7700, svc.port
    assert_equal "/meili_data", svc.mount_path
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

  # ── Name ──

  def test_name_accessor
    @config.name = "myapp"

    assert_equal "myapp", @config.name
  end

  # ── Claude ──

  def test_claude_yields_and_stores
    @config.claude { |c| c.auth_token = "key" }

    assert_equal "key", @config.claude_config.auth_token
    assert_equal "https://api.anthropic.com", @config.claude_config.base_url
    assert_predicate @config, :claude_configured?
  end

  # ── Env ──

  def test_defaults_to_empty
    assert_empty(@config.env_vars)
  end

  def test_env_collects_variables
    @config.env(RAILS_ENV: "production")

    assert_equal "production", @config.env_vars[:RAILS_ENV]
  end

  # ── Validation ──

  def test_validate_raises_without_compute
    assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
  end

  def test_validate_raises_without_api_key
    @config.compute(:hetzner)
    assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
  end

  def test_validate_raises_when_target_not_set
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end

    error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
    assert_match(/target is required/, error.message)
  end

  def test_validate_raises_when_name_not_set
    @config.target = :production
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end

    error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
    assert_match(/name is required/, error.message)
  end

  def test_validate_raises_when_name_starts_with_number
    @config.target = :production
    @config.name = "2025-app"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end

    error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
    assert_match(/name must start with a lowercase letter/, error.message)
  end

  def test_validate_passes_with_minimal_config
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end

    assert_nil @config.validate!
  end

  def test_validate_raises_when_process_has_subdomain_without_cloudflare
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.app do |a|
      a.process(:web) do |p|
        p.command = "bin/rails server"
        p.subdomain = "myapp"
      end
    end

    error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
    assert_match(/Cloudflare configuration required/, error.message)
  end

  def test_validate_raises_when_service_has_subdomain_without_cloudflare
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.service(:meilisearch) do |s|
      s.image = "getmeili/meilisearch:v1.6"
      s.subdomain = "search"
    end

    error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
    assert_match(/Cloudflare configuration required/, error.message)
  end

  def test_validate_passes_when_subdomain_with_cloudflare_configured
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.cloudflare do |cf|
      cf.api_token = "tok"
      cf.account_id = "acc"
      cf.domain = "example.com"
    end
    @config.app do |a|
      a.process(:web) do |p|
        p.command = "bin/rails server"
        p.subdomain = "myapp"
      end
    end

    assert_nil @config.validate!
  end

  def test_validate_passes_when_no_subdomains_and_no_cloudflare
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.app do |a|
      a.process(:web) { |p| p.command = "bin/rails server" }
    end

    assert_nil @config.validate!
  end

  # ── Instance Type Validation ──

  def test_validate_raises_when_service_has_replicas_without_instance_type
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.service(:meilisearch) do |s|
      s.image = "getmeili/meilisearch:v1.6"
      s.replicas = 2
    end

    error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
    assert_match(/replicas but no instance_type/, error.message)
    assert_match(/meilisearch/, error.message)
  end

  def test_validate_passes_when_service_has_instance_type_with_replicas
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.service(:meilisearch) do |s|
      s.image = "getmeili/meilisearch:v1.6"
      s.instance_type = "cx22"
      s.replicas = 2
    end

    assert_nil @config.validate!
  end

  def test_validate_passes_when_service_has_instance_type_without_replicas
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.service(:meilisearch) do |s|
      s.image = "getmeili/meilisearch:v1.6"
      s.instance_type = "cx22"
    end

    assert_nil @config.validate!
  end

  def test_validate_raises_when_service_has_mount_path_with_replicas
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.service(:meilisearch) do |s|
      s.image = "getmeili/meilisearch:v1.6"
      s.mount_path = "/meili_data"
      s.replicas = 2
    end

    error = assert_raises(RbrunCore::Error::Configuration) { @config.validate! }
    assert_match(/mount_path with replicas/, error.message)
  end

  def test_validate_passes_when_service_has_mount_path_with_instance_type
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.service(:meilisearch) do |s|
      s.image = "getmeili/meilisearch:v1.6"
      s.mount_path = "/meili_data"
      s.instance_type = "cx22"
    end

    assert_nil @config.validate!
  end

  def test_validate_passes_when_service_has_mount_path_without_replicas_or_instance_type
    @config.target = :production
    @config.name = "myapp"
    @config.compute(:hetzner) do |c|
      c.api_key = "k"
      c.ssh_key_path = TEST_SSH_KEY_PATH
    end
    @config.service(:meilisearch) do |s|
      s.image = "getmeili/meilisearch:v1.6"
      s.mount_path = "/meili_data"
    end

    assert_nil @config.validate!
  end
end
