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

    DEFAULT_PROFILES = {
      database: :large,
      registry: :minimal,
      tunnel: :minimal
    }.freeze

    Workload = Struct.new(:name, :profile, :replicas, keyword_init: true)

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

    def initialize(server_memory_mb:, workloads:)
      @server_memory_mb = server_memory_mb
      @workloads = workloads
    end

    def allocate
      available = @server_memory_mb - SYSTEM_RESERVE_MB
      total_weight = calculate_total_weight

      @workloads.each_with_object({}) do |workload, result|
        weight = PROFILE_WEIGHTS.fetch(workload.profile)
        memory_per_replica = (weight.to_f / total_weight * available).floor
        result[workload.name] = Allocation.new(memory_per_replica)
      end
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

      def calculate_total_weight
        @workloads.sum do |workload|
          PROFILE_WEIGHTS.fetch(workload.profile) * workload.replicas
        end
      end
  end
end
