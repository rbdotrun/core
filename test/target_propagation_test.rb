# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Comprehensive tests for target propagation through the entire stack.
# Target must flow from config YAML → Context → Naming → K8s resources.
class TargetPropagationTest < Minitest::Test
  # ─── Config Loading ───

  def test_config_loader_parses_target_from_yaml
    with_yaml_config(target: "staging") do |path|
      config = RbrunCore::Config::Loader.load(path)
      assert_equal :staging, config.target
    end
  end

  def test_config_loader_parses_custom_target
    with_yaml_config(target: "canary") do |path|
      config = RbrunCore::Config::Loader.load(path)
      assert_equal :canary, config.target
    end
  end

  def test_config_target_defaults_to_nil_when_not_specified
    with_yaml_config(target: nil) do |path|
      config = RbrunCore::Config::Loader.load(path)
      assert_nil config.target
    end
  end

  # ─── Context Target Resolution ───

  def test_context_uses_explicit_target_over_config
    config = build_config
    config.target = :staging

    ctx = RbrunCore::Context.new(config:, target: :production)

    assert_equal :production, ctx.target
  end

  def test_context_uses_config_target_when_no_explicit_target
    config = build_config
    config.target = :staging

    ctx = RbrunCore::Context.new(config:)

    assert_equal :staging, ctx.target
  end

  def test_context_defaults_to_production_when_no_target_anywhere
    config = build_config
    config.target = nil

    ctx = RbrunCore::Context.new(config:)

    assert_equal :production, ctx.target
  end

  # ─── Prefix Generation ───

  def test_prefix_for_staging_target
    config = build_config
    ctx = RbrunCore::Context.new(config:, target: :staging)

    assert_equal "test-repo-staging", ctx.prefix
  end

  def test_prefix_for_production_target
    config = build_config
    ctx = RbrunCore::Context.new(config:, target: :production)

    assert_equal "test-repo-production", ctx.prefix
  end

  def test_prefix_for_custom_target
    config = build_config
    ctx = RbrunCore::Context.new(config:, target: :canary)

    assert_equal "test-repo-canary", ctx.prefix
  end

  def test_prefix_for_sandbox_uses_slug
    config = build_config
    ctx = RbrunCore::Context.new(config:, target: :sandbox, slug: "abc123")

    assert_equal "rbrun-sandbox-abc123", ctx.prefix
  end

  # ─── App Name Lowercase ───

  def test_app_name_is_lowercased
    config = build_config
    config.git do |g|
      g.repo = "CPFF/2025-CRM-REGTECH"
    end

    assert_equal "2025-crm-regtech", config.git_config.app_name
  end

  def test_app_name_lowercase_propagates_to_prefix
    config = build_config
    config.git do |g|
      g.repo = "CPFF/MyApp-NAME"
    end
    ctx = RbrunCore::Context.new(config:, target: :staging)

    assert_equal "myapp-name-staging", ctx.prefix
  end

  # ─── Naming Module ───

  def test_release_prefix_with_staging
    prefix = RbrunCore::Naming.release_prefix("myapp", :staging)

    assert_equal "myapp-staging", prefix
  end

  def test_release_prefix_with_production
    prefix = RbrunCore::Naming.release_prefix("myapp", :production)

    assert_equal "myapp-production", prefix
  end

  def test_release_prefix_with_custom_environment
    prefix = RbrunCore::Naming.release_prefix("myapp", :preview)

    assert_equal "myapp-preview", prefix
  end

  def test_backup_bucket_includes_target
    bucket = RbrunCore::Naming.backup_bucket("myapp", :staging)

    assert_equal "myapp-staging-backups", bucket
  end

  def test_database_volume_includes_prefix
    volume = RbrunCore::Naming.database_volume("myapp-staging", :postgres)

    assert_equal "myapp-staging-postgres-data", volume
  end

  # ─── K8s Generator Labels ───

  def test_k3s_generator_uses_prefix_in_yaml_output
    config = build_config_with_app
    prefix = "myapp-staging"

    generator = RbrunCore::Generators::K3s.new(
      config, prefix:, zone: "test.dev", db_password: "secret", registry_tag: "test:latest"
    )

    yaml_output = generator.generate
    manifests = YAML.load_stream(yaml_output).compact

    deployment = manifests.find { |m| m&.dig("kind") == "Deployment" && m.dig("metadata", "name")&.include?("web") }

    assert deployment, "Should have a web deployment"
    assert_equal prefix, deployment.dig("metadata", "labels", RbrunCore::Naming::LABEL_INSTANCE)
    assert_equal prefix, deployment.dig("spec", "template", "metadata", "labels", RbrunCore::Naming::LABEL_INSTANCE)
  end

  def test_k3s_generator_service_names_include_prefix
    config = build_config_with_app
    prefix = "myapp-staging"

    generator = RbrunCore::Generators::K3s.new(
      config, prefix:, zone: "test.dev", db_password: "secret", registry_tag: "test:latest"
    )

    yaml_output = generator.generate
    manifests = YAML.load_stream(yaml_output).compact
    services = manifests.select { |m| m&.dig("kind") == "Service" }

    services.each do |svc|
      assert svc.dig("metadata", "name").start_with?(prefix),
             "Service #{svc.dig('metadata', 'name')} should start with #{prefix}"
    end
  end

  def test_k3s_generator_postgres_uses_prefix
    config = build_config_with_postgres
    prefix = "myapp-staging"

    generator = RbrunCore::Generators::K3s.new(
      config, prefix:, zone: "test.dev", db_password: "secret", registry_tag: "test:latest"
    )

    yaml_output = generator.generate
    manifests = YAML.load_stream(yaml_output).compact
    postgres_sts = manifests.find { |m| m&.dig("kind") == "StatefulSet" && m.dig("metadata", "name")&.include?("postgres") }

    assert postgres_sts, "Should have postgres StatefulSet"
    assert_equal "#{prefix}-postgres", postgres_sts.dig("metadata", "name")
  end

  def test_k3s_generator_secret_names_include_prefix
    config = build_config_with_app
    prefix = "myapp-production"

    generator = RbrunCore::Generators::K3s.new(
      config, prefix:, zone: "test.dev", db_password: "secret", registry_tag: "test:latest"
    )

    yaml_output = generator.generate
    manifests = YAML.load_stream(yaml_output).compact
    secrets = manifests.select { |m| m&.dig("kind") == "Secret" }

    secrets.each do |secret|
      assert secret.dig("metadata", "name").start_with?(prefix),
             "Secret #{secret.dig('metadata', 'name')} should start with #{prefix}"
    end
  end

  # ─── End-to-end: Config → Context → Prefix ───

  def test_staging_config_produces_staging_prefix
    with_yaml_config(target: "staging") do |path|
      config = RbrunCore::Config::Loader.load(path)
      ctx = RbrunCore::Context.new(config:)

      assert_equal :staging, ctx.target
      assert ctx.prefix.end_with?("-staging"), "Prefix should end with -staging, got: #{ctx.prefix}"
    end
  end

  def test_production_config_produces_production_prefix
    with_yaml_config(target: "production") do |path|
      config = RbrunCore::Config::Loader.load(path)
      ctx = RbrunCore::Context.new(config:)

      assert_equal :production, ctx.target
      assert ctx.prefix.end_with?("-production"), "Prefix should end with -production, got: #{ctx.prefix}"
    end
  end

  private

    def with_yaml_config(target:)
      Dir.mktmpdir do |dir|
        yaml = {
          "compute" => {
            "provider" => "hetzner",
            "api_key" => "test-key",
            "ssh_key_path" => TEST_SSH_KEY_PATH,
            "master" => { "instance_type" => "cpx11" }
          }
        }
        yaml["target"] = target if target

        path = File.join(dir, "rbrun.yaml")
        File.write(path, YAML.dump(yaml))
        yield path
      end
    end

    def build_config_with_app
      config = build_config
      config.app do |a|
        a.process(:web) do |p|
          p.port = 80
          p.subdomain = "www"
        end
      end
      config
    end

    def build_config_with_postgres
      config = build_config
      config.database(:postgres) do |db|
        db.username = "app"
        db.database = "app"
      end
      config.app do |a|
        a.process(:web) do |p|
          p.port = 80
        end
      end
      config
    end
end
