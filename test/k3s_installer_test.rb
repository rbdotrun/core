# frozen_string_literal: true

require "test_helper"

class K3sInstallerTest < Minitest::Test
  def test_server_install_command_includes_primary_and_fallback
    cmd = RbrunCore::K3sInstaller.server_install_command(exec_args: "--disable=traefik")

    assert_includes cmd, "https://get.k3s.io"
    assert_includes cmd, "rancher-mirror"
    assert_includes cmd, "||"
  end

  def test_server_install_command_includes_exec_args
    cmd = RbrunCore::K3sInstaller.server_install_command(exec_args: "--disable=traefik")

    assert_includes cmd, "--disable=traefik"
  end

  def test_server_install_command_structure
    cmd = RbrunCore::K3sInstaller.server_install_command(exec_args: "--test-arg")

    # First attempt uses default GitHub
    assert_match %r{\(curl -sfL https://get\.k3s\.io \| sudo INSTALL_K3S_EXEC="--test-arg" sh -s\)}, cmd
    # Second attempt uses mirror
    assert_match %r{rancher-mirror\.rancher\.cn/k3s/k3s-install\.sh}, cmd
  end

  def test_agent_install_command_includes_primary_and_fallback
    cmd = RbrunCore::K3sInstaller.agent_install_command(
      master_url: "https://10.0.0.1:6443",
      token: "secret-token",
      agent_args: "--node-ip=10.0.0.2"
    )

    assert_includes cmd, "https://get.k3s.io"
    assert_includes cmd, "rancher-mirror"
    assert_includes cmd, "||"
  end

  def test_agent_install_command_includes_cluster_config
    cmd = RbrunCore::K3sInstaller.agent_install_command(
      master_url: "https://10.0.0.1:6443",
      token: "secret-token",
      agent_args: "--node-ip=10.0.0.2"
    )

    assert_includes cmd, "K3S_URL=\"https://10.0.0.1:6443\""
    assert_includes cmd, "K3S_TOKEN=\"secret-token\""
    assert_includes cmd, "agent --node-ip=10.0.0.2"
  end

  def test_mirrors_constant_has_fallback
    assert_operator RbrunCore::K3sInstaller::MIRRORS.size, :>=, 2
  end

  def test_installer_urls_constant_has_fallback
    assert_operator RbrunCore::K3sInstaller::INSTALLER_URLS.size, :>=, 2
  end
end
