# frozen_string_literal: true

module RbrunCore
  module Kubernetes
    # Minimal kubectl wrapper via SSH.
    # Unlike the engine version, this operates on an SSH client directly.
    class Kubectl
      attr_reader :ssh_client

      def initialize(ssh_client)
        @ssh_client = ssh_client
      end

      def apply(manifest_yaml)
        run!("kubectl apply -f - << 'EOF'\n#{manifest_yaml}\nEOF")
      end

      def delete(manifest_yaml)
        run!("kubectl delete -f - --ignore-not-found << 'EOF'\n#{manifest_yaml}\nEOF", raise_on_error: false)
      end

      def get(resource, name = nil, namespace: "default")
        cmd = "kubectl get #{resource}"
        cmd += " #{name}" if name
        cmd += " -n #{namespace} -o json"
        result = run!(cmd, raise_on_error: false)
        return nil unless result[:exit_code] == 0
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

      def delete_resource(resource, name, namespace: "default")
        run!("kubectl delete #{resource} #{name} -n #{namespace} --ignore-not-found", raise_on_error: false)
      end

      private

        def run!(command, raise_on_error: true, timeout: 300)
          ssh_client.execute(command, raise_on_error:, timeout:)
        end
    end
  end
end
