# frozen_string_literal: true

require "test_helper"
require_relative "../support/store_test_case"

# Daily rollups, as rollups.test.ts and counting.test.ts test them at the store.
class StoreRollupsTest < StoreTestCase
  PAGES = ["/", "/blog/one", "/blog/two", "/pricing", "/about"].freeze
  SOURCES = ["Google", "Hacker News", "", "ChatGPT", "Twitter"].freeze
  COUNTRIES = %w[GB US DE CA].freeze

  # Ten days of visits, some running past midnight, ending two hours before NOW.
  def ten_days(store)
    now = NOW - 10 * DAY
    n = 0
    10.times do
      6.times do
        n += 1
        start = now
        rows = []
        (1 + n % 3).times do |p|
          id = "pv#{n}x#{p}"
          rows << ["pageview", PAGES[(n + p) % 5], now, id]
          now += 20_000 + (n % 5) * 7_000
          rows << ["engagement", id, now, 9_000 + n * 100, 40 + n % 60] if n.even?
          rows << ["event", "Signup", now, nil] if (n % 4).zero?
        end
        # Visitor ids change every day, as the daily salt changes them.
        Seed.visit(store, "s#{n}", "v#{n % 4}#{Time.at(start / 1000).utc.strftime("%Y%m%d")}", start, {
          "source" => SOURCES[n % 5], "channel" => SOURCES[n % 5] == "" ? "Direct" : "Referral", "referrerHost" => SOURCES[n % 5] == "" ? "" : "x.example",
          "country" => COUNTRIES[n % 4], "device" => (n % 3).zero? ? "Mobile" : "Desktop", "browser" => (n % 3).zero? ? "Safari" : "Chrome", "os" => (n % 3).zero? ? "iOS" : "macOS",
        }, rows)
        now += 3 * HOUR + (n % 7) * MIN
      end
      # A visit that runs past midnight belongs to the day it started.
      now += DAY - 6 * (3 * HOUR) - 30 * MIN
    end
  end

  # Every report the dashboard asks the store for, as JSON, for comparing before and after.
  def everything(store)
    out = {}
    ranges = {
      "7d" => [NOW - 7 * DAY, NOW + DAY],
      "30d" => [NOW - 30 * DAY, NOW + DAY],
      "odd" => [NOW - 6 * DAY - 5 * HOUR, NOW - 2 * DAY + 3 * HOUR],
      "today" => [NOW - 12 * HOUR, NOW + 12 * HOUR],
      "all" => [0, NOW + DAY],
    }
    ranges.each do |name, (from, to)|
      query = q(from, to)
      out["stats #{name}"] = store.stats(query)
      buckets = []
      at = from.zero? ? NOW - 12 * DAY : from
      while at < to
        buckets << { "start" => at, "end" => [at + DAY, to].min }
        at += DAY
      end
      out["series #{name}"] = store.series(query, buckets)
      out["hourly #{name}"] = store.hourly(query).sort_by { |h| h["quarter"] }
      %w[page event entry exit source channel referrer country browser device os].each do |dimension|
        out["#{dimension} #{name}"] = store.breakdown(query, dimension, 3, 0)
        out["#{dimension} #{name} page 2"] = store.breakdown(query, dimension, 3, 3)
      end
    end
    out["filtered"] = store.stats(q(NOW - 30 * DAY, NOW + DAY, %w[country is GB]))
    out.transform_values { |v| Runlight::Json.encode(v) }
  end

  on_each "reports_read_from_daily_rollups_match_reports_read_from_every_visit" do |kind|
    store = store(kind)
    ten_days(store)
    before = everything(store)
    assert_operator Seed.build_days(store, "default", NOW - 11 * DAY, NOW), :>=, 8
    assert_equal 11, store.rollup_days("default").length
    after = everything(store)
    before.each { |key, value| assert_equal value, after[key], key }

    # Proof the reports read the rollups: with the built days' raw visits gone, a long range still adds up.
    span = store.db.all("SELECT MIN(start_at) AS s, MAX(end_at) AS e FROM rl_rollup_days")[0]
    store.db.run("DELETE FROM rl_events WHERE ts >= ? AND ts < ?", [Integer(span["s"]), Integer(span["e"]) - 2 * HOUR])
    store.db.run("DELETE FROM rl_sessions WHERE started_at >= ? AND started_at < ?", [Integer(span["s"]), Integer(span["e"]) - 2 * HOUR])
    again = everything(store)
    ["stats 30d", "source 30d", "page 30d", "event 30d", "hourly 30d"].each do |key|
      assert_equal before[key], again[key], "#{key} comes from rollups"
    end
  end

  on_each "a_late_event_and_engagement_on_an_old_pageview_are_counted_once_the_day_is_built_again" do |kind|
    store = store(kind)
    # Evening of October 5th, then rollups built the next morning.
    start = Seed.utc(2026, 10, 5, 20)
    Seed.visit(store, "s1", "v1", start, {}, [["pageview", "/", start, "late1"]])
    day5 = Seed.utc(2026, 10, 5)
    store.build_rollup_day("default", "2026-10-05", day5, day5 + DAY)
    # The tab was left open overnight: its event and engagement arrive now.
    late = start + 7 * HOUR
    store.insert_event({ "site" => "default", "ts" => late, "kind" => "event", "visitor" => "v1", "session" => "s1", "pageview" => "late1", "path" => "/", "hostname" => "example.com", "title" => "", "name" => "Signup", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => "" })
    store.touch_session("s1", late, "event", "/", false)
    store.insert_event({ "site" => "default", "ts" => late, "kind" => "engagement", "visitor" => "v1", "session" => "s1", "pageview" => "late1", "path" => "/", "hostname" => "example.com", "title" => "", "name" => "", "props" => nil, "engagedMs" => 60_000, "scroll" => 80, "link" => "" })
    store.add_engagement("s1", 60_000)
    store.touched_old_visit("default", start, late - 2 * HOUR)
    assert_equal [], store.rollup_days("default"), "the day is forgotten"
    store.touched_old_visit("default", start, start - 1)
    query = q(day5, day5 + DAY)
    read = -> { Runlight::Json.encode([store.stats(query), store.breakdown(query, "event", 10, 0), store.breakdown(query, "page", 10, 0)]) }
    store.build_rollup_day("default", "2026-10-05", day5, day5 + DAY)
    rolled = read.call
    store.clear_rollups("default")
    assert_equal [], store.rollup_days("default")
    assert_equal rolled, read.call
    assert_equal 0, store.stats(query)["bounceRate"], "the event means the visit did not bounce"
    assert_equal ["Signup"], store.breakdown(query, "event", 10, 0).map { |r| r["value"] }
  end

  on_each "ties_come_in_code_point_order_the_same_before_and_after_the_days_are_built" do |kind|
    store = store(kind)
    values = ["alpha", "Zeta", "beta", "Gamma", "émile", "Émile", "_x", "a-b", "ab"]
    t = NOW - DAY
    values.each_with_index do |value, i|
      Seed.visit(store, "s#{i}", "v#{i}", t + i * MIN, { "utmCampaign" => value }, [["pageview", "/", t + i * MIN, "pv#{i}"]])
    end
    expected = values.sort_by(&:b)
    week = q(NOW - 7 * DAY, NOW + DAY)
    assert_equal expected, store.breakdown(week, "utm_campaign", 20, 0).map { |r| r["value"] }, "read from every visit"
    Seed.build_days(store, "default", NOW - 2 * DAY, NOW)
    assert_equal expected, store.breakdown(week, "utm_campaign", 20, 0).map { |r| r["value"] }, "read from rollups"
  end

  # Visits some days back, built, as the two clearing tests start.
  def built(kind, days)
    store = store(kind)
    days.times do |d|
      t = NOW - (days + 2 - d) * DAY
      Seed.visit(store, "s#{d}", "v#{d}", t, {}, [["pageview", "/", t, "d#{d}"]])
    end
    Seed.build_days(store, "default", NOW - (days + 3) * DAY, NOW - DAY)
    month = q(NOW - 30 * DAY, NOW + DAY)
    [store, month, store.stats(month)]
  end

  on_each "a_day_built_by_another_process_while_it_is_being_cleared_is_never_left_marked_built_without_its_numbers" do |kind|
    store, month, before = built(kind, 4)
    watched = WatchedDb.new(store.db)
    view = Runlight::Store::SqlStore.new(watched)
    raced = false
    watched.after_run = lambda do |sql, _params|
      if !raced && sql.start_with?("DELETE FROM rl_rollup_days WHERE site = ? AND start_at")
        raced = true
        watched.after_run = nil
        # Another process builds the days right after their marks are deleted.
        Seed.build_days(store, "default", NOW - 7 * DAY, NOW - DAY)
      end
    end
    view.clear_rollups("default", { "from" => NOW - 4 * DAY, "to" => NOW })
    assert raced
    assert_equal before, store.stats(month)
  end

  on_each "clearing_days_that_stops_part_way_leaves_none_marked_built_without_its_numbers" do |kind|
    store, month, before = built(kind, 8)
    watched = WatchedDb.new(store.db)
    deletes = 0
    watched.before = lambda do |sql, _params|
      raise "connection lost" if sql.start_with?("DELETE FROM rl_rollups WHERE") && (deletes += 1) > 3
    end
    error = assert_raises(RuntimeError) { Runlight::Store::SqlStore.new(watched).clear_rollups("default") }
    assert_equal "connection lost", error.message
    assert_equal before, store.stats(month)
    Seed.build_days(store, "default", NOW - 12 * DAY, NOW - DAY)
    assert_equal before, store.stats(month)
  end

  on_each "retention_drops_old_visits_with_their_events_and_forgets_the_days_they_were_in" do |kind|
    store = store(kind)
    [Seed.utc(2025, 10, 1), Seed.utc(2026, 7, 1), Seed.utc(2026, 10, 6)].each_with_index do |at, i|
      t = at + HOUR
      Seed.visit(store, "s#{i}", "v#{i}", t, {}, [["pageview", "/", t, "p#{i}"], ["event", "E", t + 1, nil]])
    end
    # An event of the oldest visit that came after the cutoff goes with it.
    store.insert_event({ "site" => "default", "ts" => Seed.utc(2025, 10, 1) + DAY, "kind" => "event", "visitor" => "v0", "session" => "s0", "pageview" => "", "path" => "/", "hostname" => "", "title" => "", "name" => "Late", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => "" })
    all = q(0, NOW + DAY)
    assert_equal 3, store.stats(all)["visits"]
    store.build_rollup_day("default", "2026-07-01", Seed.utc(2026, 7, 1), Seed.utc(2026, 7, 2))
    store.drop_before("default", Seed.utc(2026, 4, 6))
    assert_equal 2, store.stats(all)["visits"], "the visit from a year ago is gone"
    assert_equal 0, Integer(store.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE session = 's0'")[0]["n"]), "its events, even the late one"
    assert_equal ["2026-07-01"], store.rollup_days("default"), "a day after the cutoff stays built"
    store.drop_before("default", Seed.utc(2026, 8, 1))
    assert_equal 1, store.stats(all)["visits"]
    assert_equal [], store.rollup_days("default"), "a day before the cutoff is built again later"

    # Events whose visit is gone, as an older version left them, are swept.
    store.insert_event({ "site" => "default", "ts" => NOW - DAY, "kind" => "pageview", "visitor" => "x", "session" => "gone", "pageview" => "g", "path" => "/", "hostname" => "", "title" => "", "name" => "", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => "" })
    store.insert_event({ "site" => "default", "ts" => NOW - DAY, "kind" => "fetch", "visitor" => "", "session" => "", "pageview" => "", "path" => "/", "hostname" => "", "title" => "", "name" => "GPTBot", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => "" })
    store.drop_orphans("default", 0, NOW + DAY)
    assert_equal 0, Integer(store.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE session = 'gone'")[0]["n"])
    assert_equal 1, Integer(store.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'fetch'")[0]["n"]), "rows of no visit stay"
  end
end
