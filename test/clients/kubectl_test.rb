# frozen_string_literal: true

require "test_helper"

class KubectlTest < Minitest::Test
  def test_exec_finds_pod_and_runs_command
    with_mocked_ssh(output: "my-pod-abc123") do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      result = kubectl.exec("myapp-production-web", "rails console")

      assert_equal "my-pod-abc123", result[:output]
    end
  end

  def test_exec_raises_when_no_pod_found
    with_mocked_ssh(output: "", exit_code_for: { "kubectl get pods" => 1 }) do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)

      error = assert_raises(RbrunCore::Error::Standard) do
        kubectl.exec("myapp-production-web", "rails console")
      end
      assert_includes error.message, "No running pod found"
    end
  end

  def test_get_pod_name_returns_nil_for_empty_output
    with_mocked_ssh(output: "''") do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      result = kubectl.get_pod_name("myapp-production-web")

      assert_nil result
    end
  end

  def test_get_pod_name_returns_name_on_success
    with_mocked_ssh(output: "myapp-production-web-abc123") do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      result = kubectl.get_pod_name("myapp-production-web")

      assert_equal "myapp-production-web-abc123", result
    end
  end

  def test_logs_returns_output
    with_mocked_ssh(output: "log line 1\nlog line 2") do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      result = kubectl.logs("myapp-production-web", tail: 50)

      assert_equal "log line 1\nlog line 2", result[:output]
    end
  end

  def test_drain_sends_cordon_and_drain_commands
    cmds = with_capturing_ssh(output: "") do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      kubectl.drain("my-node", max_attempts: 1, interval: 0)
    end

    assert(cmds.any? { |c| c.include?("kubectl cordon my-node") })
    assert(cmds.any? { |c| c.include?("kubectl drain my-node") && c.include?("--ignore-daemonsets") && c.include?("--delete-emptydir-data") && c.include?("--force") })
  end

  def test_delete_node_sends_correct_command
    cmds = with_capturing_ssh(output: "", exit_code_for: { "kubectl get node" => 1 }) do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      kubectl.delete_node("my-node", max_attempts: 1, interval: 0)
    end

    assert(cmds.any? { |c| c.include?("kubectl delete node my-node --ignore-not-found") })
  end
end
