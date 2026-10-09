# frozen_string_literal: true

module Conformance
  # Fresh, empty stores for the conformance scenarios, from the Databases helper in test_helper.rb: SQLite in
  # memory always, a Postgres schema of its own in runlight_test_ruby when RUNLIGHT_TEST_PG is set, and the one
  # MySQL or MariaDB database runlight_test_ruby, emptied first, when RUNLIGHT_TEST_MYSQL is set. Databases.cleanup,
  # which every test's teardown runs, drops the schemas.
  module TestStores
    module_function

    # The stores to play on, by name.
    def kinds
      Databases.kinds
    end

    # A fresh store of this kind, Runlight::Stores.from_db over an empty database.
    def store(kind)
      Runlight::Stores.from_db(Databases.db(kind))
    end
  end
end
