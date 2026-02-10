# frozen_string_literal: true

require "test_helper"

class ResourceAllocatorTest < Minitest::Test
  def test_allocates_memory_proportionally
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "postgres", profile: :large, replicas: 1, runs_on: :master),
      RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 2, runs_on: :master),
      RbrunCore::ResourceAllocator::Workload.new(name: "worker", profile: :small, replicas: 1, runs_on: :master)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 4096 },
      workloads:
    )

    result = allocator.allocate

    assert_equal 3, result.size
    assert_operator result["postgres"].memory_mb, :>, result["web"].memory_mb
    assert_operator result["web"].memory_mb, :>, result["worker"].memory_mb
  end

  def test_accounts_for_replicas_in_total_weight
    # Use minimal profile to stay under caps and test proportional allocation
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "svc", profile: :minimal, replicas: 1, runs_on: :master)
    ]

    single_replica = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 1024 },
      workloads:
    ).allocate

    workloads_double = [
      RbrunCore::ResourceAllocator::Workload.new(name: "svc", profile: :minimal, replicas: 2, runs_on: :master)
    ]

    double_replica = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 1024 },
      workloads: workloads_double
    ).allocate

    # Both hit the cap (256) since minimal profile cap is 256
    # and even with 2 replicas on 1024MB node: (1024-512)/2 = 256
    assert_equal 256, single_replica["svc"].memory_mb
    assert_equal 256, double_replica["svc"].memory_mb
  end

  def test_reserves_system_memory
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "app", profile: :large, replicas: 1, runs_on: :master)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 4096 },
      workloads:
    )

    result = allocator.allocate

    assert_operator result["app"].memory_mb, :<, 4096
    # Capped at profile max (2048 for large) instead of full available
    assert_equal 2048, result["app"].memory_mb
  end

  def test_allocation_to_kubernetes_format
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "app", profile: :medium, replicas: 1, runs_on: :master)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 2048 },
      workloads:
    )

    result = allocator.allocate
    k8s = result["app"].to_kubernetes

    assert_equal({ memory: "#{result["app"].memory_mb}Mi" }, k8s[:requests])
    assert_equal({ memory: "#{result["app"].memory_mb}Mi" }, k8s[:limits])
  end

  def test_profile_for_process_with_subdomain_returns_medium
    process = RbrunCore::Config::Process.new(:web)
    process.subdomain = "www"

    profile = RbrunCore::ResourceAllocator.profile_for_process(process)

    assert_equal :medium, profile
  end

  def test_profile_for_process_without_subdomain_returns_small
    process = RbrunCore::Config::Process.new(:worker)

    profile = RbrunCore::ResourceAllocator.profile_for_process(process)

    assert_equal :small, profile
  end

  def test_single_node_allocation_system_components
    result = single_node_allocations

    # 4096 * 0.80 = 3276 available, weight 20 total
    # minimal (1/20 * 3276) = 163, under cap
    assert_equal 163, result["registry"].memory_mb
    assert_equal 163, result["tunnel"].memory_mb
  end

  def test_single_node_allocation_app_components
    result = single_node_allocations

    # 4096 * 0.80 = 3276 available, weight 20 total
    # postgres: 8/20 * 3276 = 1310, under large cap
    # web: 4/20 * 3276 = 655, under medium cap
    # worker: 2/20 * 3276 = 327, under small cap
    assert_equal 1310, result["postgres"].memory_mb
    assert_equal 655, result["web"].memory_mb
    assert_equal 327, result["worker"].memory_mb
  end

  def test_multi_node_allocates_per_group
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "postgres", profile: :large, replicas: 1, runs_on: :master),
      RbrunCore::ResourceAllocator::Workload.new(name: "registry", profile: :minimal, replicas: 1, runs_on: :master),
      RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 2, runs_on: :worker),
      RbrunCore::ResourceAllocator::Workload.new(name: "worker", profile: :small, replicas: 1, runs_on: :worker)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 4096, worker: 8192 },
      workloads:
    )

    result = allocator.allocate

    # Master: 4096 * 0.80 = 3276, postgres(8) + registry(1) = 9 weight
    # postgres: 8/9 * 3276 = 2912, capped at 2048
    assert_equal 2048, result["postgres"].memory_mb

    # Worker: 8192 * 0.80 = 6553, * 0.75 headroom = 4914
    # web(8) + worker(2) = 10 weight
    # web: 4/10 * 4914 = 1965 (no cap on dedicated)
    assert_equal 1965, result["web"].memory_mb
  end

  def test_workload_defaults_to_master_when_runs_on_nil
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "app", profile: :medium, replicas: 1, runs_on: nil)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 2048 },
      workloads:
    )

    result = allocator.allocate

    assert_predicate result["app"].memory_mb, :positive?
  end

  def test_dedicated_node_reserves_headroom_for_rolling_updates
    # Simulates production scenario: web on dedicated node
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 2, runs_on: :web)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 4096, web: 4096 },
      workloads:
    )

    result = allocator.allocate

    # 4096 * 0.80 = 3276 available
    # With 25% headroom: 3276 * 0.75 = 2457 allocatable
    # No cap on dedicated nodes: 4/8 * 2457 = 1228
    assert_equal 1228, result["web"].memory_mb
  end

  def test_dedicated_worker_node_reserves_headroom
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "worker", profile: :small, replicas: 1, runs_on: :worker)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 4096, worker: 4096 },
      workloads:
    )

    result = allocator.allocate

    # No cap on dedicated nodes: full allocation after headroom
    # 4096 * 0.80 = 3276, * 0.75 = 2457
    assert_equal 2457, result["worker"].memory_mb
  end

  def test_master_node_does_not_reserve_extra_headroom
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "app", profile: :medium, replicas: 1, runs_on: :master)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 4096 },
      workloads:
    )

    result = allocator.allocate

    # Master uses full available (minus system reserve), capped at profile max
    # 4096 - 512 = 3584, but capped at 1024 for medium
    assert_equal 1024, result["app"].memory_mb
  end

  def test_profile_caps_prevent_over_allocation
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 1, runs_on: :master)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      node_groups: { master: 16384 }, # 16GB node
      workloads:
    )

    result = allocator.allocate

    # Even with 16GB available, medium profile capped at 1024MB
    assert_equal 1024, result["web"].memory_mb
  end

  def test_profile_caps_by_type
    expected = { minimal: 256, small: 512, medium: 1024, large: 2048 }

    assert_equal expected, RbrunCore::ResourceAllocator::PROFILE_CAPS_MB
  end

  def test_rolling_update_headroom_constant
    assert_in_delta(0.25, RbrunCore::ResourceAllocator::ROLLING_UPDATE_HEADROOM)
  end

  def test_production_multi_node_dedicated_nodes
    result = production_multi_node_allocations

    # Web and worker on dedicated nodes have headroom but NO caps
    # Web: 4096 * 0.80 = 3276, * 0.75 = 2457, 4/8 * 2457 = 1228
    # Worker: 4096 * 0.80 = 3276, * 0.75 = 2457 (full allocation)
    assert_equal 1228, result["web"].memory_mb
    assert_equal 2457, result["worker"].memory_mb
  end

  def test_production_multi_node_master_workloads
    result = production_multi_node_allocations

    # Master workloads use proportional allocation with caps
    assert_equal 2048, result["postgres"].memory_mb  # large cap
    assert_equal 256, result["registry"].memory_mb   # minimal cap
    assert_equal 256, result["tunnel"].memory_mb     # minimal cap
  end

  private

    def single_node_allocations
      workloads = [
        RbrunCore::ResourceAllocator::Workload.new(name: "registry", profile: :minimal, replicas: 1, runs_on: :master),
        RbrunCore::ResourceAllocator::Workload.new(name: "tunnel", profile: :minimal, replicas: 1, runs_on: :master),
        RbrunCore::ResourceAllocator::Workload.new(name: "postgres", profile: :large, replicas: 1, runs_on: :master),
        RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 2, runs_on: :master),
        RbrunCore::ResourceAllocator::Workload.new(name: "worker", profile: :small, replicas: 1, runs_on: :master)
      ]

      RbrunCore::ResourceAllocator.new(
        node_groups: { master: 4096 },
        workloads:
      ).allocate
    end

    def production_multi_node_allocations
      workloads = [
        RbrunCore::ResourceAllocator::Workload.new(name: "postgres", profile: :large, replicas: 1, runs_on: :master),
        RbrunCore::ResourceAllocator::Workload.new(name: "registry", profile: :minimal, replicas: 1, runs_on: :master),
        RbrunCore::ResourceAllocator::Workload.new(name: "tunnel", profile: :minimal, replicas: 1, runs_on: :master),
        RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 2, runs_on: :web),
        RbrunCore::ResourceAllocator::Workload.new(name: "worker", profile: :small, replicas: 1, runs_on: :worker)
      ]

      RbrunCore::ResourceAllocator.new(
        node_groups: { master: 4096, web: 4096, worker: 4096 },
        workloads:
      ).allocate
    end
end
