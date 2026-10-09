# frozen_string_literal: true

require "rails"

module Runlight
  # Runlight in a Rails app. The engine puts Runlight::Rails::Middleware in the
  # app's middleware stack, which serves the dashboard, the API, and the tracker
  # under the routes' base path (/runlight by default), short links at /go/:slug
  # and on link domains, and records AI agent fetches of the app's pages, all
  # before the router, so Rails' CSRF check and cookie encryption never see
  # Runlight's requests (the tracker cannot send a CSRF token, and Runlight
  # checks requests its own way). It also brings the install generator
  # (`bin/rails generate runlight:install`) and the runlight:check and
  # runlight:migrate tasks.
  class Engine < ::Rails::Engine
    engine_name "runlight"

    initializer "runlight.middleware" do |app|
      app.middleware.use Runlight::Rails::Middleware
    end

    rake_tasks do
      namespace :runlight do
        desc "Runlight's scheduled check: salts, email reports, retention, and rollups. Run it from cron or a job every few minutes"
        task check: :environment do
          result = Runlight.instance.check
          puts Runlight::Json.encode(result)
        end

        desc "Creates or updates Runlight's tables now, rather than on the first request"
        task migrate: :environment do
          Runlight.instance.store.migrate(true)
          puts "Runlight's tables are up to date."
        end
      end
    end
  end

  module Rails
    # Answers Runlight's requests and hands the rest to the app. Until Runlight.configure has run (an app
    # that has not set it up yet), everything goes to the app.
    class Middleware
      def initialize(app)
        @app = app
        @lock = Mutex.new
      end

      def call(env)
        return @app.call(env) unless Runlight.configured?

        rack_app.call(env)
      end

      private

      # Made again when Runlight.configure runs again (a reloaded initializer), so the new settings apply.
      def rack_app
        core = Runlight.instance
        made = @rack_app
        return made if made && made.runlight.equal?(core)

        @lock.synchronize do
          @rack_app = Runlight::RackApp.new(@app, runlight: core, **Runlight.routes_options) unless @rack_app&.runlight.equal?(core)
          @rack_app
        end
      end
    end
  end
end
