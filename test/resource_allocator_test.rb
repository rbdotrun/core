# frozen_string_literal: true

require "test_helper"

class ResourceAllocatorTest < Minitest::Test
  def test_allocates_memory_proportionally
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "postgres", profile: :large, replicas: 1),
      RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 2),
      RbrunCore::ResourceAllocator::Workload.new(name: "worker", profile: :small, replicas: 1)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      server_memory_mb: 4096,
      workloads:
    )

    result = allocator.allocate

    assert_equal 3, result.size
    assert_operator result["postgres"].memory_mb, :>, result["web"].memory_mb
    assert_operator result["web"].memory_mb, :>, result["worker"].memory_mb
  end

  def test_accounts_for_replicas_in_total_weight
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 1)
    ]

    single_replica = RbrunCore::ResourceAllocator.new(
      server_memory_mb: 4096,
      workloads:
    ).allocate

    workloads_double = [
      RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 2)
    ]

    double_replica = RbrunCore::ResourceAllocator.new(
      server_memory_mb: 4096,
      workloads: workloads_double
    ).allocate

    assert_equal single_replica["web"].memory_mb / 2, double_replica["web"].memory_mb
  end

  def test_reserves_system_memory
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "app", profile: :large, replicas: 1)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      server_memory_mb: 4096,
      workloads:
    )

    result = allocator.allocate

    assert_operator result["app"].memory_mb, :<, 4096
    assert_equal 4096 - 512, result["app"].memory_mb
  end

  def test_allocation_to_kubernetes_format
    workloads = [
      RbrunCore::ResourceAllocator::Workload.new(name: "app", profile: :medium, replicas: 1)
    ]

    allocator = RbrunCore::ResourceAllocator.new(
      server_memory_mb: 2048,
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

  def test_realistic_staging_allocation_system_components
    result = realistic_staging_allocations

    assert_equal 179, result["registry"].memory_mb
    assert_equal 179, result["tunnel"].memory_mb
  end

  def test_realistic_staging_allocation_app_components
    result = realistic_staging_allocations

    assert_equal 1433, result["postgres"].memory_mb
    assert_equal 716, result["web"].memory_mb
    assert_equal 358, result["worker"].memory_mb
  end

  private

    def realistic_staging_allocations
      workloads = [
        RbrunCore::ResourceAllocator::Workload.new(name: "registry", profile: :minimal, replicas: 1),
        RbrunCore::ResourceAllocator::Workload.new(name: "tunnel", profile: :minimal, replicas: 1),
        RbrunCore::ResourceAllocator::Workload.new(name: "postgres", profile: :large, replicas: 1),
        RbrunCore::ResourceAllocator::Workload.new(name: "web", profile: :medium, replicas: 2),
        RbrunCore::ResourceAllocator::Workload.new(name: "worker", profile: :small, replicas: 1)
      ]

      RbrunCore::ResourceAllocator.new(
        server_memory_mb: 4096,
        workloads:
      ).allocate
    end
end
