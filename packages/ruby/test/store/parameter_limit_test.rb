# frozen_string_literal: true

require "test_helper"
require_relative "../support/store_test_case"

# d1-limits.test.ts at the store: no statement binds more than 100 values, as Cloudflare D1 requires, over a
# year of data, on SQLite as D1 runs it and on MySQL, whose statements for the same reports are written
# differently.
class StoreParameterLimitTest < StoreTestCase
  on_each "no_statement_binds_more_than_100_parameters", Databases.kinds - ["postgres"] do |kind|
    store = store(kind)
    # A visit every third day for a year, so a year of days can be built.
    store.transaction do |tx|
      (0...365).step(3) do |d|
        t = NOW - 365 * DAY + d * DAY
        Seed.visit(tx, "y#{d}", "v#{d}", t, { "country" => "GB" }, [["pageview", "/p#{d % 40}", t, "y#{d}"], ["event", "Goal#{d % 30}", t + 1, { "amount" => d }]])
      end
    end
    Seed.build_days(store, "default", NOW - 366 * DAY, NOW - DAY)
    30.times do |g|
      store.save_goal(goal(g.to_s(16).rjust(24, "0"), { "name" => "Goal #{g}", "match" => "Goal#{g}", "valueMode" => g.odd? ? "prop" : "fixed", "value" => 5, "valueProp" => "amount" }))
    end
    funnel = { "id" => "f" * 24, "site" => "default", "name" => "Funnel", "steps" => [{ "kind" => "page", "match" => "/p1" }, { "kind" => "event", "match" => "Goal1" }], "createdAt" => 0 }
    store.save_funnel(funnel)
    # Days not built, scattered through the last month, as late engagement or an import leaves them.
    (2...30).step(3) do |d|
      store.clear_rollups("default", { "from" => NOW - d * DAY, "to" => NOW - d * DAY + 1 })
    end

    # Every statement from here on is checked.
    watched = WatchedDb.new(store.db)
    most = 0
    watched.before = lambda do |_sql, params|
      most = [most, params.length].max
      raise "a statement bound #{params.length} parameters" if params.length > 100
    end
    view = Runlight::Store::SqlStore.new(watched)
    goals = view.goals("default")
    days = lambda do |from, to, size|
      (from...to).step(size).map { |at| { "start" => at, "end" => [at + size, to].min } }
    end
    f = ->(d, op, v) { { "dimension" => d, "op" => op, "value" => v } }
    # As many filters as a query takes, each of the kind that binds the most.
    many = [f.("page", "contains", "/P"), f.("page", "contains", "é"), f.("event", "contains", "goal"), f.("hostname", "contains", "example"), f.("page", "not", "/x"), f.("country", "not", "XX")]
    # Path filters in mixed case are tried in several forms, each a value of its own.
    paths = [f.("page", "contains", "/pÉ"), f.("page", "contains", "/Pé"), f.("page", "contains", "/xÜ"), f.("page", "contains", "/üX"), f.("page", "contains", "/ÉtÉ"), f.("hostname", "contains", "eXa")]
    ranges = {
      "12mo" => [NOW - 365 * DAY, NOW + DAY, DAY],
      "all" => [NOW - 400 * DAY, NOW + DAY, 30 * DAY],
      "90d" => [NOW - 90 * DAY, NOW + DAY, DAY],
      "30d" => [NOW - 30 * DAY, NOW + DAY, DAY],
      "7d hourly" => [NOW - 7 * DAY, NOW + DAY, HOUR],
    }
    ranges.each_value do |from, to, size|
      [[], [f.("page", "contains", "/p")], [f.("country", "not", "XX")], many, paths].each do |filters|
        query = { "site" => "default", "from" => from, "to" => to, "filters" => filters }
        view.stats(query)
        view.series(query, days.call(from, to, size))
        view.hourly(query)
        view.breakdown(query, "page", 1000, 0)
        view.breakdown(query, "source", 1000, 0)
        view.breakdown(query, "event", 1000, 0)
        assert_equal 30, view.goal_totals_all(query, goals).length
        [goals[1], goals[2]].each do |goal|
          view.goal_totals(query, goal)
          view.goal_series(query, goal, days.call(from, to, size))
          view.goal_breakdown(query, goal, "path")
        end
        view.funnel_counts(query, funnel)
        view.journey_pages(query, 5)
        view.event_prop_keys(query, "Goal1")
        view.event_prop_values(query, "Goal1", "amount", 10)
      end
    end
    assert_operator most, :<=, 100
    assert_operator most, :>, 50, "the reads came close"
  end
end
