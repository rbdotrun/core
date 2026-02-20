# frozen_string_literal: true

require_relative "../test_helper"
require "rbrun_cli"

module RbrunCliTestSetup
  private

    def capture_output
      output = StringIO.new
      yield output
      output.string
    end
end

module Minitest
  class Test
    include RbrunCliTestSetup
  end
end
