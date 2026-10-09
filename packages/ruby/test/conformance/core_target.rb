# frozen_string_literal: true

require_relative "target"

module Conformance
  # The Ruby core, through the public API the port conventions name.
  class CoreTarget
    include Target

    # runlight_options: for Runlight::Core.new; routes_options: for core.routes.
    def initialize(runlight_options, routes_options)
      @rl = Runlight::Core.new(runlight_options)
      @routes = @rl.routes(routes_options)
      @links = @rl.link_handler
    end

    # nil when the core, its routes, and Stores.from_db are all here and load, else why not.
    def self.missing
      lib = File.expand_path("../../lib/runlight", __dir__)
      %w[core routes store/sql_store].each do |file|
        return "lib/runlight/#{file}.rb is not here yet" unless File.exist?(File.join(lib, "#{file}.rb"))
      end
      Runlight::Core
      Runlight::Routes
      Runlight::Store::SqlStore
      nil
    rescue ScriptError, StandardError => e
      "the core does not load: #{e.class}: #{e.message.lines.first&.strip}"
    end

    def handle(request)
      @routes.handle(request)
    end

    def links(request)
      @links.call(request)
    end

    def link_domain(request)
      @rl.link_domain_response(request)
    end

    # TypeScript deletes visits past a shorter retention after answering. If the Ruby core does that work
    # inline, there is nothing to wait for; if it defers it, it gives the core an idle that finishes it.
    def idle
      @rl.idle if @rl.respond_to?(:idle)
    end
  end
end
