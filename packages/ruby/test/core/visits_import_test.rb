# frozen_string_literal: true

require "test_helper"
require "time"
require_relative "../support/core_test_case"
require_relative "../support/router"
require_relative "../support/watched_db"

# Visit history from Umami and from CSV files, as visits-import*.test.ts and visits-csv.test.ts test it at the store.
class CoreVisitsImportTest < CoreTestCase
  CREDENTIALS = { "url" => "https://umami.example.com", "apiKey" => "key" }.freeze
  Visits = Runlight::Importers::Visits
  CsvVisits = Runlight::Importers::CsvVisits
  Json = Runlight::Json

  # Date.parse of an ISO time, in whole seconds.
  def self.at(iso)
    Time.iso8601(iso).to_i * 1000
  end

  def at(iso)
    self.class.at(iso)
  end

  # A small Umami: one website, events answered by time window like the real API, newest first.
  def umami(events, sessions = [], created = "2026-03-01T08:00:00Z", newest_first = true)
    inside = lambda do |url|
      q = url.search_params
      from = q.get("startAt").to_i
      to = q.get("endAt").to_i
      rows = events.select { |e| at(e["createdAt"]) >= from && at(e["createdAt"]) <= to }
      newest_first ? rows.reverse : rows
    end
    Router.new([
      [%r{/api/websites\?}, ->(_u, _i) { { "data" => [{ "id" => "w1", "name" => "Blog", "domain" => "blog.example.com" }], "count" => 1 } }],
      [%r{/api/websites/w1\z}, ->(_u, _i) { { "id" => "w1", "createdAt" => created } }],
      [%r{/api/websites/w1/events\?}, lambda { |u, _i|
        rows = inside.call(u)
        { "data" => rows, "count" => rows.length }
      }],
      [%r{/api/websites/w1/sessions\?}, ->(_u, _i) { { "data" => sessions, "count" => sessions.length } }],
    ])
  end

  def fake_events
    [
      # Visit 1: Google, two pages and a signup, in Toronto on a phone.
      { "sessionId" => "s1", "createdAt" => "2026-03-01T10:00:00.000Z", "hostname" => "blog.example.com", "urlPath" => "/", "urlQuery" => "utm_campaign=spring",
        "referrerDomain" => "www.google.com", "referrerPath" => "/", "pageTitle" => "Home", "eventType" => 1, "country" => "CA", "city" => "Toronto", "device" => "mobile",
        "os" => "iOS", "browser" => "ios" },
      { "sessionId" => "s1", "createdAt" => "2026-03-01T10:02:00.000Z", "hostname" => "blog.example.com", "urlPath" => "/pricing", "pageTitle" => "Pricing",
        "eventType" => 1, "country" => "CA", "city" => "Toronto", "device" => "mobile", "os" => "iOS", "browser" => "ios" },
      { "sessionId" => "s1", "createdAt" => "2026-03-01T10:03:00.000Z", "hostname" => "blog.example.com", "urlPath" => "/pricing", "eventType" => 2,
        "eventName" => "Signup", "country" => "CA", "city" => "Toronto", "device" => "mobile", "os" => "iOS", "browser" => "ios" },
      # The same Umami session two hours later is a second visit.
      { "sessionId" => "s1", "createdAt" => "2026-03-01T12:30:00.000Z", "hostname" => "blog.example.com", "urlPath" => "/blog", "eventType" => 1, "country" => "CA",
        "city" => "Toronto", "device" => "mobile", "os" => "iOS", "browser" => "ios" },
      # Visit 3: direct, desktop, the next day.
      { "sessionId" => "s2", "createdAt" => "2026-03-02T09:00:00.000Z", "hostname" => "blog.example.com", "urlPath" => "/", "eventType" => 1, "country" => "GB",
        "city" => "London", "device" => "desktop", "os" => "Mac OS", "browser" => "chrome" },
      # A performance event is not a visit.
      { "sessionId" => "s2", "createdAt" => "2026-03-02T09:00:01.000Z", "hostname" => "blog.example.com", "urlPath" => "/", "eventType" => 5, "country" => "GB",
        "city" => "London", "device" => "desktop", "os" => "Mac OS", "browser" => "chrome" },
    ]
  end

  SESSIONS = [
    { "id" => "s1", "screen" => "390x844", "language" => "en-CA", "region" => "CA-ON" },
    { "id" => "s2", "screen" => "1440x900", "language" => "en-GB", "region" => "GB-ENG" },
  ].freeze

  def harness(kind, router, now, timezone = "UTC")
    t = Harness.new(kind, { "site" => { "hostnames" => ["blog.example.com"], "timezone" => timezone }, "fetcher" => router })
    t.now = now
    t
  end

  # Runs an import to the end: { "pageviews", "events", "visits", "steps" }.
  def import_all(t, credentials = CREDENTIALS)
    cursor = nil
    totals = { "pageviews" => 0, "events" => 0, "visits" => 0, "steps" => 0 }
    loop do
      step = Visits.import_umami_visits(t.rl, "default", credentials, "w1", cursor)
      cursor = step["cursor"]
      %w[pageviews events visits].each { |k| totals[k] += step[k] }
      totals["steps"] += 1
      assert_operator step["done"], :<=, step["total"]
      break if cursor.nil?
    end
    totals
  end

  def build_all(t)
    loop { break unless t.rl.build_rollups.positive? }
  end

  on_every_database("umami visit history pageviews and events become visits with sources places and devices") do |kind|
    router = umami(fake_events, SESSIONS)
    assert_equal [{ "id" => "w1", "name" => "Blog", "domain" => "blog.example.com" }], Visits.umami_websites(CREDENTIALS, router)
    t = harness(kind, router, at("2026-03-04T00:00:00Z"))
    totals = import_all(t)
    assert_equal({ "pageviews" => 4, "events" => 1, "visits" => 3 }, totals.slice("pageviews", "events", "visits"))
    router.requests.each { |r| assert_equal "Bearer key", Router.authorization(r["init"]), "every request carries the key" }

    q = t.query("2026-03-01", "2026-03-03")
    stats = t.stats(q)
    assert_equal 4, stats["pageviews"]
    assert_equal 3, stats["visits"]
    assert_equal 2, stats["visitors"], "one Umami session on one day is one visitor"
    assert_operator stats["visitDuration"], :>, 0, "imported visits take their length from first to last pageview"
    assert_equal ["Google"], t.values(q, "source")
    assert_equal %w[CA-ON GB-ENG], t.values(q, "region").sort
    assert_equal %w[Chrome Safari], t.values(q, "browser").sort
    assert_equal ["Signup"], t.values(q, "event")
    assert_equal ["spring"], t.values(q, "utm_campaign")

    # Running it again carries on from where it stopped, so nothing doubles.
    t.advance(DAY)
    again = Visits.import_umami_visits(t.rl, "default", CREDENTIALS, "w1", nil)
    assert_equal 0, again["pageviews"]
    assert_equal 4, t.stats(q)["pageviews"]

    # No imported visitor id lasts past a day.
    days = Hash.new { |h, k| h[k] = {} }
    t.store.db.all("SELECT visitor, ts FROM rl_events").each do |r|
      days[r["visitor"]][Time.at(r["ts"].to_i / 1000).utc.strftime("%Y-%m-%d")] = true
    end
    days.each_value { |set| assert_equal 1, set.length }
  end

  def test_umami_visit_history_stops_where_runlights_own_visits_begin
    t = harness("sqlite", umami(fake_events, SESSIONS), at("2026-03-01T23:00:00Z"))
    # Runlight started counting on the evening of March 1st.
    t.rl.collect(Harness.hit("https://x.com/runlight/e", { "k" => "pageview", "u" => "https://blog.example.com/" }, { "ip" => "203.0.113.9" }))
    assert_equal 3, import_all(t)["pageviews"], "March 2nd is left to Runlight"
  end

  def test_a_step_that_failed_part_way_can_run_again_without_counting_anything_twice
    watched = WatchedDb.new(Databases.fresh("sqlite").db)
    t = harness(Runlight::Store::SqlStore.new(watched), umami(fake_events, SESSIONS), at("2026-03-04T00:00:00Z"))
    t.rl.init
    writes = 0
    watched.before = lambda do |sql, _params|
      raise "connection lost" if sql.start_with?("INSERT INTO rl_events") && (writes += 1) > 2
    end
    e = assert_raises(RuntimeError) { Visits.import_umami_visits(t.rl, "default", CREDENTIALS, "w1", nil) }
    assert_equal "connection lost", e.message
    watched.before = nil
    import_all(t)
    stats = t.stats(t.query("2026-03-01", "2026-03-03"))
    assert_equal 4, stats["pageviews"]
    assert_equal 3, stats["visits"]
    totals = t.store.db.all("SELECT SUM(pageviews) AS pageviews, SUM(events) AS events FROM rl_sessions")[0]
    assert_equal({ "pageviews" => 4, "events" => 1 }, { "pageviews" => totals["pageviews"].to_i, "events" => totals["events"].to_i })
  end

  def test_umami_visit_history_skips_days_older_than_the_site_keeps
    t = harness("sqlite", umami(fake_events, SESSIONS), at("2026-09-01T12:00:00Z"))
    t.rl.init
    # Six months back from September 1st at noon is March 1st at noon, so March 1st is left out.
    t.rl.set_retention("default", 6)
    assert_equal 1, import_all(t)["pageviews"], "only March 2nd comes in"
  end

  def test_an_unreadable_saved_progress_setting_starts_as_if_there_were_none
    t = harness("sqlite", umami(fake_events, SESSIONS), at("2026-03-04T00:00:00Z"))
    t.rl.init
    t.rl.store.set_setting("import:umami-visits:default:w1", "not a number")
    assert_equal 4, import_all(t)["pageviews"], "every day is read from the website's start"
  end

  def test_an_imported_visit_across_utc_midnight_is_one_visit_on_the_sites_own_day
    events = [
      { "sessionId" => "n1", "createdAt" => "2026-03-02T23:55:00.000Z", "hostname" => "blog.example.com", "urlPath" => "/", "eventType" => 1, "country" => "CA",
        "device" => "desktop", "os" => "Mac OS", "browser" => "chrome" },
      { "sessionId" => "n1", "createdAt" => "2026-03-03T00:05:00.000Z", "hostname" => "blog.example.com", "urlPath" => "/about", "eventType" => 1, "country" => "CA",
        "device" => "desktop", "os" => "Mac OS", "browser" => "chrome" },
    ]
    t = harness("sqlite", umami(events, [{ "id" => "n1" }], "2026-03-02T00:00:00Z", false), at("2026-03-10T00:00:00Z"), "America/Toronto")
    import_all(t)
    stats = t.stats(t.query("2026-03-02", "2026-03-02"))
    assert_equal [1, 1, 2], [stats["visits"], stats["visitors"], stats["pageviews"]]
  end

  def ev(session, iso, path, name = nil)
    e = { "sessionId" => session, "createdAt" => Time.at(at(iso) / 1000).utc.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "hostname" => "blog.example.com",
          "urlPath" => path, "eventType" => name.nil? ? 1 : 2 }
    e["eventName"] = name unless name.nil?
    e
  end

  on_every_database("an imported visit that runs past midnight keeps one visitor on all its rows") do |kind|
    events = [ev("s1", "2026-03-01T23:50:00Z", "/a"), ev("s1", "2026-03-02T00:05:00Z", "/b"), ev("s1", "2026-03-02T00:06:00Z", "/b", "Signup"),
              ev("s1", "2026-03-02T10:00:00Z", "/b"), ev("s1", "2026-03-02T10:01:00Z", "/b", "Signup")]
    t = harness(kind, umami(events, [], "2026-03-01T00:00:00.000Z"), at("2026-03-05T12:00:00Z"))
    import_all(t)
    assert_equal [], t.store.db.all("SELECT e.id FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.visitor <> s.visitor")
    q = t.query("2026-03-01", "2026-03-02")
    read = lambda do
      {
        "pages" => t.store.breakdown(q, "page", 10, 0).map { |r| [r["value"], r["visitors"]] },
        "events" => t.store.breakdown(q, "event", 10, 0).map { |r| [r["value"], r["visitors"]] },
      }
    end
    raw = read.call
    build_all(t)
    assert_equal raw, read.call, "the same before and after the days are built"
    assert_equal [["Signup", 2]], raw["events"]
  end

  on_every_database("a visit that crosses into the next import step has its first day built again") do |kind|
    events = [ev("s0", "2026-03-02T10:00:00Z", "/"), ev("s1", "2026-03-14T23:50:00Z", "/a"), ev("s1", "2026-03-15T00:10:00Z", "/b"), ev("s2", "2026-03-20T10:00:00Z", "/")]
    t = harness(kind, umami(events, [], "2026-03-01T00:00:00.000Z"), at("2026-03-25T12:00:00Z"))
    cursor = Visits.import_umami_visits(t.rl, "default", CREDENTIALS, "w1", nil)["cursor"]
    # The scheduled check builds days between two steps.
    build_all(t)
    cursor = Visits.import_umami_visits(t.rl, "default", CREDENTIALS, "w1", cursor)["cursor"] until cursor.nil?
    build_all(t)
    q = t.query("2026-03-14", "2026-03-14")
    read = -> { { "stats" => t.stats(q), "pages" => t.store.breakdown(q, "page", 10, 0).map { |r| [r["value"], r["pageviews"]] } } }
    rolled = read.call
    t.store.clear_rollups("default")
    assert_equal rolled, read.call
    assert_equal 2, rolled["stats"]["pageviews"]
  end

  def test_a_step_cursor_carries_a_sign_in_token_but_never_an_api_key
    events = [ev("s0", "2026-03-02T10:00:00Z", "/"), ev("s2", "2026-03-20T10:00:00Z", "/")]
    t = harness("sqlite", umami(events, [], "2026-03-01T00:00:00.000Z"), at("2026-03-25T12:00:00Z"))
    cursor = Json.decode(Visits.import_umami_visits(t.rl, "default", CREDENTIALS, "w1", nil)["cursor"].to_s)
    assert_equal %w[website day start end], cursor.keys
    assert_equal at("2026-03-15T00:00:00Z"), cursor["day"], "fourteen days a step"
    e = assert_raises(Runlight::Importers::ImportError) { Visits.import_umami_visits(t.rl, "default", CREDENTIALS, "w/1", nil) }
    assert_equal "import_website", e.code
  end

  # CSV

  RUNLIGHT_ROWS = [
    { "time" => "2026-03-01T10:00:00Z", "url" => "https://blog.example.com/?utm_campaign=spring", "referrer" => "www.google.com", "visitor" => "a", "country" => "CA",
      "region" => "CA-ON", "city" => "Toronto", "browser" => "Safari", "os" => "iOS", "device" => "mobile", "title" => "Home" },
    { "time" => "2026-03-01T10:02:00Z", "url" => "https://blog.example.com/pricing", "visitor" => "a", "country" => "CA", "browser" => "Safari", "os" => "iOS",
      "device" => "mobile" },
    { "time" => "2026-03-01T10:03:00Z", "url" => "https://blog.example.com/pricing", "event" => "Signup", "visitor" => "a" },
    { "time" => "1772442000", "path" => "/", "hostname" => "blog.example.com", "visitor" => "b", "country" => "GB", "browser" => "Chrome", "os" => "macOS",
      "device" => "desktop" },
    # Not a time at all.
    { "time" => "yesterday", "path" => "/x", "visitor" => "c" },
  ].freeze

  def csv(now = 0)
    t = Harness.new("sqlite", { "site" => { "hostnames" => ["blog.example.com"], "timezone" => "UTC" } })
    t.now = now.zero? ? at("2026-03-04T00:00:00Z") : now
    t
  end

  def test_csv_in_runlights_format_rows_become_visits_with_sources_places_devices_and_events
    t = csv
    assert_equal({ "pageviews" => 3, "events" => 1, "visits" => 2, "skipped" => 1 }, Visits.import_csv_visits(t.rl, "default", RUNLIGHT_ROWS))
    q = t.query("2026-03-01", "2026-03-03")
    stats = t.stats(q)
    assert_equal [3, 2, 2], [stats["pageviews"], stats["visits"], stats["visitors"]]
    assert_equal ["Google"], t.values(q, "source")
    assert_equal ["spring"], t.values(q, "utm_campaign")
    assert_equal ["Signup"], t.values(q, "event")
    assert_equal %w[desktop mobile], t.values(q, "device").sort
    assert_equal ["CA-ON"], t.values(q, "region")

    # The same file again replaces what it brought in, so nothing doubles.
    Visits.import_csv_visits(t.rl, "default", RUNLIGHT_ROWS)
    assert_equal 3, t.stats(q)["pageviews"]
    assert_equal 2, t.stats(q)["visits"]
  end

  def test_csv_in_runlights_format_without_a_visitor_column_every_row_is_its_own_visit
    t = csv
    rows = [{ "time" => "2026-03-01 10:00:00", "path" => "/a" }, { "time" => "2026-03-01 10:01:00", "path" => "/b?ref=x" }]
    assert_equal 2, Visits.import_csv_visits(t.rl, "default", rows)["visits"]
    Visits.import_csv_visits(t.rl, "default", rows)
    q = t.query("2026-03-01", "2026-03-03")
    assert_equal 2, t.stats(q)["visits"], "the same rows get the same ids the second time"
    assert_equal ["/a", "/b"], t.values(q, "page").sort
  end

  def test_csv_from_umamis_export_pageviews_and_named_events_come_across_other_event_types_do_not
    t = csv
    rows = [
      { "website_id" => "w1", "session_id" => "s1", "created_at" => "2026-03-01 10:00:00", "hostname" => "blog.example.com", "url_path" => "/", "url_query" => "",
        "referrer_domain" => "news.ycombinator.com", "page_title" => "Home", "event_type" => "1", "country" => "CA", "subdivision1" => "ON", "city" => "Toronto",
        "browser" => "ios", "os" => "iOS", "device" => "mobile", "screen" => "390x844", "language" => "en-CA" },
      { "website_id" => "w1", "session_id" => "s1", "created_at" => "2026-03-01 10:03:00", "hostname" => "blog.example.com", "url_path" => "/pricing",
        "event_type" => "2", "event_name" => "Signup" },
      { "website_id" => "w1", "session_id" => "s1", "created_at" => "2026-03-01 10:03:01", "hostname" => "blog.example.com", "url_path" => "/pricing",
        "event_type" => "5" },
      { "website_id" => "w1", "session_id" => "s2", "created_at" => "2026-03-02T09:00:00.000Z", "hostname" => "blog.example.com", "url_path" => "/blog",
        "event_type" => "1", "country" => "GB", "browser" => "chrome", "os" => "Mac OS", "device" => "desktop" },
    ]
    assert_equal({ "pageviews" => 2, "events" => 1, "visits" => 2, "skipped" => 1 }, Visits.import_csv_visits(t.rl, "default", rows))
    q = t.query("2026-03-01", "2026-03-03")
    assert_equal ["Hacker News"], t.values(q, "source")
    assert_equal ["CA-ON"], t.values(q, "region")
    assert_equal %w[Chrome Safari], t.values(q, "browser").sort
  end

  def test_csv_rows_from_after_runlights_own_first_visit_are_left_to_runlight
    t = csv(at("2026-03-01T23:00:00Z"))
    t.rl.collect(Harness.hit("https://x.com/runlight/e", { "k" => "pageview", "u" => "https://blog.example.com/" }, { "ip" => "203.0.113.9" }))
    step = Visits.import_csv_visits(t.rl, "default", RUNLIGHT_ROWS[0, 4])
    assert_equal 2, step["pageviews"], "March 2nd is left to Runlight"
    assert_equal 1, step["skipped"]
  end

  def test_a_csv_it_cannot_read_and_a_batch_that_is_too_big_are_refused
    t = csv
    [[[{ "date" => "2026-03-01", "visitors" => "12" }], "import_csv_format"], [Array.new(2001, RUNLIGHT_ROWS[0]), "import_csv_batch"],
     ["not rows", "import_csv_batch"]].each do |rows, code|
      e = assert_raises(Runlight::Importers::ImportError) { Visits.import_csv_visits(t.rl, "default", rows) }
      assert_equal code, e.code
    end
    assert_equal 2, Visits.import_csv_visits(t.rl, "default", RUNLIGHT_ROWS)["visits"]
  end

  def test_csv_times_and_formats
    assert_equal "umami", CsvVisits.csv_format(%w[created_at url_path session_id])
    assert_equal "runlight", CsvVisits.csv_format(%w[time url])
    assert_nil CsvVisits.csv_format(%w[date visitors])
    iso = at("2026-03-01T10:00:00Z")
    assert_equal iso, CsvVisits.row_time({ "time" => "2026-03-01 10:00:00" }, "runlight"), "no zone reads as UTC"
    assert_equal iso, CsvVisits.row_time({ "time" => "2026-03-01T12:00:00+02:00" }, "runlight")
    assert_equal iso, CsvVisits.row_time({ "time" => (iso / 1000).to_s }, "runlight"), "Unix seconds"
    assert_equal iso, CsvVisits.row_time({ "time" => iso.to_s }, "runlight"), "Unix milliseconds"
    assert_equal iso, CsvVisits.row_time({ "created_at" => "2026-03-01 10:00:00" }, "umami")
    assert CsvVisits.row_time({ "time" => "" }, "runlight").nan?
    assert CsvVisits.row_time({ "time" => "yesterday" }, "runlight").nan?
  end
end
