# frozen_string_literal: true

module RbrunCore
  class ResourceAllocator
    SYSTEM_RESERVE_MB = 512
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
        needs_headroom = dedicated_node_group?(group)
        allocations.merge!(allocate_group(group_workloads, group_memory, reserve_headroom: needs_headroom))
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

      def allocate_group(workloads, server_memory_mb, reserve_headroom: false)
        available = server_memory_mb - SYSTEM_RESERVE_MB
        available = (available * (1 - ROLLING_UPDATE_HEADROOM)).floor if reserve_headroom
        total_weight = calculate_total_weight(workloads)

        workloads.each_with_object({}) do |workload, result|
          weight = PROFILE_WEIGHTS.fetch(workload.profile)
          memory_per_replica = (weight.to_f / total_weight * available).floor
          capped_memory = apply_profile_cap(memory_per_replica, workload.profile)
          result[workload.name] = Allocation.new(capped_memory)
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
