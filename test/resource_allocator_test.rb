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

  def test_profile_for_process_with_explicit_resources_uses_override
    process = RbrunCore::Config::Process.new(:worker)
    process.resources = :large

    profile = RbrunCore::ResourceAllocator.profile_for_process(process)

    assert_equal :large, profile
  end

  def test_single_node_allocation_system_components
    result = single_node_allocations

    # Capped at minimal profile max (256)
    assert_equal 179, result["registry"].memory_mb
    assert_equal 179, result["tunnel"].memory_mb
  end

  def test_single_node_allocation_app_components
    result = single_node_allocations

    # Now capped at profile maximums
    assert_equal 1433, result["postgres"].memory_mb  # under large cap (2048)
    assert_equal 716, result["web"].memory_mb        # under medium cap (1024)
    assert_equal 358, result["worker"].memory_mb     # under small cap (512)
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

    # Master group: no headroom reserved, but capped at profile max
    # postgres: large profile, capped at 2048
    assert_equal 2048, result["postgres"].memory_mb

    # Worker group: dedicated node, 25% headroom reserved
    # 8192 - 512 = 7680 available, * 0.75 = 5760 allocatable
    # web (medium, 2 replicas) + worker (small, 1 replica) = weight 10
    # web gets 4/10 * 5760 = 2304, but capped at 1024 (medium)
    assert_equal 1024, result["web"].memory_mb
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

    # 4096 - 512 system = 3584 available
    # With 25% headroom: 3584 * 0.75 = 2688 allocatable
    # But capped at 1024 per medium profile
    assert_equal 1024, result["web"].memory_mb
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

    # Capped at 512 for small profile
    assert_equal 512, result["worker"].memory_mb
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

    # Web and worker on dedicated nodes have headroom and profile caps
    assert_equal 1024, result["web"].memory_mb    # medium cap
    assert_equal 512, result["worker"].memory_mb  # small cap
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
