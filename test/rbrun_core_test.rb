# frozen_string_literal: true

require "test_helper"

class RbrunCoreTest < Minitest::Test
  def test_version_is_defined
    refute_nil RbrunCore::VERSION
  end

  def test_exposes_configuration_class
    assert_kind_of Class, RbrunCore::Configuration
  end

  def test_exposes_context_class
    assert_kind_of Class, RbrunCore::Context
  end

  def test_exposes_commands_module
    assert_kind_of Module, RbrunCore::Commands
  end

  def test_exposes_steps_module
    assert_kind_of Module, RbrunCore::Steps
  end

  def test_exposes_naming_module
    assert_kind_of Module, RbrunCore::Naming
  end
end
