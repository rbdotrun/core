# frozen_string_literal: true

module RbrunCore
  class ResourceAllocator
    SYSTEM_RESERVE_MB = 512

    PROFILE_WEIGHTS = {
      minimal: 1,
      small: 2,
      medium: 4,
      large: 8
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
        allocations.merge!(allocate_group(group_workloads, group_memory))
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

      def allocate_group(workloads, server_memory_mb)
        available = server_memory_mb - SYSTEM_RESERVE_MB
        total_weight = calculate_total_weight(workloads)

        workloads.each_with_object({}) do |workload, result|
          weight = PROFILE_WEIGHTS.fetch(workload.profile)
          memory_per_replica = (weight.to_f / total_weight * available).floor
          result[workload.name] = Allocation.new(memory_per_replica)
        end
      end

      def calculate_total_weight(workloads)
        workloads.sum do |workload|
          PROFILE_WEIGHTS.fetch(workload.profile) * workload.replicas
        end
      end
  end
end
