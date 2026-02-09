# frozen_string_literal: true

module RbrunCore
  module K3s
    class Generators
      module Primitives
        private

          def labels(name)
            {
              Naming::LABEL_APP => name,
              Naming::LABEL_INSTANCE => @prefix,
              Naming::LABEL_MANAGED_BY => "rbrun"
            }
          end

          def deployment(name:, containers:, volumes: [], replicas: 1, host_network: false, node_selector: nil,
                         init_containers: [])
            spec = build_deployment_pod_spec(containers, init_containers, volumes, host_network, node_selector)

            {
              apiVersion: "apps/v1",
              kind: "Deployment",
              metadata: { name:, namespace: NAMESPACE, labels: labels(name) },
              spec: {
                replicas:,
                selector: { matchLabels: { Naming::LABEL_APP => name } },
                template: { metadata: { labels: labels(name) }, spec: }
              }
            }
          end

          def build_deployment_pod_spec(containers, init_containers, volumes, host_network, node_selector)
            spec = { containers: }
            spec[:initContainers] = init_containers if init_containers.any?
            spec[:volumes] = volumes if volumes.any?
            spec[:hostNetwork] = true if host_network

            if node_selector == :affinity
              affinity = build_node_affinity
              spec[:affinity] = affinity if affinity
            elsif node_selector
              spec[:nodeSelector] = node_selector
            end

            spec
          end

          def build_node_affinity
            process = find_multi_node_process
            return nil unless process

            {
              nodeAffinity: {
                requiredDuringSchedulingIgnoredDuringExecution: {
                  nodeSelectorTerms: [
                    {
                      matchExpressions: [
                        {
                          key: Naming::LABEL_SERVER_GROUP,
                          operator: "In",
                          values: process.runs_on.map(&:to_s)
                        }
                      ]
                    }
                  ]
                }
              }
            }
          end

          def find_multi_node_process
            @config.app_config&.processes&.values&.find do |p|
              p.runs_on.is_a?(Array) && p.runs_on.length > 1
            end
          end

          def service(name:, port:)
            {
              apiVersion: "v1",
              kind: "Service",
              metadata: { name:, namespace: NAMESPACE, labels: labels(name) },
              spec: {
                selector: { Naming::LABEL_APP => name },
                ports: [ { port:, targetPort: port } ]
              }
            }
          end

          def headless_service(name:, port:)
            {
              apiVersion: "v1",
              kind: "Service",
              metadata: { name:, namespace: NAMESPACE, labels: labels(name) },
              spec: {
                clusterIP: "None",
                selector: { Naming::LABEL_APP => name },
                ports: [ { port:, targetPort: port } ]
              }
            }
          end

          def statefulset(name:, containers:, volumes: [], node_selector: nil)
            spec = { containers: }
            spec[:volumes] = volumes if volumes.any?
            spec[:nodeSelector] = node_selector if node_selector

            {
              apiVersion: "apps/v1",
              kind: "StatefulSet",
              metadata: { name:, namespace: NAMESPACE, labels: labels(name) },
              spec: {
                serviceName: name,
                replicas: 1,
                selector: { matchLabels: { Naming::LABEL_APP => name } },
                template: { metadata: { labels: labels(name) }, spec: }
              }
            }
          end

          def secret(name:, data:)
            {
              apiVersion: "v1",
              kind: "Secret",
              metadata: { name:, namespace: NAMESPACE },
              type: "Opaque",
              data: data.transform_values { |v| Base64.strict_encode64(v.to_s) }
            }
          end

          def ingress(name:, hostname:, port:)
            {
              apiVersion: "networking.k8s.io/v1",
              kind: "Ingress",
              metadata: {
                name:,
                namespace: NAMESPACE,
                annotations: { "nginx.ingress.kubernetes.io/proxy-body-size" => "50m" }
              },
              spec: {
                ingressClassName: "nginx",
                rules: [
                  {
                    host: hostname,
                    http: {
                      paths: [
                        {
                          path: "/",
                          pathType: "Prefix",
                          backend: { service: { name:, port: { number: port } } }
                        }
                      ]
                    }
                  }
                ]
              }
            }
          end

          def host_path_volume(name, path)
            { name:, hostPath: { path:, type: "DirectoryOrCreate" } }
          end

          def node_selector_for(runs_on)
            return nil unless runs_on

            { Naming::LABEL_SERVER_GROUP => runs_on.to_s }
          end

          def node_selector_for_process(runs_on)
            return nil unless runs_on

            if runs_on.is_a?(Array) && runs_on.length > 1
              :affinity
            elsif runs_on.is_a?(Array)
              { Naming::LABEL_SERVER_GROUP => runs_on.first.to_s }
            else
              { Naming::LABEL_SERVER_GROUP => runs_on.to_s }
            end
          end
      end
    end
  end
end
