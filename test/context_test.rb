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

  def test_auto_detects_branch_when_not_provided
    ctx = build_context
    # We're running in a git repo, so branch should be auto-detected
    refute_nil ctx.branch
  end

  def test_auto_detects_target_from_config
    config = build_config
    config.target = :staging
    ctx = RbrunCore::Context.new(config:)

    assert_equal :staging, ctx.target
  end

  def test_target_uses_config_target
    config = build_config(target: :staging)

    ctx = RbrunCore::Context.new(config:)

    assert_equal :staging, ctx.target
  end

  def test_initial_state_is_pending
    ctx = build_context

    assert_equal :pending, ctx.state
  end

  def test_mutable_server_attributes
    ctx = build_context
    ctx.server_id = "srv-123"
    ctx.server_ip = "1.2.3.4"

    assert_equal "srv-123", ctx.server_id
    assert_equal "1.2.3.4", ctx.server_ip
  end

  def test_mutable_registry_and_tunnel_attributes
    ctx = build_context
    ctx.registry_tag = "localhost:5000/app:v1"
    ctx.tunnel_id = "tun-456"

    assert_equal "localhost:5000/app:v1", ctx.registry_tag
    assert_equal "tun-456", ctx.tunnel_id
  end

  def test_prefix_for_sandbox_target
    ctx = build_context(target: :sandbox, slug: "a1b2c3")

    assert_equal "rbrun-sandbox-a1b2c3", ctx.prefix
  end

  def test_prefix_for_production_target
    ctx = build_context(target: :production)

    assert_equal "testapp-production", ctx.prefix
  end

  def test_ssh_client_returns_client_when_configured
    ctx = build_context
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key
    client = ctx.ssh_client

    assert_kind_of RbrunCore::Clients::Ssh, client
    assert_equal "1.2.3.4", client.host
  end

  def test_compute_client_returns_provider_client
    ctx = build_context

    assert_respond_to ctx.compute_client, :find_server
  end

  def test_servers_hash_defaults_to_empty
    ctx = build_context

    assert_empty(ctx.servers)
  end

  def test_servers_hash_is_mutable
    ctx = build_context
    ctx.servers = { "web-1" => { id: "srv-1", ip: "1.2.3.4", group: "web" } }

    assert_equal "srv-1", ctx.servers["web-1"][:id]
  end

  def test_new_servers_defaults_to_empty_set
    ctx = build_context

    assert_instance_of Set, ctx.new_servers
    assert_empty ctx.new_servers
  end

  def test_new_servers_is_mutable
    ctx = build_context
    ctx.new_servers.add("web-2")

    assert_includes ctx.new_servers, "web-2"
  end
end
