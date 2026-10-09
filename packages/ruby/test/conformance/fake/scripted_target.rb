# frozen_string_literal: true

require_relative "../target"

module Conformance
  module Fake
    # A target that hands each request to the next callable in a script, for tests that look at exactly what
    # the runner sends. Each is called with the request and the entry point's name.
    class ScriptedTarget
      include Target

      attr_reader :seen, :idled

      def initialize(script)
        @script = script.dup
        @seen = []
        @idled = 0
      end

      def handle(request)
        take_step("routes", request) || Runlight::Http::Response.new("", status: 404)
      end

      def links(request)
        take_step("links", request) || Runlight::Http::Response.new("", status: 404)
      end

      def link_domain(request)
        take_step("linkDomain", request)
      end

      def idle
        @idled += 1
      end

      def take_step(to, request)
        @seen << [to, request]
        step = @script.shift || raise("The script ran out")
        step.call(request, to)
      end
    end
  end
end
