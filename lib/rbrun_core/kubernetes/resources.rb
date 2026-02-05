# frozen_string_literal: true

module RbrunCore
  module Kubernetes
    module Resources
      PRIORITIES = {
        database: 1_000_000_000,
        platform: 100_000,
        app: 1_000
      }.freeze

      PROFILES = {
        database: {
          requests: { memory: "512Mi", cpu: "250m" },
          limits: { memory: "1536Mi" }
        },
        platform: {
          requests: { memory: "64Mi", cpu: "50m" },
          limits: { memory: "256Mi" }
        },
        small: {
          requests: { memory: "512Mi", cpu: "100m" },
          limits: { memory: "1536Mi" }
        },
        medium: {
          requests: { memory: "768Mi", cpu: "200m" },
          limits: { memory: "2Gi" }
        },
        large: {
          requests: { memory: "1Gi", cpu: "300m" },
          limits: { memory: "3Gi" }
        }
      }.freeze

      DEFAULT_APP_SIZE = :small

      class << self
        def priority_class_manifests
          [
            priority_class("database-critical", PRIORITIES[:database], "Database workloads - never evict"),
            priority_class("platform", PRIORITIES[:platform], "Platform services - evict after apps"),
            priority_class("app", PRIORITIES[:app], "Application workloads - evict first", global_default: true)
          ]
        end

        def priority_class_yaml
          priority_class_manifests.map { |m| YAML.dump(deep_stringify_keys(m)) }.join("\n---\n")
        end

        def for(type)
          profile = PROFILES[type] || PROFILES[DEFAULT_APP_SIZE]
          deep_copy(profile)
        end

        def priority_class_for(type)
          case type
          when :database then "database-critical"
          when :platform then "platform"
          else "app"
          end
        end

        def auto_size_for_node(node_memory_bytes)
          node_gi = node_memory_bytes / (1024**3)
          return PROFILES.dup if node_gi <= 8

          profiles = deep_copy(PROFILES)
          if node_gi >= 16
            profiles[:database][:limits][:memory] = "2Gi"
            profiles[:large][:limits][:memory] = "2Gi"
          end
          profiles
        end

        private

          def priority_class(name, value, description, global_default: false)
            {
              apiVersion: "scheduling.k8s.io/v1",
              kind: "PriorityClass",
              metadata: { name: },
              value:,
              globalDefault: global_default,
              preemptionPolicy: "PreemptLowerPriority",
              description:
            }
          end

          def deep_copy(hash)
            Marshal.load(Marshal.dump(hash))
          end

          def deep_stringify_keys(obj)
            case obj
            when Hash
              obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify_keys(v) }
            when Array
              obj.map { |v| deep_stringify_keys(v) }
            else
              obj
            end
          end
      end
    end
  end
end
