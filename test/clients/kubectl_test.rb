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

  def test_deployment_status_returns_replica_counts
    json = {
      "spec" => { "replicas" => 3 },
      "status" => {
        "readyReplicas" => 2,
        "availableReplicas" => 2,
        "updatedReplicas" => 3
      }
    }.to_json

    with_mocked_ssh(output: json) do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      status = kubectl.deployment_status("myapp-web")

      assert_equal "myapp-web", status[:name]
      assert_equal 3, status[:desired]
      assert_equal 2, status[:ready]
      assert_equal 2, status[:available]
      assert_equal 3, status[:updated]
      refute status[:ready?]
    end
  end

  def test_deployment_status_ready_when_all_replicas_available
    json = {
      "spec" => { "replicas" => 2 },
      "status" => {
        "readyReplicas" => 2,
        "availableReplicas" => 2,
        "updatedReplicas" => 2
      }
    }.to_json

    with_mocked_ssh(output: json) do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      status = kubectl.deployment_status("myapp-web")

      assert status[:ready?]
    end
  end

  def test_deployment_status_returns_nil_on_error
    with_mocked_ssh(output: "", exit_code: 1, exit_code_for: { "kubectl get deployment" => 1 }) do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      status = kubectl.deployment_status("nonexistent")

      assert_nil status
    end
  end

  def test_wait_for_deployments_yields_progress
    json = {
      "spec" => { "replicas" => 1 },
      "status" => {
        "readyReplicas" => 1,
        "availableReplicas" => 1,
        "updatedReplicas" => 1
      }
    }.to_json

    with_mocked_ssh(output: json) do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
      updates = []

      kubectl.wait_for_deployments(["myapp-web"], timeout: 5, interval: 0) do |status|
        updates << status
      end

      assert_equal 1, updates.length
      assert_equal "myapp-web", updates.first[:name]
      assert updates.first[:ready?]
    end
  end

  def test_wait_for_deployments_raises_on_timeout
    json = {
      "spec" => { "replicas" => 2 },
      "status" => {
        "readyReplicas" => 0,
        "availableReplicas" => 0,
        "updatedReplicas" => 0
      }
    }.to_json

    with_mocked_ssh(output: json) do
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = RbrunCore::Clients::Kubectl.new(ctx.ssh_client)

      error = assert_raises(RbrunCore::Error::Standard) do
        kubectl.wait_for_deployments(["myapp-web"], timeout: 0.1, interval: 0.05) {}
      end

      assert_includes error.message, "Rollout timed out"
      assert_includes error.message, "myapp-web"
    end
  end
end
