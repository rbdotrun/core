# frozen_string_literal: true

require "test_helper"

class StorageConfigTest < Minitest::Test
  def setup
    super
    @config = RbrunCore::Configuration.new
  end

  # ── Storage DSL ──

  def test_storage_creates_bucket_config
    @config.storage do |s|
      s.bucket(:uploads)
    end

    assert_predicate @config, :storage?
  end

  def test_storage_bucket_defaults_to_private
    @config.storage do |s|
      s.bucket(:uploads)
    end

    refute @config.storage_config.buckets[:uploads].public
  end

  def test_storage_bucket_public_option
    @config.storage do |s|
      s.bucket(:uploads) { |b| b.public = true }
    end

    assert @config.storage_config.buckets[:uploads].public
  end

  def test_storage_bucket_cors_hash_config
    @config.storage do |s|
      s.bucket(:uploads) do |b|
        b.cors = { origins: [ "https://example.com" ], methods: %w[GET PUT] }
      end
    end

    bucket = @config.storage_config.buckets[:uploads]

    assert_predicate bucket, :cors?
    refute_predicate bucket, :cors_inferred?
  end

  def test_storage_bucket_cors_true_is_inferred
    @config.storage do |s|
      s.bucket(:uploads) { |b| b.cors = true }
    end

    bucket = @config.storage_config.buckets[:uploads]

    assert_predicate bucket, :cors?
    assert_predicate bucket, :cors_inferred?
  end

  def test_storage_bucket_cors_config_uses_explicit_origins
    @config.storage do |s|
      s.bucket(:uploads) do |b|
        b.cors = { origins: [ "https://example.com" ], methods: %w[GET PUT] }
      end
    end

    cors = @config.storage_config.buckets[:uploads].cors_config

    assert_equal [ "https://example.com" ], cors[:allowed_origins]
    assert_equal %w[GET PUT], cors[:allowed_methods]
  end

  def test_storage_bucket_cors_inferred_uses_passed_origins
    @config.storage do |s|
      s.bucket(:uploads) { |b| b.cors = true }
    end

    inferred = [ "https://www.myapp.com", "https://admin.myapp.com" ]
    cors = @config.storage_config.buckets[:uploads].cors_config(inferred_origins: inferred)

    assert_equal inferred, cors[:allowed_origins]
  end

  def test_storage_bucket_cors_defaults_methods
    @config.storage do |s|
      s.bucket(:uploads) { |b| b.cors = true }
    end

    cors = @config.storage_config.buckets[:uploads].cors_config(inferred_origins: [])

    assert_equal %w[GET PUT POST DELETE HEAD], cors[:allowed_methods]
  end

  def test_storage_multiple_buckets
    @config.storage do |s|
      s.bucket(:uploads) { |b| b.public = true }
      s.bucket(:assets) { |b| b.public = false }
      s.bucket(:backups)
    end

    assert_equal 3, @config.storage_config.buckets.size
  end

  def test_storage_returns_false_when_none
    refute_predicate @config, :storage?
  end
end
