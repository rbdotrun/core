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

          # ─────────────────────────────────────────────────────────────────────────────
          # ROLLING UPDATE STRATEGY
          # ─────────────────────────────────────────────────────────────────────────────
          #
          # All deployments use RollingUpdate with default surge settings. This enables
          # zero-downtime deploys:
          #
          #   1. New pod starts alongside old pod (surge)
          #   2. New pod becomes Ready (passes readiness probe)
          #   3. Old pod terminates gracefully
          #   4. Repeat for remaining replicas
          #
          # This works even on dedicated nodes because we use SOFT anti-affinity
          # (preferredDuringScheduling), which allows temporary co-location during
          # updates. See build_pod_anti_affinity for details.
          #
          # ─────────────────────────────────────────────────────────────────────────────
          def deployment(name:, containers:, volumes: [], replicas: 1, host_network: false, node_selector: nil,
                         init_containers: [], anti_affinity: false)
            spec = build_deployment_pod_spec(containers, init_containers, volumes, host_network, node_selector,
                                             anti_affinity:)

            strategy = { type: "RollingUpdate" }

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

          # NODE SELECTOR: Hard constraint that pins pods to labeled nodes.
          # Workloads with instance_type get dedicated servers labeled with their name.
          # This provides HARD isolation between different processes (web vs worker).
          def node_selector_for_instance_type(workload)
            return nil unless workload.instance_type

            { Naming::LABEL_SERVER_GROUP => workload.name.to_s }
          end

          # ─────────────────────────────────────────────────────────────────────────────
          # SOFT ANTI-AFFINITY FOR DEDICATED NODES
          # ─────────────────────────────────────────────────────────────────────────────
          #
          # Pods with instance_type get SOFT anti-affinity (preferredDuringScheduling).
          # This provides two benefits:
          #
          # 1. CRASH ISOLATION (normal operation):
          #    Scheduler spreads pods across nodes. If web-1 node dies, web-2 keeps
          #    serving traffic. Weight 100 = strongest preference.
          #
          # 2. ZERO-DOWNTIME DEPLOYS (rolling updates):
          #    During updates, new pod can temporarily co-locate with old pod on same
          #    node. Once new pod is Ready, old pod terminates. This allows surge
          #    without requiring extra node capacity.
          #
          #    Timeline:
          #      web-1: [old-pod] + [new-pod starting]  ← temporary co-location OK
          #      web-2: [old-pod serving traffic]
          #             ↓
          #      web-1: [new-pod Ready, old-pod terminating]
          #      web-2: [old-pod serving traffic]
          #             ↓
          #      web-1: [new-pod serving]
          #      web-2: [new-pod starting alongside old-pod]
          #             ... repeat
          #
          # Why not HARD anti-affinity (requiredDuringScheduling)?
          #   - Would block surge: new pod can't schedule if old pod still running
          #   - Would require maxSurge: 0 (kill first, then start)
          #   - Risk: if new pod fails to start, gap in service
          #
          # NODE ISOLATION between different processes (web vs worker) is enforced by
          # nodeSelector, not anti-affinity. Anti-affinity only affects pods of the
          # SAME deployment.
          #
          # ─────────────────────────────────────────────────────────────────────────────
          def build_pod_anti_affinity(node_selector)
            process_name = node_selector[Naming::LABEL_SERVER_GROUP]
            {
              podAntiAffinity: {
                preferredDuringSchedulingIgnoredDuringExecution: [
                  {
                    weight: 100,
                    podAffinityTerm: {
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
                  }
                ]
              }
            }
          end
      end
    end
  end
end
