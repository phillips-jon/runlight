# frozen_string_literal: true

# The smallest Rails app that exercises the engine: ActiveRecord on a SQLite
# file, Action Dispatch with one route of the app's own, and runlight required
# as a Gemfile would, after Rails. Booted once per process.
ENV["RAILS_ENV"] = "test"
require_relative "../test_helper"
require "logger"
require "stringio"
require "tmpdir"
require "fileutils"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "runlight/rails"
require "rails/generators"
require "generators/runlight/install/install_generator"

module RailsApp
  ROOT = Dir.mktmpdir("runlight-rails-")
  LOG = StringIO.new
  Minitest.after_run { FileUtils.rm_rf(ROOT) }

  FileUtils.mkdir_p(File.join(ROOT, "config"))
  FileUtils.mkdir_p(File.join(ROOT, "db"))
  File.write(File.join(ROOT, "config/database.yml"), <<~YAML)
    test:
      adapter: sqlite3
      database: #{File.join(ROOT, "db/test.sqlite3")}
      pool: 5
  YAML

  class Application < ::Rails::Application
    config.root = ROOT
    config.eager_load = false
    config.logger = Logger.new(LOG)
    config.secret_key_base = "runlight-test-#{"x" * 48}"
    config.active_support.deprecation = :silence
    config.hosts.clear
    routes.append do
      get "/hello", to: ->(_env) { [200, { "content-type" => "text/plain" }, ["hello from the app"]] }
      post "/form", to: ->(env) { [200, { "content-type" => "text/plain" }, [env["rack.input"].read]] }
    end
  end

  Application.initialize!
  ActiveRecord::Migration.verbose = false
end
