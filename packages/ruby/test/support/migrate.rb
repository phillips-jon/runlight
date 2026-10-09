# frozen_string_literal: true

# Creates Runlight's tables, as one of several processes starting at once: ruby migrate.rb <kind> <url or path> [schema]

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "runlight"

kind, where, schema = ARGV
store = case kind
        when "sqlite" then Runlight::Stores.sqlite(where)
        when "postgres" then Runlight::Stores.postgres(where, schema: schema)
        else Runlight::Stores.mysql(where)
        end
store.migrate
store.close
puts "ok"
