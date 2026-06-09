# frozen_string_literal: true

require_relative "testing/node_runner"

module Funicular
  module Testing
    def self.run!(**options)
      NodeRunner.new(**options).run
    end

    def self.assert_picotests(test_case, result, print_summary: true)
      puts result.picotest_summary if print_summary
      test_case.assert result.success?, result.output

      # The Minitest wrapper is one CRuby test method, but the actual client
      # checks run inside PicoRuby. Reflect those inner checks in Minitest's
      # assertion count so successful runs do not look like a single assertion.
      extra_assertions = result.picotest_assertion_count - 1
      test_case.assertions += extra_assertions if extra_assertions.positive?
    end
  end
end
