# frozen_string_literal: true

module RbrunCore
  # ResourceAllocator: Proportional memory allocation for Kubernetes workloads
  #
  # == Formula
  #
  #   For shared nodes (master):
  #     available = node_memory × 0.80
  #     per_pod = available × (weight / total_weight)
  #     final = min(per_pod, profile_cap)
  #
  #   For dedicated nodes (runs_on specified):
  #     available = node_memory × 0.80
  #     allocatable = available × 0.75  (headroom for rolling updates)
  #     per_pod = allocatable × (weight / total_weight)
  #     final = per_pod  (no cap)
  #
  # == Inputs
  #
  #   - node_memory: Total RAM of the server (e.g., 16384 MB for 16GB)
  #   - profile: :minimal, :small, :medium, :large (determines weight)
  #   - replicas: Number of pod replicas (affects total_weight)
  #   - runs_on: Node group (:master for shared, :web/:worker for dedicated)
  #
  # == Example (16GB dedicated web node, 2 replicas)
  #
  #   available   = 16384 × 0.80 = 13107 MB
  #   allocatable = 13107 × 0.75 = 9830 MB
  #   weight      = 4 (medium), total_weight = 4 × 2 = 8
  #   per_pod     = 9830 × (4 / 8) = 4915 MB (~4.8 GB each)
  #
  class ResourceAllocator
    SYSTEM_RESERVE_PERCENT = 0.20 # Always leave 20% for OS/k3s/kubelet
    ROLLING_UPDATE_HEADROOM = 0.25 # Reserve 25% for rolling update surge

    PROFILE_WEIGHTS = {
      minimal: 1,
      small: 2,
      medium: 4,
      large: 8
    }.freeze

    # Maximum memory per profile to prevent over-allocation
    PROFILE_CAPS_MB = {
      minimal: 256,
      small: 512,
      medium: 1024,
      large: 2048
    }.freeze

    MASTER_GROUP = :master

    Workload = Struct.new(:name, :profile, :replicas, :runs_on, keyword_init: true) do
      def target_group
        runs_on || MASTER_GROUP
      end
    end

    class Allocation
      attr_reader :memory_mb

      def initialize(memory_mb)
        @memory_mb = memory_mb
      end

      def to_kubernetes
        {
          requests: { memory: "#{memory_mb}Mi" },
          limits: { memory: "#{memory_mb}Mi" }
        }
      end
    end

    # node_groups: { master: 4096, worker: 8192 } (memory in MB)
    # workloads: array of Workload structs with runs_on
    def initialize(node_groups:, workloads:)
      @node_groups = node_groups
      @workloads = workloads
    end

    def allocate
      allocations = {}

      workloads_by_group.each do |group, group_workloads|
        group_memory = @node_groups[group] || @node_groups[MASTER_GROUP]
        dedicated = dedicated_node_group?(group)
        allocations.merge!(allocate_group(group_workloads, group_memory, reserve_headroom: dedicated, dedicated:))
      end

      allocations
    end

    def self.profile_for_process(process)
      if process.respond_to?(:resources) && process.resources
        process.resources.to_sym
      elsif process.subdomain && !process.subdomain.to_s.empty?
        :medium
      else
        :small
      end
    end

    def self.profile_for_service(_service)
      :small
    end

    private

      def workloads_by_group
        @workloads.group_by(&:target_group)
      end

      # Dedicated node groups (non-master) need headroom for rolling updates
      # since workloads can't spill over to other nodes
      def dedicated_node_group?(group)
        group != MASTER_GROUP && @node_groups.key?(group)
      end

      def allocate_group(workloads, server_memory_mb, reserve_headroom: false, dedicated: false)
        available = (server_memory_mb * (1 - SYSTEM_RESERVE_PERCENT)).floor
        available = (available * (1 - ROLLING_UPDATE_HEADROOM)).floor if reserve_headroom
        total_weight = calculate_total_weight(workloads)

        workloads.each_with_object({}) do |workload, result|
          weight = PROFILE_WEIGHTS.fetch(workload.profile)
          memory_per_replica = (weight.to_f / total_weight * available).floor
          # Only apply caps on shared nodes (master) - dedicated nodes use full allocation
          final_memory = dedicated ? memory_per_replica : apply_profile_cap(memory_per_replica, workload.profile)
          result[workload.name] = Allocation.new(final_memory)
        end
      end

      def apply_profile_cap(memory_mb, profile)
        cap = PROFILE_CAPS_MB.fetch(profile)
        [ memory_mb, cap ].min
      end

      def calculate_total_weight(workloads)
        workloads.sum do |workload|
          PROFILE_WEIGHTS.fetch(workload.profile) * workload.replicas
        end
      end
  end
end
