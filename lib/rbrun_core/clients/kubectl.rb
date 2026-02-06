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
        cmd = "kubectl get #{resource}"
        cmd += " #{name}" if name
        cmd += " -n #{namespace} -o json"
        result = run!(cmd, raise_on_error: false)
        return nil unless result[:exit_code].zero?

        JSON.parse(result[:output])
      end

      def logs(deployment, tail: 100, namespace: "default")
        run!("kubectl logs deployment/#{deployment} -n #{namespace} --tail=#{tail}")
      end

      def scale(deployment, replicas:, namespace: "default")
        run!("kubectl scale deployment/#{deployment} --replicas=#{replicas} -n #{namespace}")
      end

      def rollout_restart(deployment, namespace: "default")
        run!("kubectl rollout restart deployment/#{deployment} -n #{namespace}")
      end

      def rollout_status(deployment, namespace: "default", timeout: 300)
        run!("kubectl rollout status deployment/#{deployment} -n #{namespace} --timeout=#{timeout}s")
      end

      # Get deployment replica status for progress tracking.
      # Returns { name:, ready:, desired:, available:, updated:, ready?: }
      def deployment_status(deployment, namespace: "default")
        result = run!(
          "kubectl get deployment #{deployment} -n #{namespace} -o json",
          raise_on_error: false
        )

        return nil unless result[:exit_code].zero?

        data = JSON.parse(result[:output])
        status = data["status"] || {}
        spec = data["spec"] || {}

        desired = spec["replicas"] || 0
        ready = status["readyReplicas"] || 0
        available = status["availableReplicas"] || 0
        updated = status["updatedReplicas"] || 0

        {
          name: deployment,
          ready:,
          desired:,
          available:,
          updated:,
          ready?: ready >= desired && updated >= desired && available >= desired
        }
      end

      # Wait for multiple deployments to roll out, yielding progress updates.
      # Yields { name:, ready:, desired:, ready?: } for each deployment on each poll.
      def wait_for_deployments(deployments, namespace: "default", timeout: 300, interval: 2)
        deadline = Time.now + timeout
        pending = deployments.dup

        while pending.any? && Time.now < deadline
          pending.each do |deployment|
            status = deployment_status(deployment, namespace:)
            yield status if block_given? && status

            pending.delete(deployment) if status&.dig(:ready?)
          end

          sleep interval if pending.any? && Time.now < deadline
        end

        raise Error::Standard, "Rollout timed out for: #{pending.join(", ")}" if pending.any?
      end

      def exec(deployment, command, namespace: "default")
        pod = get_pod_name(deployment, namespace:)
        raise Error::Standard, "No running pod found for #{deployment}" unless pod

        run!("kubectl exec #{pod} -n #{namespace} -- #{command}")
      end

      def get_pod_name(deployment, namespace: "default")
        result = run!("kubectl get pods -l #{Naming::LABEL_APP}=#{deployment} -n #{namespace} -o jsonpath='{.items[0].metadata.name}'",
                       raise_on_error: false)
        return nil unless result[:exit_code].zero?

        name = result[:output].strip.delete("'")
        name.empty? ? nil : name
      end

      def delete_resource(resource, name, namespace: "default")
        run!("kubectl delete #{resource} #{name} -n #{namespace} --ignore-not-found", raise_on_error: false)
      end

      def drain(node_name, max_attempts: 12, interval: 5)
        run!("kubectl cordon #{node_name}")
        run!("kubectl drain #{node_name} --ignore-daemonsets --delete-emptydir-data --force --grace-period=30",
             raise_on_error: false)

        Waiter.poll(max_attempts:, interval:, message: "Node #{node_name} still has pods after #{max_attempts * interval}s") do
          result = run!(
            "kubectl get pods --all-namespaces --field-selector spec.nodeName=#{node_name} " \
            "-o jsonpath='{.items[?(@.metadata.ownerReferences[0].kind!=\"DaemonSet\")].metadata.name}'",
            raise_on_error: false
          )
          result[:output].strip.delete("'").empty?
        end
      end

      def delete_node(node_name, max_attempts: 12, interval: 5)
        run!("kubectl delete node #{node_name} --ignore-not-found")

        Waiter.poll(max_attempts:, interval:, message: "Node #{node_name} still present after #{max_attempts * interval}s") do
          result = run!("kubectl get node #{node_name} -o name", raise_on_error: false)
          result[:exit_code] != 0 || result[:output].strip.empty?
        end
      end

      private

        def run!(command, raise_on_error: true, timeout: 300)
          ssh_client.execute(command, raise_on_error:, timeout:)
        end
    end
  end
end
