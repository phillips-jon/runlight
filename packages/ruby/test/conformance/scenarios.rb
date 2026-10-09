# frozen_string_literal: true

module Conformance
  # conformance/http.json, read once, with objects as Hashes and lists as Arrays, so {} and [] stay apart.
  module Scenarios
    PATH = File.expand_path("../../../../conformance/http.json", __dir__)

    module_function

    def file
      @file ||= Runlight::Json.decode(File.read(PATH))
    end

    def all
      file["scenarios"]
    end

    def named(name)
      all.find { |scenario| scenario["name"] == name } || raise(ArgumentError, "No scenario is named #{name}")
    end

    # The scenarios RUNLIGHT_CONFORMANCE_SCENARIO picks: the one of that name, else those whose name holds it
    # (any case); every scenario when it is unset.
    def chosen
      wanted = ENV["RUNLIGHT_CONFORMANCE_SCENARIO"].to_s.strip
      return all if wanted.empty?

      exact = all.select { |scenario| scenario["name"] == wanted }
      return exact unless exact.empty?

      some = all.select { |scenario| scenario["name"].downcase.include?(wanted.downcase) }
      raise ArgumentError, "RUNLIGHT_CONFORMANCE_SCENARIO names no scenario: #{wanted}" if some.empty?

      some
    end
  end
end
