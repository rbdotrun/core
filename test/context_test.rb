# frozen_string_literal: true

require "test_helper"

class ContextTest < Minitest::Test
  def test_initializes_with_config_and_target
    ctx = build_context(target: :production)

    assert_equal :production, ctx.target
    assert_kind_of RbrunCore::Configuration, ctx.config
  end

  def test_generates_slug_when_not_provided
    ctx = build_context

    assert_match(/\A[a-f0-9]{6}\z/, ctx.slug)
  end

  def test_uses_provided_slug
    ctx = build_context(slug: "abc123")

    assert_equal "abc123", ctx.slug
  end

  def test_stores_branch
    ctx = build_context(branch: "main")

    assert_equal "main", ctx.branch
  end

  def test_initial_state_is_pending
    ctx = build_context

    assert_equal :pending, ctx.state
  end

  def test_mutable_state_attributes
    ctx = build_context
    ctx.server_id = "srv-123"
    ctx.server_ip = "1.2.3.4"
    ctx.registry_tag = "localhost:5000/app:v1"
    ctx.tunnel_id = "tun-456"

    assert_equal "srv-123", ctx.server_id
    assert_equal "1.2.3.4", ctx.server_ip
    assert_equal "localhost:5000/app:v1", ctx.registry_tag
    assert_equal "tun-456", ctx.tunnel_id
  end

  def test_prefix_for_sandbox_target
    ctx = build_context(target: :sandbox, slug: "a1b2c3")

    assert_equal "rbrun-sandbox-a1b2c3", ctx.prefix
  end

  def test_prefix_for_production_target
    ctx = build_context(target: :production)

    assert_equal "test-repo-production", ctx.prefix
  end

  def test_ssh_client_returns_client_when_configured
    ctx = build_context
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key
    client = ctx.ssh_client

    assert_kind_of RbrunCore::Ssh::Client, client
    assert_equal "1.2.3.4", client.host
  end

  def test_compute_client_returns_provider_client
    ctx = build_context

    assert_respond_to ctx.compute_client, :find_server
  end
end
