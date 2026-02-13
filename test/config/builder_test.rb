# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Config
    class BuilderTest < Minitest::Test
      def test_defaults_enabled_to_false
        builder = Builder.new

        refute_predicate builder, :enabled?
      end

      def test_enabled_returns_true_when_set
        builder = Builder.new
        builder.enabled = true

        assert_predicate builder, :enabled?
      end

      def test_enabled_returns_false_for_non_true_values
        builder = Builder.new
        builder.enabled = "true"

        refute_predicate builder, :enabled?
      end

      def test_default_machine_type
        builder = Builder.new

        assert_equal "cpx31", builder.machine_type
      end

      def test_machine_type_is_configurable
        builder = Builder.new
        builder.machine_type = "cpx41"

        assert_equal "cpx41", builder.machine_type
      end

      def test_default_volume_size
        builder = Builder.new

        assert_equal 50, builder.volume_size
      end

      def test_volume_size_is_configurable
        builder = Builder.new
        builder.volume_size = 100

        assert_equal 100, builder.volume_size
      end

      def test_default_machine_type_constant
        assert_equal "cpx31", Builder::DEFAULT_MACHINE_TYPE
      end

      def test_default_volume_size_constant
        assert_equal 50, Builder::DEFAULT_VOLUME_SIZE
      end
    end
  end
end
