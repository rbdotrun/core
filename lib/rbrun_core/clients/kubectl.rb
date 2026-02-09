# frozen_string_literal: true

module RbrunCore
  module Clients
    # Minimal kubectl wrapper via SSH.
    class Kubectl
      attr_reader :ssh_client

      def initialize(ssh_client)
        @ssh_client = ssh_client
      end

      def apply(manifest_yaml)
        encoded = Base64.strict_encode64(manifest_yaml)
        run!("echo '#{encoded}' | base64 -d | kubectl apply -f -")
      end

      def delete(manifest_yaml)
        encoded = Base64.strict_encode64(manifest_yaml)
        run!("echo '#{encoded}' | base64 -d | kubectl delete -f - --ignore-not-found", raise_on_error: false)
      end

      def get(resource, name = nil, namespace: "default")
        cmd = [ "kubectl", "get", resource ]
        cmd << name if name
        cmd += [ "-n", namespace, "-o", "json" ]

        result = run!(cmd.join(" "), raise_on_error: false)
        return nil unless result[:exit_code].zero?

        JSON.parse(result[:output])
      end

      def logs(deployment, tail: 100, namespace: "default", follow: false, &block)
        cmd = [ "kubectl", "logs", "deployment/#{deployment}", "-n", namespace, "--tail=#{tail}" ]
        cmd += [ "-f", "--all-containers" ] if follow

        run!(cmd.join(" "), &block)
      end

      def scale(deployment, replicas:, namespace: "default")
        cmd = [ "kubectl", "scale", "deployment/#{deployment}", "--replicas=#{replicas}", "-n", namespace ]
        run!(cmd.join(" "))
      end

      def rollout_restart(deployment, namespace: "default")
        cmd = [ "kubectl", "rollout", "restart", "deployment/#{deployment}", "-n", namespace ]
        run!(cmd.join(" "))
      end

      def rollout_status(deployment, namespace: "default", timeout: 300)
        cmd = [ "kubectl", "rollout", "status", "deployment/#{deployment}", "-n", namespace, "--timeout=#{timeout}s" ]
        run!(cmd.join(" "))
      end

      def get_pods(namespace: "default")
        cmd = [ "kubectl", "get", "pods", "-n", namespace, "-o", "json" ]
        result = run!(cmd.join(" "), raise_on_error: false)
        return [] unless result[:exit_code].zero?

        data = JSON.parse(result[:output])
        items = data["items"] || []
        items.map { |pod| parse_pod(pod) }
      end

      def exec(deployment, command, namespace: "default", &block)
        pod = get_pod_name(deployment, namespace:)
        raise Error::Standard, "No running pod found for #{deployment}" unless pod

        cmd = [ "kubectl", "exec", pod, "-n", namespace, "--", command ]
        run!(cmd.join(" "), &block)
      end

      def get_pod_name(deployment, namespace: "default")
        cmd = [
          "kubectl", "get", "pods",
          "-l", "#{K3s::Naming::LABEL_APP}=#{deployment}",
          "-n", namespace,
          "-o", "jsonpath='{.items[0].metadata.name}'"
        ]
        result = run!(cmd.join(" "), raise_on_error: false)
        return nil unless result[:exit_code].zero?

        name = result[:output].strip.delete("'")
        name.empty? ? nil : name
      end

      def delete_resource(resource, name, namespace: "default")
        cmd = [ "kubectl", "delete", resource, name, "-n", namespace, "--ignore-not-found" ]
        run!(cmd.join(" "), raise_on_error: false)
      end

      def create_job_from_cronjob(cronjob_name, namespace: "default")
        job_name = K3s::Naming.manual_job(cronjob_name)
        cmd = [ "kubectl", "create", "job", job_name, "--from=cronjob/#{cronjob_name}", "-n", namespace ]
        run!(cmd.join(" "))
        job_name
      end

      def wait_for_job(job_name, namespace: "default", timeout: 300)
        cmd = [ "kubectl", "wait", "--for=condition=complete", "--timeout=#{timeout}s", "job/#{job_name}", "-n", namespace ]
        run!(cmd.join(" "))
        :complete
      rescue Clients::Ssh::CommandError => e
        handle_job_failure(e, job_name, namespace, timeout)
      end

      def drain(node_name, max_attempts: 12, interval: 5)
        run!(cordon_command(node_name))
        run!(drain_command(node_name), raise_on_error: false)

        Waiter.poll(max_attempts:, interval:, message: "Node #{node_name} still has pods after #{max_attempts * interval}s") do
          node_drained?(node_name)
        end
      end

      def delete_node(node_name, max_attempts: 12, interval: 5)
        cmd = [ "kubectl", "delete", "node", node_name, "--ignore-not-found" ]
        run!(cmd.join(" "))

        Waiter.poll(max_attempts:, interval:, message: "Node #{node_name} still present after #{max_attempts * interval}s") do
          node_deleted?(node_name)
        end
      end

      private

        def run!(command, raise_on_error: true, timeout: 300, &block)
          ssh_client.execute(command, raise_on_error:, timeout:, &block)
        end

        def parse_pod(pod)
          containers = pod.dig("status", "containerStatuses") || []
          ready_count = containers.count { |c| c["ready"] }
          total = [ containers.size, 1 ].max
          phase = pod.dig("status", "phase") || "Pending"
          status = extract_pod_status(containers, phase)

          {
            name: pod.dig("metadata", "name"),
            app: pod.dig("metadata", "labels", K3s::Naming::LABEL_APP),
            ready_count:,
            total:,
            status:,
            ready: pod_ready?(phase, ready_count, total)
          }
        end

        def extract_pod_status(containers, phase)
          waiting = containers.find { |c| c.dig("state", "waiting") }
          waiting&.dig("state", "waiting", "reason") || phase
        end

        def pod_ready?(phase, ready_count, total)
          phase == "Running" && ready_count == total && total > 0
        end

        def handle_job_failure(error, job_name, namespace, timeout)
          if error.output.include?("timed out")
            raise Error::Standard, "Job #{job_name} timed out after #{timeout}s"
          end

          if job_failed?(job_name, namespace)
            raise Error::Standard, "Job #{job_name} failed"
          end

          raise
        end

        def job_failed?(job_name, namespace)
          cmd = [ "kubectl", "get", "job", job_name, "-n", namespace, "-o", "jsonpath='{.status.failed}'" ]
          result = run!(cmd.join(" "), raise_on_error: false)
          result[:output].strip.delete("'").to_i > 0
        end

        def cordon_command(node_name)
          [ "kubectl", "cordon", node_name ].join(" ")
        end

        def drain_command(node_name)
          [
            "kubectl", "drain", node_name,
            "--ignore-daemonsets", "--delete-emptydir-data", "--force", "--grace-period=30"
          ].join(" ")
        end

        def node_drained?(node_name)
          cmd = [
            "kubectl", "get", "pods", "--all-namespaces",
            "--field-selector", "spec.nodeName=#{node_name}",
            "-o", "jsonpath='{.items[?(@.metadata.ownerReferences[0].kind!=\"DaemonSet\")].metadata.name}'"
          ]
          result = run!(cmd.join(" "), raise_on_error: false)
          result[:output].strip.delete("'").empty?
        end

        def node_deleted?(node_name)
          cmd = [ "kubectl", "get", "node", node_name, "-o", "name" ]
          result = run!(cmd.join(" "), raise_on_error: false)
          result[:exit_code] != 0 || result[:output].strip.empty?
        end
    end
  end
end
