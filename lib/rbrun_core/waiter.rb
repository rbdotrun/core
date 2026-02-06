# frozen_string_literal: true

module RbrunCore
  module Waiter
    class TimeoutError < RbrunCore::Error; end

    # Poll until block returns truthy value.
    # Returns the truthy value, or raises TimeoutError.
    def self.poll(max_attempts:, interval:, message: "Timed out")
      max_attempts.times do |i|
        result = yield(i)
        return result if result

        sleep(interval) unless i == max_attempts - 1
      end
      raise TimeoutError, message
    end

    # Retry block on specified exceptions with exponential backoff.
    def self.retry_with_backoff(retries:, backoff: 2, on:)
      attempts = 0
      begin
        yield
      rescue *Array(on)
        attempts += 1
        raise if attempts >= retries

        sleep(backoff**attempts)
        retry
      end
    end
  end
end
