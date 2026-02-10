# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
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
                         init_containers: [], anti_affinity: false)
            spec = build_deployment_pod_spec(containers, init_containers, volumes, host_network, node_selector,
                                             anti_affinity:)

            # Dedicated nodes (anti_affinity set): use Recreate because pods can't spill to other
            # nodes during rolling update, causing "Insufficient memory" when resource allocations change.
            # Shared nodes (no anti_affinity): use RollingUpdate for zero-downtime deploys.
            strategy = anti_affinity ? { type: "Recreate" } : { type: "RollingUpdate" }

            {
              apiVersion: "apps/v1",
              kind: "Deployment",
              metadata: { name:, namespace: NAMESPACE, labels: labels(name) },
              spec: {
                replicas:,
                strategy:,
                selector: { matchLabels: { Naming::LABEL_APP => name } },
                template: { metadata: { labels: labels(name) }, spec: }
              }
            }
          end

          def build_deployment_pod_spec(containers, init_containers, volumes, host_network, node_selector,
                                         anti_affinity: false)
            spec = { containers: }
            spec[:initContainers] = init_containers if init_containers.any?
            spec[:volumes] = volumes if volumes.any?
            spec[:hostNetwork] = true if host_network
            spec[:nodeSelector] = node_selector if node_selector
            spec[:affinity] = build_pod_anti_affinity(node_selector) if anti_affinity && node_selector

            spec
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

          def node_selector_for_instance_type(workload)
            return nil unless workload.instance_type

            { Naming::LABEL_SERVER_GROUP => workload.name.to_s }
          end

          def build_pod_anti_affinity(node_selector)
            process_name = node_selector[Naming::LABEL_SERVER_GROUP]
            {
              podAntiAffinity: {
                requiredDuringSchedulingIgnoredDuringExecution: [
                  {
                    labelSelector: {
                      matchExpressions: [
                        {
                          key: Naming::LABEL_APP,
                          operator: "NotIn",
                          values: [ process_name ]
                        }
                      ]
                    },
                    topologyKey: "kubernetes.io/hostname"
                  }
                ]
              }
            }
          end
      end
    end
  end
end
