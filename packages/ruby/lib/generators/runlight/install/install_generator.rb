# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Runlight
  module Generators
    # bin/rails generate runlight:install
    #
    # Writes config/initializers/runlight.rb and a migration that creates
    # Runlight's tables (prefixed rl_) in the app's database with the SQL
    # Runlight itself runs, so they match the ones the TypeScript and PHP
    # versions make, then prints what is left to do. The templates live in this
    # file so the gem ships nothing but Ruby.
    class InstallGenerator < ::Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      desc "Adds Runlight's initializer and the migration that creates its tables."

      MIGRATION_NAME = "create_runlight_tables"

      def create_migration_file
        dir = db_migrate_path
        absolute = File.join(destination_root, dir)
        if (existing = self.class.migration_exists?(absolute, MIGRATION_NAME))
          say_status :exist, existing.delete_prefix("#{destination_root}/"), :blue
          return
        end

        number = self.class.next_migration_number(absolute)
        create_file File.join(dir, "#{number}_#{MIGRATION_NAME}.rb"), migration
      end

      def create_initializer
        create_file "config/initializers/runlight.rb", initializer
      end

      def show_next_steps
        say next_steps
      end

      private

      def migration
        <<~RUBY
          # frozen_string_literal: true

          # Runlight's tables, made with the SQL Runlight itself runs. After a gem upgrade Runlight brings them up
          # to date on its own, on the first request or with bin/rails runlight:migrate.
          class CreateRunlightTables < ActiveRecord::Migration[#{::ActiveRecord::Migration.current_version}]
            # Postgres builds the indexes CONCURRENTLY, which cannot run inside a transaction.
            disable_ddl_transaction!

            def up
              Runlight::Stores.active_record.migrate(true)
            end

            def down
              connection.tables.grep(/\\Arl_/).each { |table| drop_table table }
            end
          end
        RUBY
      end

      def initializer
        <<~RUBY
          # frozen_string_literal: true

          # Runlight, privacy friendly analytics at /runlight. See https://runlight.sh/docs/rails/
          Runlight.configure(
            # Runlight's tables (rl_*) live in the app's own database.
            store: Runlight::Stores.active_record,
            site: {
              name: #{site_name.inspect},
              # The hostnames that belong to the site, without www. Empty counts every hostname.
              hostnames: [],
              timezone: "UTC",
            },
            routes: {
              base_path: "/runlight",
              # Sign in at /runlight/?token=... with this token. An empty one keeps the dashboard closed,
              # and nil would leave it open to anyone.
              token: ENV.fetch("RUNLIGHT_TOKEN", ""),
            },
          )
        RUBY
      end

      def next_steps
        <<~TEXT

          Runlight is installed. To finish setting it up,
            1. Run bin/rails db:migrate.
            2. Set RUNLIGHT_TOKEN to a long random string, and the site's hostnames in config/initializers/runlight.rb.
            3. Add <script defer src="/runlight/s.js"></script> to your layout's <head>.
            4. Run bin/rails runlight:check every few minutes, from cron or a recurring job.
          Then open /runlight/?token= followed by the token to sign in.
        TEXT
      end

      def site_name
        ::Rails.application.class.module_parent_name.to_s.underscore.tr("_", " ")
      rescue StandardError
        "My site"
      end
    end
  end
end
