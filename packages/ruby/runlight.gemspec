# frozen_string_literal: true

require_relative "lib/runlight/version"

Gem::Specification.new do |spec|
  spec.name = "runlight"
  spec.version = Runlight::GEM_VERSION
  spec.authors = ["Jon C. Phillips"]
  spec.summary = "Privacy friendly web analytics that lives inside your Ruby app."
  spec.description = "Mount the Rails engine or the Rack app, add a script tag, and read your stats at /runlight. " \
                     "The Ruby port of the runlight npm package: same tables, same answers, same dashboard."
  spec.homepage = "https://runlight.sh"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/phillips-jon/runlight/tree/main/packages/ruby",
    "changelog_uri" => "https://github.com/phillips-jon/runlight/releases",
    "bug_tracker_uri" => "https://github.com/phillips-jon/runlight/issues",
    "documentation_uri" => "https://runlight.sh/docs/ruby/",
    "rubygems_mfa_required" => "true",
  }

  # Globbed from this file's directory, so the list is the same whatever the working directory.
  spec.files = Dir.glob(%w[lib/**/*.rb assets/* exe/*], base: __dir__) + %w[README.md LICENSE]
  spec.bindir = "exe"
  spec.executables = ["runlight"]
  spec.require_paths = ["lib"]

  # The store reads and writes through ActiveRecord, on SQLite, Postgres, MySQL, or MariaDB; the app adds the
  # driver gem (sqlite3, pg, mysql2, or trilogy). ActiveSupport brings tzinfo, which reports use for timezones.
  spec.add_dependency "activerecord", ">= 7.2", "< 8.2"
end
