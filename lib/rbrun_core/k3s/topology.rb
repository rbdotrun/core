# frozen_string_literal: true

module RbrunCore
  module K3s
    class Topology
      def initialize(ctx)
        @ctx = ctx
        @kubectl = Clients::Kubectl.new(ctx.ssh_client)
      end

      def nodes
        data = @kubectl.get("nodes")
        return [] unless data

        data["items"].map { |node| build_node_info(node) }
      end

      def pods(namespace: "default")
        data = @kubectl.get("pods", namespace:)
        return [] unless data

        data["items"].map { |pod| build_pod_info(pod) }
      end

      def topology_hash(namespace: "default")
        {
          nodes:,
          pods: pods(namespace:),
          placement: build_placement(namespace:)
        }
      end

      def to_json(namespace: "default")
        JSON.pretty_generate(topology_hash(namespace:))
      end

      def validate_placement!(expected, namespace: "default")
        current_pods = pods(namespace:)
        errors = collect_placement_errors(expected, current_pods)

        raise Error, "Placement validation failed:\n#{errors.join("\n")}" unless errors.empty?
      end

      def validate_replicas!(expected, namespace: "default")
        current_pods = pods(namespace:)
        errors = collect_replica_errors(expected, current_pods)

        raise Error, "Replica validation failed:\n#{errors.join("\n")}" unless errors.empty?
      end

      private

        def build_node_info(node)
          {
            name: node.dig("metadata", "name"),
            labels: node.dig("metadata", "labels") || {},
            ready: node_ready?(node),
            roles: extract_roles(node)
          }
        end

        def build_pod_info(pod)
          {
            name: pod.dig("metadata", "name"),
            node: pod.dig("spec", "nodeName"),
            app: pod.dig("metadata", "labels", Naming::LABEL_APP),
            phase: pod.dig("status", "phase"),
            ready: pod_ready?(pod)
          }
        end

        def node_ready?(node)
          conditions = node.dig("status", "conditions") || []
          conditions.any? { |c| c["type"] == "Ready" && c["status"] == "True" }
        end

        def pod_ready?(pod)
          return false unless pod.dig("status", "phase") == "Running"

          container_statuses = pod.dig("status", "containerStatuses") || []
          container_statuses.all? { |c| c["ready"] }
        end

        def extract_roles(node)
          labels = node.dig("metadata", "labels") || {}
          role_labels = labels.keys.select { |k| k.start_with?("node-role.kubernetes.io/") }
          role_labels.map { |k| k.delete_prefix("node-role.kubernetes.io/") }
        end

        def build_placement(namespace:)
          pods_list = pods(namespace:)
          nodes_list = nodes

          nodes_list.each_with_object({}) do |node, hash|
            hash[node[:name]] = pods_on_node(pods_list, node[:name])
          end
        end

        def pods_on_node(pods_list, node_name)
          pods_list
            .select { |p| p[:node] == node_name }
            .map { |p| { name: p[:name], app: p[:app], ready: p[:ready] } }
        end

        def collect_placement_errors(expected, current_pods)
          errors = []

          expected.each do |app_suffix, allowed_groups|
            app_pods = pods_for_app(current_pods, app_suffix)
            errors.concat(placement_errors_for_pods(app_pods, allowed_groups))
          end

          errors
        end

        def pods_for_app(pods_list, app_suffix)
          pods_list.select { |p| p[:app]&.end_with?("-#{app_suffix}") }
        end

        def placement_errors_for_pods(app_pods, allowed_groups)
          app_pods.filter_map do |pod|
            placement_error_for_pod(pod, allowed_groups)
          end
        end

        def placement_error_for_pod(pod, allowed_groups)
          node_name = pod[:node]
          return nil unless node_name

          group = extract_node_group(node_name)
          return nil if allowed_groups.include?(group)

          "Pod #{pod[:name]} on node #{node_name} (group: #{group}), expected: #{allowed_groups.join(', ')}"
        end

        def extract_node_group(node_name)
          match = node_name.match(/-(\w+)-\d+$/)
          match&.[](1)
        end

        def collect_replica_errors(expected, current_pods)
          expected.filter_map do |app_suffix, count|
            replica_error_for_app(current_pods, app_suffix, count)
          end
        end

        def replica_error_for_app(pods_list, app_suffix, expected_count)
          actual_count = pods_list.count { |p| p[:app]&.end_with?("-#{app_suffix}") && p[:ready] }
          return nil if actual_count == expected_count

          "#{app_suffix}: expected #{expected_count} ready pods, got #{actual_count}"
        end
    end
  end
end
