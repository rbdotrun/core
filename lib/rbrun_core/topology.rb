# frozen_string_literal: true

module RbrunCore
  class Topology
    def initialize(ctx)
      @ctx = ctx
      @kubectl = Clients::Kubectl.new(ctx.ssh_client)
    end

    def nodes
      data = @kubectl.get("nodes")
      return [] unless data

      data["items"].map do |node|
        {
          name: node["metadata"]["name"],
          labels: node["metadata"]["labels"] || {},
          ready: node_ready?(node),
          roles: extract_roles(node)
        }
      end
    end

    def pods(namespace: "default")
      data = @kubectl.get("pods", namespace:)
      return [] unless data

      data["items"].map do |pod|
        {
          name: pod["metadata"]["name"],
          node: pod["spec"]["nodeName"],
          app: pod["metadata"]["labels"]&.dig(Naming::LABEL_APP),
          phase: pod["status"]["phase"],
          ready: pod_ready?(pod)
        }
      end
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

    # Validates expected placement
    # expected: { "web" => ["app"], "worker" => ["worker"], "postgres" => ["db"] }
    def validate_placement!(expected, namespace: "default")
      current_pods = pods(namespace:)
      errors = []

      expected.each do |app_suffix, allowed_groups|
        app_pods = current_pods.select { |p| p[:app]&.end_with?("-#{app_suffix}") }

        app_pods.each do |pod|
          node_name = pod[:node]
          next unless node_name

          # Extract group from node name (e.g., "prefix-app-1" => "app")
          group = node_name.match(/-(\w+)-\d+$/)&.[](1)

          unless allowed_groups.include?(group)
            errors << "Pod #{pod[:name]} on node #{node_name} (group: #{group}), expected: #{allowed_groups.join(', ')}"
          end
        end
      end

      raise Error, "Placement validation failed:\n#{errors.join("\n")}" unless errors.empty?
    end

    # Validates replica counts
    # expected: { "web" => 2, "worker" => 2, "postgres" => 1 }
    def validate_replicas!(expected, namespace: "default")
      current_pods = pods(namespace:)
      errors = []

      expected.each do |app_suffix, count|
        matching = current_pods.count { |p| p[:app]&.end_with?("-#{app_suffix}") && p[:ready] }

        if matching != count
          errors << "#{app_suffix}: expected #{count} ready pods, got #{matching}"
        end
      end

      raise Error, "Replica validation failed:\n#{errors.join("\n")}" unless errors.empty?
    end

    private

      def node_ready?(node)
        node.dig("status", "conditions")&.any? { |c| c["type"] == "Ready" && c["status"] == "True" }
      end

      def pod_ready?(pod)
        pod["status"]["phase"] == "Running" &&
          pod.dig("status", "containerStatuses")&.all? { |c| c["ready"] }
      end

      def extract_roles(node)
        (node.dig("metadata", "labels") || {})
          .select { |k, _| k.start_with?("node-role.kubernetes.io/") }
          .keys
          .map { |k| k.sub("node-role.kubernetes.io/", "") }
      end

      def build_placement(namespace:)
        pods_list = pods(namespace:)
        nodes_list = nodes

        nodes_list.each_with_object({}) do |node, hash|
          hash[node[:name]] = pods_list
            .select { |p| p[:node] == node[:name] }
            .map { |p| { name: p[:name], app: p[:app], ready: p[:ready] } }
        end
      end
  end
end
