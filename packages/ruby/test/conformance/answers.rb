# frozen_string_literal: true

require_relative "normalizer"

module Conformance
  # Answers compared with the ones http.json expects, and a difference put in one line: the step, its method
  # and path, and the first field that differs, with both values.
  module Answers
    # A field one answer has and the other does not.
    ABSENT = Object.new.freeze

    # Text that describes a value rather than being one, shown as it is.
    Said = Struct.new(:text)

    # The fields of an answer in the order a difference is looked for: the status before what follows from it.
    ORDER = %w[raised status headers body text files found fetched pass].freeze

    module_function

    # The indexes of the steps whose answer differs from the expected one.
    def differing(scenario, answers)
      scenario["steps"].each_index.reject do |i|
        Conformance::Normalizer.canonical(scenario["steps"][i]["expect"]) == Conformance::Normalizer.canonical(answers[i])
      end
    end

    # Compares answer by answer and fails with one line for each step that differs: the scenario, the step,
    # its method and path, and the first field that differs, with both values.
    def assert_answers(test, scenario, answers, kind = "fake")
      test.assert_equal scenario["steps"].length, answers.length, "#{scenario["name"]} (#{kind}): one answer for each step"
      differ = differing(scenario, answers)
      if differ.empty?
        test.pass
        return
      end
      lines = differ.map do |i|
        step = scenario["steps"][i]
        line = "  step #{i + 1}, #{step["method"]} #{step["path"]}: #{describe(step["expect"], answers[i])}"
        if ENV["RUNLIGHT_CONFORMANCE_FULL"].to_s.strip != ""
          line += "\n    expected #{Conformance::Normalizer.canonical(step["expect"]).gsub("\n", "\n    ")}" \
                  "\n    actual #{Conformance::Normalizer.canonical(answers[i]).gsub("\n", "\n    ")}"
        end
        line
      end
      report(kind, scenario, answers, differ)
      test.flunk("#{scenario["name"]} (#{kind}): #{differ.length} of #{scenario["steps"].length} steps answered " \
                 "differently\n#{lines.join("\n")}")
    end

    # The first difference between two answers, as "path: expected X, got Y".
    def describe(expected, actual)
      return "raised #{actual["raised"]}" if actual.is_a?(Hash) && actual.key?("raised")

      path, want, got = difference(expected, actual, [])
      "#{path.empty? ? "the answer" : path.join(".")}: expected #{show(want)}, got #{show(got)}"
    end

    # [path, expected, actual] for the first place two values differ, nil when they do not.
    def difference(expected, actual, path)
      if expected.is_a?(Hash) && actual.is_a?(Hash)
        keys = (expected.keys | actual.keys).sort_by { |k| [ORDER.index(k) || ORDER.length, k] }
        keys.each do |k|
          return [path + [k], expected.fetch(k, ABSENT), actual.fetch(k, ABSENT)] unless expected.key?(k) && actual.key?(k)

          found = difference(expected[k], actual[k], path + [k])
          return found if found
        end
        return nil
      end
      if expected.is_a?(Array) && actual.is_a?(Array)
        [expected.length, actual.length].min.times do |i|
          found = difference(expected[i], actual[i], path + [i])
          return found if found
        end
        return nil if expected.length == actual.length

        first = expected.length > actual.length ? "first missing: #{show(expected[actual.length])}" : "first extra: #{show(actual[expected.length])}"
        return [path, Said.new("#{expected.length} items"), Said.new("#{actual.length} items (#{first})")]
      end
      return nil if Conformance::Normalizer.canonical(expected) == Conformance::Normalizer.canonical(actual)

      [path, expected, actual]
    end

    def show(value)
      return "(absent)" if value.equal?(ABSENT)
      return value.text if value.is_a?(Said)

      text = Runlight::Json.encode(value)
      text.length > 200 ? "#{text[0, 200]}..." : text
    end

    # Every difference as a JSON line in RUNLIGHT_CONFORMANCE_REPORT's file, when it names one.
    def report(kind, scenario, answers, differ)
      file = ENV["RUNLIGHT_CONFORMANCE_REPORT"].to_s.strip
      return if file.empty?

      File.open(file, "a") do |out|
        differ.each do |i|
          step = scenario["steps"][i]
          out.puts Runlight::Json.encode({ "kind" => kind, "scenario" => scenario["name"], "step" => i + 1,
                                           "method" => step["method"], "path" => step["path"],
                                           "difference" => describe(step["expect"], answers[i]),
                                           "expected" => step["expect"], "actual" => answers[i] })
        end
      end
    end
  end
end
