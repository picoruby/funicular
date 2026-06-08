# frozen_string_literal: true

require_relative "testing/node_runner"

module Funicular
  module Testing
    def self.run!(**options)
      NodeRunner.new(**options).run
    end
  end
end
