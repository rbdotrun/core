# frozen_string_literal: true

require "test_helper"

module RbrunCore
  class WaiterTest < Minitest::Test
    def test_poll_returns_truthy_value
      result = Waiter.poll(max_attempts: 3, interval: 0, message: "fail") { "success" }

      assert_equal "success", result
    end

    def test_poll_returns_object_on_success
      obj = Object.new
      result = Waiter.poll(max_attempts: 3, interval: 0, message: "fail") { obj }

      assert_same obj, result
    end

    def test_poll_retries_until_truthy
      attempts = 0
      Waiter.poll(max_attempts: 5, interval: 0, message: "fail") do
        attempts += 1
        attempts >= 3
      end

      assert_equal 3, attempts
    end

    def test_poll_raises_timeout_error_on_exhaustion
      error = assert_raises(Waiter::TimeoutError) do
        Waiter.poll(max_attempts: 3, interval: 0, message: "Custom timeout") { false }
      end
      assert_equal "Custom timeout", error.message
    end

    def test_poll_yields_iteration_index
      indices = []
      Waiter.poll(max_attempts: 3, interval: 0, message: "fail") do |i|
        indices << i
        i == 2
      end

      assert_equal [ 0, 1, 2 ], indices
    end

    def test_poll_skips_sleep_on_last_iteration
      sleeps = []

      Waiter.stub(:sleep, ->(n) { sleeps << n }) do
        assert_raises(Waiter::TimeoutError) do
          Waiter.poll(max_attempts: 3, interval: 1, message: "fail") { false }
        end
      end

      assert_equal [ 1, 1 ], sleeps  # 2 sleeps, not 3
    end

    def test_retry_with_backoff_returns_on_success
      result = Waiter.retry_with_backoff(retries: 3, backoff: 2, on: StandardError) { "ok" }

      assert_equal "ok", result
    end

    def test_retry_with_backoff_retries_on_exception
      attempts = 0

      Waiter.stub(:sleep, ->(_) { }) do
        Waiter.retry_with_backoff(retries: 3, backoff: 2, on: RuntimeError) do
          attempts += 1
          raise RuntimeError, "fail" if attempts < 3
          "success"
        end
      end

      assert_equal 3, attempts
    end

    def test_retry_with_backoff_raises_after_max_retries
      attempts = 0

      Waiter.stub(:sleep, ->(_) { }) do
        assert_raises(RuntimeError) do
          Waiter.retry_with_backoff(retries: 3, backoff: 2, on: RuntimeError) do
            attempts += 1
            raise RuntimeError, "fail"
          end
        end
      end

      assert_equal 3, attempts
    end

    def test_retry_with_backoff_uses_exponential_delay
      sleeps = []
      attempts = 0

      Waiter.stub(:sleep, ->(n) { sleeps << n }) do
        assert_raises(RuntimeError) do
          Waiter.retry_with_backoff(retries: 4, backoff: 2, on: RuntimeError) do
            attempts += 1
            raise RuntimeError, "fail"
          end
        end
      end

      assert_equal [ 2, 4, 8 ], sleeps  # 2^1, 2^2, 2^3
    end

    def test_retry_with_backoff_accepts_array_of_exceptions
      attempts = 0

      Waiter.stub(:sleep, ->(_) { }) do
        Waiter.retry_with_backoff(retries: 3, backoff: 2, on: [ ArgumentError, RuntimeError ]) do
          attempts += 1
          raise ArgumentError if attempts == 1
          raise RuntimeError if attempts == 2
          "ok"
        end
      end

      assert_equal 3, attempts
    end

    def test_retry_with_backoff_does_not_catch_other_exceptions
      Waiter.stub(:sleep, ->(_) { }) do
        assert_raises(NoMethodError) do
          Waiter.retry_with_backoff(retries: 3, backoff: 2, on: RuntimeError) do
            raise NoMethodError, "wrong"
          end
        end
      end
    end
  end
end
