# frozen_string_literal: true

require "test_helper"

class NamingTest < Minitest::Test
  VALID_SLUG = "a1b2c3"

  def test_prefix_is_rbrun_sandbox
    assert_equal "rbrun-sandbox", RbrunCore::Naming::PREFIX
  end

  def test_slug_length_is_6
    assert_equal 6, RbrunCore::Naming::SLUG_LENGTH
  end

  def test_generate_slug_returns_6_hex_chars
    slug = RbrunCore::Naming.generate_slug

    assert_equal 6, slug.length
    assert_match(/\A[a-f0-9]{6}\z/, slug)
  end

  def test_generate_slug_returns_unique_values
    slugs = 100.times.map { RbrunCore::Naming.generate_slug }

    assert_equal 100, slugs.uniq.size
  end

  def test_valid_slug_true_for_valid
    assert RbrunCore::Naming.valid_slug?(VALID_SLUG)
  end

  def test_valid_slug_false_for_invalid
    refute RbrunCore::Naming.valid_slug?(nil)
    refute RbrunCore::Naming.valid_slug?("")
    refute RbrunCore::Naming.valid_slug?("abc")
    refute RbrunCore::Naming.valid_slug?("ABCDEF")
    refute RbrunCore::Naming.valid_slug?("a1b2cg")
  end

  def test_validate_slug_raises_for_invalid
    assert_raises(ArgumentError) { RbrunCore::Naming.validate_slug!("invalid") }
  end

  def test_resource_returns_prefixed_name
    assert_equal "rbrun-sandbox-a1b2c3", RbrunCore::Naming.resource(VALID_SLUG)
  end

  def test_resource_raises_for_invalid_slug
    assert_raises(ArgumentError) { RbrunCore::Naming.resource("bad") }
  end

  def test_container_returns_prefixed_name_with_role
    assert_equal "rbrun-sandbox-a1b2c3-app", RbrunCore::Naming.container(VALID_SLUG, "app")
  end

  def test_branch_returns_prefixed_branch
    assert_equal "rbrun-sandbox/a1b2c3", RbrunCore::Naming.branch(VALID_SLUG)
  end

  def test_release_prefix_returns_app_environment
    assert_equal "myapp-production", RbrunCore::Naming.release_prefix("myapp", "production")
    assert_equal "myapp-staging", RbrunCore::Naming.release_prefix("myapp", :staging)
  end

  def test_hostname_returns_prefixed_hostname
    assert_equal "rbrun-sandbox-a1b2c3.rb.run", RbrunCore::Naming.hostname(VALID_SLUG, "rb.run")
  end

  def test_self_hosted_preview_url_returns_https
    assert_equal "https://rbrun-sandbox-a1b2c3.rb.run",
                 RbrunCore::Naming.self_hosted_preview_url(VALID_SLUG, "rb.run")
  end

  def test_worker_returns_prefixed_worker_name
    assert_equal "rbrun-sandbox-widget-a1b2c3", RbrunCore::Naming.worker(VALID_SLUG)
  end

  def test_worker_route_returns_route_pattern
    assert_equal "rbrun-sandbox-a1b2c3.rb.run/*", RbrunCore::Naming.worker_route(VALID_SLUG, "rb.run")
  end

  def test_roundtrip
    slug = RbrunCore::Naming.generate_slug
    RbrunCore::Naming.resource(slug)
    RbrunCore::Naming.container(slug, "app")
    RbrunCore::Naming.branch(slug)
    RbrunCore::Naming.hostname(slug, "rb.run")
    RbrunCore::Naming.worker(slug)
  end

  def test_slug_extractable_from_resource
    slug = RbrunCore::Naming.generate_slug
    resource = RbrunCore::Naming.resource(slug)
    extracted = resource.match(RbrunCore::Naming.resource_regex)[1]

    assert_equal slug, extracted
  end
end
