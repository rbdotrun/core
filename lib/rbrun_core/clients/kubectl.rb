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

      def logs(deployment, tail: 100, namespace: "default", follow: false, &block)
        cmd = "kubectl logs deployment/#{deployment} -n #{namespace} --tail=#{tail}"
        cmd += " -f --all-containers" if follow
        run!(cmd, &block)
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

      # Get pods as structured data
      def get_pods(namespace: "default")
        result = run!("kubectl get pods -n #{namespace} -o json", raise_on_error: false)
        return [] unless result[:exit_code].zero?

        items = JSON.parse(result[:output])["items"] || []
        items.map { |pod| parse_pod(pod) }
      end

      def parse_pod(pod)
        containers = pod.dig("status", "containerStatuses") || []
        ready_count = containers.count { |c| c["ready"] }
        total = [ containers.size, 1 ].max

        phase = pod.dig("status", "phase") || "Pending"
        waiting = containers.find { |c| c.dig("state", "waiting") }
        status = waiting&.dig("state", "waiting", "reason") || phase

        {
          name: pod.dig("metadata", "name"),
          app: pod.dig("metadata", "labels", Naming::LABEL_APP),
          ready_count:,
          total:,
          status:,
          ready: phase == "Running" && ready_count == total && total > 0
        }
      end

      def exec(deployment, command, namespace: "default", &block)
        pod = get_pod_name(deployment, namespace:)
        raise Error::Standard, "No running pod found for #{deployment}" unless pod

        run!("kubectl exec #{pod} -n #{namespace} -- #{command}", &block)
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

      def create_job_from_cronjob(cronjob_name, namespace: "default")
        job_name = Naming.manual_job(cronjob_name)
        run!("kubectl create job #{job_name} --from=cronjob/#{cronjob_name} -n #{namespace}")
        job_name
      end

      def wait_for_job(job_name, namespace: "default", timeout: 300)
        run!("kubectl wait --for=condition=complete --timeout=#{timeout}s job/#{job_name} -n #{namespace}")
        :complete
      rescue Clients::Ssh::CommandError => e
        if e.output.include?("timed out")
          raise Error::Standard, "Job #{job_name} timed out after #{timeout}s"
        end

        result = run!("kubectl get job #{job_name} -n #{namespace} -o jsonpath='{.status.failed}'", raise_on_error: false)
        if result[:output].strip.delete("'").to_i > 0
          raise Error::Standard, "Job #{job_name} failed"
        end

        raise
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

        def run!(command, raise_on_error: true, timeout: 300, &block)
          ssh_client.execute(command, raise_on_error:, timeout:, &block)
        end
    end
  end
end
