# frozen_string_literal: true

require "json"

module Runlight
  # The gem's own version, which the release keeps equal to the npm package's.
  GEM_VERSION = "0.1.0"

  # The SDK's version and the HTTP API's, read from assets/build.json, which
  # scripts/ruby-assets.mts writes from the TypeScript SDK, so the two always
  # report the same.
  module Version
    ASSETS = File.expand_path("../../assets", __dir__)

    module_function

    # Everything in assets/build.json: the versions, the asset hashes, and the icon.
    def build
      @build ||= begin
        JSON.parse(File.read(File.join(ASSETS, "build.json")))
      rescue Errno::ENOENT
        raise "Runlight: assets/build.json is missing; run node --import tsx scripts/ruby-assets.mts."
      end
    end

    def version
      build.fetch("version").to_s
    end

    # Bumped when the HTTP API changes shape, so the dashboard and the hub can tell.
    def api_version
      build.fetch("apiVersion").to_i
    end
  end
end
