# frozen_string_literal: true

require "test_helper"

class InstanceTypesTest < Minitest::Test
  def test_hetzner_cx23_returns_4gb
    memory = RbrunCore::InstanceTypes.memory_mb(:hetzner, "cx23")

    assert_equal 4096, memory
  end

  def test_hetzner_cpx11_returns_2gb
    memory = RbrunCore::InstanceTypes.memory_mb(:hetzner, "cpx11")

    assert_equal 2048, memory
  end

  def test_hetzner_cpx31_returns_8gb
    memory = RbrunCore::InstanceTypes.memory_mb(:hetzner, "cpx31")

    assert_equal 8192, memory
  end

  def test_scaleway_dev1_s_returns_2gb
    memory = RbrunCore::InstanceTypes.memory_mb(:scaleway, "DEV1-S")

    assert_equal 2048, memory
  end

  def test_aws_t3_medium_returns_4gb
    memory = RbrunCore::InstanceTypes.memory_mb(:aws, "t3.medium")

    assert_equal 4096, memory
  end

  def test_unknown_instance_type_raises_error
    error = assert_raises(RbrunCore::Error::Configuration) do
      RbrunCore::InstanceTypes.memory_mb(:hetzner, "unknown-type")
    end

    assert_match(/Unknown instance type/, error.message)
  end

  def test_unknown_provider_raises_error
    error = assert_raises(RbrunCore::Error::Configuration) do
      RbrunCore::InstanceTypes.memory_mb(:unknown_provider, "t3.medium")
    end

    assert_match(/Unknown instance type/, error.message)
  end
end
