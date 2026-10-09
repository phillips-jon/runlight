# frozen_string_literal: true

require "test_helper"
require_relative "player"
require_relative "core_target"
require_relative "test_stores"
require_relative "answers"

# Replays conformance/http.json against the Ruby core on every store, as
# http-conformance.test.ts does against the TypeScript one: each step's answer
# must equal the one the file holds.
#
# RUNLIGHT_CONFORMANCE_SCENARIO=<name> plays one scenario (or those whose name
# holds it). A failure lists every step that answered differently, each with the
# first field that differs; RUNLIGHT_CONFORMANCE_FULL=1 adds both whole answers,
# and RUNLIGHT_CONFORMANCE_REPORT=<file> writes every difference to that file as
# JSON lines. A step that raises answers {"raised": ...} and the scenario plays on.
class ConformanceTest < Minitest::Test
  # Scenarios and steps played and passed, by database, for the summary after the run.
  TALLY = Hash.new { |h, kind| h[kind] = { "scenarios" => 0, "passed" => 0, "steps" => 0, "matched" => 0 } }

  Conformance::TestStores.kinds.each do |kind|
    Conformance::Scenarios.chosen.each do |scenario|
      define_method("test_#{kind}: #{scenario["name"]}") { play_on(kind, scenario["name"]) }
    end
  end

  Minitest.after_run do
    TALLY.each do |kind, t|
      puts "Conformance on #{kind}: #{t["passed"]} of #{t["scenarios"]} scenarios and #{t["matched"]} of " \
           "#{t["steps"]} requests answered as TypeScript does"
    end
  end

  def play_on(kind, name)
    missing = Conformance::CoreTarget.missing
    skip "Nothing to replay the scenarios against yet: #{missing}" if missing

    scenario = Conformance::Scenarios.named(name)
    store = Conformance::TestStores.store(kind)
    begin
      answers = Conformance::Player.new.play(scenario, ->(rl, routes) { Conformance::CoreTarget.new(rl, routes) },
                                             store, keep_going: true)
    rescue StandardError, ScriptError => e
      self.class.tally(kind, scenario, [])
      raise RuntimeError, "#{name} (#{kind}): the core could not be set up: #{e.class}: #{e.message}", e.backtrace
    end
    self.class.tally(kind, scenario, answers)
    Conformance::Answers.assert_answers(self, scenario, answers, kind)
  end

  def self.tally(kind, scenario, answers)
    t = TALLY[kind]
    differ = Conformance::Answers.differing(scenario, answers)
    t["scenarios"] += 1
    t["passed"] += 1 if differ.empty? && answers.length == scenario["steps"].length
    t["steps"] += scenario["steps"].length
    t["matched"] += scenario["steps"].length - differ.length
  end
end
