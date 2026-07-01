# frozen_string_literal: true

# Coverage must start before any lib/ file is required so every line is
# tracked. Opt in via `rake test:coverage` (or COVERAGE=1) to avoid slowing
# down focused, single-file runs.
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    # Only the gem's own Ruby implementation (lib/) is in scope here. The
    # PicoRuby runtime (mrblib/), the client test suite (test/), and the
    # minitest suite itself are out of scope for this coverage report.
    root File.expand_path("..", __dir__)
    add_filter %r{\A/(minitest|test|mrblib|sig|exe|bin)/}
    track_files "lib/**/*.rb"

    add_group "Core",       "lib/funicular"
    add_group "SSR",        "lib/funicular/ssr"
    add_group "Rails",      %r{lib/funicular/(railtie|middleware|helpers|commands|tasks)}
    add_group "Generators", "lib/generators"
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "funicular"
require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use!
