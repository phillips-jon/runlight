# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../support/core_test_case"
require_relative "../support/watched_db"

# The scheduled check and the rollups it builds, as rollups.test.ts and hardening.test.ts test the process around the store.
class CoreCheckTest < CoreTestCase
  PAGES = ["/", "/blog/one", "/blog/two", "/pricing", "/about"].freeze
  REFERRERS = ["https://www.google.com/", "https://news.ycombinator.com/", "", "https://chatgpt.com/", "https://t.co/x"].freeze
  COUNTRIES = %w[GB US DE CA].freeze

  # Every report this test compares before and after the days are built.
  def everything(t)
    out = {}
    ranges = { "7d" => t.query("2026-09-30", "2026-10-06"), "30d" => t.query("2026-09-07", "2026-10-06"),
               "some" => t.query("2026-09-29", "2026-10-03"), "all" => t.all }
    ranges.each do |name, q|
      out["stats #{name}"] = t.stats(q)
      out["hourly #{name}"] = t.store.hourly(q)
      %w[page event entry exit source channel referrer country browser device os].each do |dimension|
        out["#{dimension} #{name}"] = t.store.breakdown(q, dimension, 3, 0)
        out["#{dimension} #{name} page 2"] = t.store.breakdown(q, dimension, 3, 3)
      end
    end
    out["filtered"] = t.stats(t.query("2026-09-07", "2026-10-06", nil, [{ "dimension" => "country", "op" => "is", "value" => "GB" }]))
    out
  end

  # A temporary SQLite file, removed afterwards.
  def with_file
    Dir.mktmpdir("runlight-zones-") { |dir| yield File.join(dir, "runlight.db") }
  end

  on_every_database("reports read from daily rollups match reports read from every visit") do |kind|
    # Toronto, so local days and UTC days differ, starting ten days back.
    t = Harness.new(kind, { "site" => { "hostnames" => ["example.com"], "timezone" => "America/Toronto" } })
    start = t.now
    t.advance(-10 * 24 * HOUR)
    n = 0
    10.times do
      6.times do
        n += 1
        init = { "ip" => "203.0.113.#{n % 40}", "headers" => { "x-vercel-ip-country" => COUNTRIES[n % 4] } }
        init["ua"] = Harness::SAFARI_IPHONE if (n % 3).zero?
        (1 + (n % 3)).times do |p|
          id = "pv#{n}x#{p}"
          t.track({ "k" => "pageview", "u" => "https://example.com#{PAGES[(n + p) % 5]}", "r" => p.zero? ? REFERRERS[n % 5] : "", "i" => id }, init)
          t.advance(20_000 + ((n % 5) * 7_000))
          t.track({ "k" => "engagement", "u" => "https://example.com/", "i" => id, "e" => 9_000 + (n * 100), "d" => 40 + (n % 60) }, init) if n.even?
          t.track({ "k" => "event", "u" => "https://example.com/", "i" => id, "n" => "Signup" }, init) if (n % 4).zero?
        end
        t.advance((3 * HOUR) + ((n % 7) * 60_000))
      end
      # A visit that runs past midnight: it belongs to the day it started.
      t.advance((24 * HOUR) - (6 * (3 * HOUR)) - (30 * 60_000))
    end
    t.advance(start - t.now + (2 * HOUR))

    before = everything(t)
    built = 0
    while (made = t.rl.build_rollups).positive?
      built += made
    end
    assert_operator built, :>=, 8
    assert_equal 0, t.rl.build_rollups, "a built day is not built again"
    assert_equal before, everything(t)
  end

  on_every_database("a late event and engagement on an old pageview are counted once the day is built again") do |kind|
    t = Harness.new(kind, { "site" => { "hostnames" => ["example.com"], "timezone" => "UTC" } })
    # Evening of October 5th, then rollups built the next morning.
    t.now = utc(2026, 10, 5, 20)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "late1" }, { "ip" => "203.0.113.50" })
    t.advance(7 * HOUR)
    assert_operator t.rl.build_rollups, :>=, 1
    # The tab was left open overnight: its event and engagement arrive now.
    t.track({ "k" => "event", "u" => "https://example.com/", "i" => "late1", "n" => "Signup" }, { "ip" => "203.0.113.50" })
    t.track({ "k" => "engagement", "u" => "https://example.com/", "i" => "late1", "e" => 60_000, "d" => 80 }, { "ip" => "203.0.113.50" })
    q = t.query("2026-10-05", "2026-10-05")
    read = -> { { "stats" => t.stats(q), "events" => t.store.breakdown(q, "event", 10, 0), "pages" => t.store.breakdown(q, "page", 10, 0) } }
    t.rl.build_rollups
    rolled = read.call
    t.store.clear_rollups("default")
    raw = read.call
    assert_equal raw, rolled
    assert_equal 0, raw["stats"]["bounceRate"], "the event means the visit did not bounce"
    assert_equal ["Signup"], raw["events"].map { |e| e["value"] }
  end

  on_every_database("after a timezone change only days after it are built") do |kind|
    t = Harness.new(kind, { "site" => { "hostnames" => ["example.com"], "timezone" => "UTC" } })
    t.rl.init
    t.now = utc(2026, 10, 3, 10)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "r" => "", "i" => "a1" }, { "ip" => "203.0.113.1" })
    t.advance(10 * HOUR)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "r" => "", "i" => "a2" }, { "ip" => "203.0.113.1" })
    t.now = utc(2026, 10, 4, 12)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "r" => "", "i" => "b1" }, { "ip" => "203.0.113.2" })
    t.now = utc(2026, 10, 6, 12)
    assert_operator t.rl.build_rollups, :>=, 2

    t.rl.update_site("default", { "timezone" => "Asia/Tokyo" })
    q = t.query("2026-10-03", "2026-10-05")
    before = t.stats(q)
    assert_equal 0, t.rl.build_rollups, "days before the change stay counted visit by visit"
    assert_equal before, t.stats(q)
    assert_equal 2, before["visitors"]
    # A day that starts after the change is built as usual.
    t.advance(3 * 24 * HOUR)
    assert_operator t.rl.build_rollups, :>=, 1
  end

  def test_two_processes_on_one_database_a_stale_timezone_builds_nothing_and_clears_nothing
    with_file do |file|
      now = utc(2026, 10, 3, 12)
      clock = -> { now }
      old = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(file), "site" => { "hostnames" => ["example.com"], "timezone" => "UTC" }, "now" => clock })
      old.init
      old.collect(Harness.hit("https://example.com/runlight/e", { "k" => "pageview", "u" => "https://example.com/" },
                              { "ip" => "203.0.113.1", "ua" => Harness::SAFARI_IPHONE }))
      now = utc(2026, 10, 6, 12)
      assert_operator old.build_rollups, :>=, 2, "the old process builds in UTC"
      built = -> { old.store.db.all("SELECT COUNT(*) AS n FROM rl_rollup_days")[0]["n"].to_i }

      # A new copy starts with the timezone changed in code: it clears the old days once, at startup.
      fresh = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(file), "site" => { "hostnames" => ["example.com"], "timezone" => "Asia/Tokyo" }, "now" => clock })
      fresh.init
      assert_equal 0, built.call
      # The old copy, still running, neither builds in UTC nor clears what the new one does.
      now += 3 * DAY
      assert_equal 0, old.build_rollups
      assert_operator fresh.build_rollups, :>=, 1
      after_fresh = built.call
      assert_equal 0, old.build_rollups
      assert_equal after_fresh, built.call, "nothing cleared by the stale copy"
      old.store.close
      fresh.store.close
    end
  end

  def test_a_timezone_changed_in_the_dashboard_reaches_another_process_at_its_next_check
    with_file do |file|
      now = utc(2026, 10, 6, 12)
      clock = -> { now }
      a = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(file), "site" => { "hostnames" => ["example.com"], "timezone" => "UTC" }, "now" => clock })
      b = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(file), "site" => { "hostnames" => ["example.com"], "timezone" => "UTC" }, "now" => clock })
      a.init
      b.init
      a.update_site("default", { "timezone" => "Europe/Paris" })
      assert_equal "UTC", b.site("default")["timezone"]
      # A visit after the change, and days enough for its day to be built.
      b.store.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)", [now + DAY, now + DAY])
      now += 3 * DAY
      assert_equal 0, b.build_rollups, "holding the old timezone, it builds nothing"
      b.check
      assert_equal "Europe/Paris", b.site("default")["timezone"]
      assert_equal %w[2026-10-07 2026-10-08], b.store.rollup_days("default").sort, "then it builds the days after the change"
      a.store.close
      b.store.close
    end
  end

  on_every_database("events left behind by an older version whose visit retention removed are swept once") do |kind|
    t = Harness.new(kind, { "site" => { "hostnames" => ["example.com"], "timezone" => "UTC" } })
    t.rl.init
    old = t.now - (400 * DAY)
    db = t.store.db
    db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)", [old, old])
    db.run("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', 'v1', 's1', 'p1', '/', 'example.com')", [old])
    # An event that joined the visit long after it started, as older versions allowed.
    db.run("INSERT INTO rl_events (site, ts, kind, visitor, session, name, path, hostname) VALUES ('default', ?, 'event', 'v1', 's1', 'Late', '/', 'example.com')", [t.now - (30 * DAY)])
    t.rl.set_retention("default", 6)
    t.rl.idle
    t.rl.check
    assert_equal [], db.all("SELECT name FROM rl_events WHERE site = 'default'")
    assert_equal "1", t.store.setting("orphans-swept:default")
  end

  def test_planner_statistics_are_gathered_once_a_day
    watched = WatchedDb.new(Databases.fresh("sqlite").db)
    analyzed = 0
    watched.before = ->(sql, _params) { analyzed += 1 if sql == "ANALYZE" }
    t = Harness.new(Runlight::Store::SqlStore.new(watched), { "site" => { "hostnames" => ["example.com"], "timezone" => "UTC" } })
    t.rl.init
    assert_equal 1, analyzed, "a database without statistics gets them at the start"
    t.rl.check
    t.rl.check
    assert_equal 2, analyzed, "not again the same day"
    t.advance(DAY)
    t.rl.check
    assert_equal 3, analyzed
    refute_empty t.store.db.all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'"), "statistics written"
  end

  def test_short_link_clicks_are_not_visits_in_the_heatmap_raw_or_rolled_up_nor_the_first_visit
    clock = utc(2026, 10, 7, 12)
    rl = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "sites" => [{ "id" => "a", "name" => "Site A", "hostnames" => ["a.com"] }], "now" => -> { clock } })
    rl.init
    day = utc(2026, 10, 5, 15)
    # A session opened only by a short link click, then a real visit.
    rl.store.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'a', 'v1', ?, ?, 0, 0, 0)", [day - 3_600_000, day - 3_600_000])
    rl.store.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'a', 'v2', ?, ?, 1, 0, 0)", [day, day])
    assert_equal day, rl.store.first_own_visit("a")
    query = { "site" => "a", "from" => utc(2026, 10, 1), "to" => utc(2026, 10, 7), "filters" => [] }
    sum = ->(rows) { rows.sum { |r| r["visits"] } }
    assert_equal 1, sum.call(rl.store.hourly(query)), "raw"
    clock += 3 * 3_600_000
    rl.build_rollups
    assert_equal 1, sum.call(rl.store.hourly(query)), "rolled up"
  end

  def test_a_check_reports_what_it_sent
    t = Harness.new("sqlite")
    assert_equal({ "ok" => true, "reports" => { "sent" => 0, "failed" => 0 } }, t.rl.check)
  end
end
