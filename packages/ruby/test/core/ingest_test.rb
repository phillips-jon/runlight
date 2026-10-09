# frozen_string_literal: true

require "tmpdir"
require "test_helper"
require_relative "../support/core_test_case"
require_relative "../support/watched_db"

# The tracker endpoint's work, as ingest.test.ts, audit.test.ts, and hardening.test.ts test it, read back from the store.
class CoreIngestTest < CoreTestCase
  Request = Runlight::Http::Request
  Json = Runlight::Json

  on_every_database("a visit pageviews an event engagement and the reports that follow") do |kind|
    t = Harness.new(kind)
    t.track({ "k" => "pageview", "u" => "https://example.com/?utm_source=chatgpt.com", "r" => "https://chatgpt.com/", "i" => "pv1", "t" => "Home", "w" => 1440, "h" => 900, "l" => "en-GB" }, {
      "headers" => { "x-vercel-ip-country" => "GB", "x-vercel-ip-country-region" => "ENG", "x-vercel-ip-city" => "London" },
    })
    t.advance(20_000)
    t.track({ "k" => "engagement", "u" => "https://example.com/", "i" => "pv1", "e" => 18_000, "d" => 75 })
    t.track({ "k" => "pageview", "u" => "https://example.com/pricing", "r" => "https://example.com/", "i" => "pv2", "w" => 1440, "h" => 900 })
    t.advance(5_000)
    t.track({ "k" => "event", "u" => "https://example.com/pricing", "i" => "pv2", "n" => "Signup", "p" => { "plan" => "pro" } })

    # A second visitor on a phone who bounces.
    t.track({ "k" => "pageview", "u" => "https://example.com/blog/post", "r" => "https://news.ycombinator.com/", "i" => "pv3", "w" => 390, "h" => 844 }, { "ua" => Harness::SAFARI_IPHONE, "ip" => "198.51.100.7" })
    t.track({ "k" => "engagement", "u" => "https://example.com/blog/post", "i" => "pv3", "e" => 4_000 }, { "ua" => Harness::SAFARI_IPHONE, "ip" => "198.51.100.7" })

    today = t.today
    assert_equal Json.encode({ "visitors" => 2, "visits" => 2, "pageviews" => 3, "viewsPerVisit" => 1.5, "bounceRate" => 0.5, "visitDuration" => 11_000 }), Json.encode(t.stats(today))
    assert_equal [
      { "value" => "AI", "visitors" => 1, "visits" => 1, "pageviews" => 2, "bounceRate" => 0, "visitDuration" => 18_000 },
      { "value" => "Social", "visitors" => 1, "visits" => 1, "pageviews" => 1, "bounceRate" => 1, "visitDuration" => 4_000 },
    ], t.store.breakdown(today, "channel", 10, 0)
    assert_equal ["ChatGPT", "Hacker News"], t.values(today, "source")
    assert_equal ["GB"], t.values(today, "country")
    assert_equal ["GB-ENG"], t.values(today, "region")
    assert_equal %w[desktop mobile], t.values(today, "device").sort
    assert_equal %w[1440x900 390x844], t.values(today, "screen").sort
    assert_equal [{ "value" => "Signup", "visitors" => 1, "events" => 1 }], t.store.breakdown(today, "event", 10, 0)
    home = t.store.breakdown(today, "page", 10, 0).find { |p| p["value"] == "/" }
    assert_equal({ "value" => "/", "visitors" => 1, "pageviews" => 1, "timeOnPage" => 18_000, "scrollDepth" => 75 }, home)
    props = Json.decode(t.store.db.all("SELECT props FROM rl_events WHERE kind = 'event'")[0]["props"].to_s)
    assert_equal({ "plan" => "pro" }, props)

    live = t.store.realtime("default", t.now)
    assert_equal 2, live["visitors"]
    assert_equal 4, live["recent"].length, "three pageviews and an event"
  end

  on_every_database("thirty idle minutes start a new session and a new day is a new visitor") do |kind|
    t = Harness.new(kind)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "a1" })
    t.advance(29 * MIN)
    t.track({ "k" => "pageview", "u" => "https://example.com/a", "i" => "a2" })
    t.advance(31 * MIN)
    t.track({ "k" => "pageview", "u" => "https://example.com/b", "i" => "a3" })
    stats = t.stats(t.today)
    assert_equal 2, stats["visits"]
    assert_equal 1, stats["visitors"]

    t.advance(24 * 60 * MIN)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "a4" })
    assert_equal 2, t.stats(t.query("2026-10-01", "2026-10-07"))["visitors"], "the same person on another day is counted again"
  end

  on_every_database("a session that runs past midnight utc stays one session") do |kind|
    t = Harness.new(kind)
    t.advance((11 * 60 * MIN) + (50 * MIN))
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "m1" })
    t.advance(20 * MIN)
    t.track({ "k" => "pageview", "u" => "https://example.com/next", "i" => "m2" })
    stats = t.stats(t.query("2026-10-01", "2026-10-07"))
    assert_equal 1, stats["visits"]
    assert_equal 2, stats["pageviews"]
  end

  on_every_database("a salt is deleted once its day has ended everywhere") do |kind|
    t = Harness.new(kind)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "s1" })
    3.times do |i|
      t.advance(24 * 60 * MIN)
      t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "s#{i + 2}" })
    end
    t.rl.check
    # October 9th at noon UTC: the earliest timezone is on the 8th and still needs the 7th.
    days = t.store.db.all("SELECT day FROM rl_salts ORDER BY day").map { |r| r["day"].to_s }
    assert_equal %w[2026-10-07 2026-10-08 2026-10-09], days
  end

  on_every_database("a visitor is one visitor for the whole of the sites own day") do |kind|
    # Toronto: 11pm on the 6th and 1am on the 7th UTC are both the evening of October 6th.
    t = Harness.new(kind, { "site" => { "timezone" => "America/Toronto" } })
    t.advance(11 * 60 * MIN)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "t1" })
    t.advance(2 * 60 * MIN)
    t.track({ "k" => "pageview", "u" => "https://example.com/later", "i" => "t2" })
    stats = t.stats(t.query("2026-10-06", "2026-10-06"))
    assert_equal 2, stats["visits"], "two hours apart is two visits"
    assert_equal 1, stats["visitors"], "but one visitor, since it is the same day in Toronto"
  end

  on_every_database("nothing identifying is stored") do |kind|
    t = Harness.new(kind)
    t.track({ "k" => "pageview", "u" => "https://example.com/?email=jane@example.org&utm_campaign=x", "i" => "p1" }, { "ip" => "192.0.2.55" })
    dump = Json.encode([t.store.db.all("SELECT * FROM rl_sessions"), t.store.db.all("SELECT * FROM rl_events")])
    refute_includes dump, "192.0.2.55", "no IP"
    refute_includes dump, "jane@example.org", "no query string"
    refute_includes dump, "AppleWebKit", "no user agent"
  end

  on_every_database("bots ai agents junk and other sites are dropped quietly") do |kind|
    t = Harness.new(kind, { "site" => { "hostnames" => ["example.com"] } })
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "b1" }, { "ua" => "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" })
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "b2" }, { "ua" => "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2)" })
    t.track({ "k" => "pageview", "u" => "https://elsewhere.net/", "i" => "b3" })
    t.track({ "k" => "pageview", "u" => "javascript:alert(1)" })
    t.track({ "k" => "nonsense", "u" => "https://example.com/" })
    t.track({ "k" => "event", "u" => "https://example.com/" })
    t.rl.collect(Request.new("https://example.com/runlight/e", method: "POST", headers: { "user-agent" => Harness::CHROME_MAC }, body: "{not json"))
    # Too long, whatever the length header says.
    t.rl.collect(Request.new("https://example.com/runlight/e", method: "POST", headers: { "user-agent" => Harness::CHROME_MAC },
                                                               body: Json.encode({ "k" => "pageview", "u" => "https://example.com/", "t" => "x" * 9000 })))
    t.rl.collect(Request.new("https://example.com/runlight/e", method: "POST", headers: { "user-agent" => Harness::CHROME_MAC, "content-length" => "99999" },
                                                               body: Json.encode({ "k" => "pageview", "u" => "https://example.com/" })))
    assert_equal 0, t.stats(t.today)["pageviews"]
  end

  on_every_database("ai agents are recorded as fetches by observe") do |kind|
    t = Harness.new(kind)
    fetch = ->(path, ua) { t.rl.observe(Request.new("https://example.com#{path}", headers: { "user-agent" => ua, "host" => "example.com" })) }
    assert fetch.call("/blog/post", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ChatGPT-User/1.0; +https://openai.com/bot")
    assert fetch.call("/blog/post", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)")
    refute fetch.call("/logo.png", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)")
    refute fetch.call("/", Harness::CHROME_MAC)
    today = t.today
    assert_equal [{ "value" => "ChatGPT-User", "visitors" => 0, "fetches" => 1 }, { "value" => "ClaudeBot", "visitors" => 0, "fetches" => 1 }],
                 t.store.breakdown(today, "ai_agent", 10, 0)
    assert_equal [{ "value" => "/blog/post", "visitors" => 0, "fetches" => 2 }], t.store.breakdown(today, "ai_page", 10, 0)
    assert_equal 0, t.stats(today)["visitors"], "fetches are not visits"
    # A log reader's time: older than a week is dropped, ahead of now counts as now.
    ua = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)"
    refute t.rl.observe(Request.new("https://example.com/old", headers: { "user-agent" => ua }), t.now - (8 * DAY))
    assert t.rl.observe(Request.new("https://example.com/later", headers: { "user-agent" => ua }), t.now + DAY)
    assert_equal t.now, t.store.db.all("SELECT ts FROM rl_events WHERE path = '/later'")[0]["ts"].to_i
  end

  on_every_database("several sites in one install told apart by hostname") do |kind|
    t = Harness.new(kind, { "sites" => [{ "id" => "brand-a", "hostnames" => ["brand-a.com"] }, { "id" => "brand-b", "hostnames" => ["brand-b.com"], "timezone" => "America/Toronto" }] })
    t.track({ "k" => "pageview", "u" => "https://www.brand-a.com/", "i" => "x1" })
    t.track({ "k" => "pageview", "u" => "https://brand-b.com/", "i" => "x2" })
    t.track({ "k" => "pageview", "u" => "https://brand-b.com/two", "i" => "x3" })
    assert_equal 1, t.stats(t.today("brand-a"))["pageviews"]
    assert_equal 2, t.stats(t.today("brand-b"))["pageviews"]
    assert_equal 2, t.rl.sites.length
    assert_nil t.rl.site("brand-c")
  end

  on_every_database("a visitors pageview and events make one session") do |kind|
    t = Harness.new(kind)
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "p1" })
    t.track({ "k" => "event", "u" => "https://example.com/", "n" => "Signup", "i" => "p1" })
    t.track({ "k" => "event", "u" => "https://example.com/", "n" => "Clicked" })
    stats = t.stats(t.today)
    assert_equal 1, stats["visits"]
    assert_equal 1, stats["visitors"]
  end

  on_every_database("a managed install counts the first hit it gets before anything else has loaded its sites") do |kind|
    store = Databases.fresh(kind)
    first = Runlight::Core.new({ "store" => store, "managedSites" => true })
    first.add_site({ "hostnames" => "blog.example.com" })
    cold = Runlight::Core.new({ "store" => store, "managedSites" => true, "now" => -> { Harness::START } })
    cold.collect(Harness.hit("https://stats.example.com/runlight/e", { "k" => "pageview", "u" => "https://blog.example.com/" }, { "ip" => "203.0.113.4" }))
    assert_equal 1, store.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'")[0]["n"].to_i
  end

  def test_a_region_name_from_a_location_database_is_kept_readable_and_a_code_stays_a_code
    names = {
      "203.0.113.1" => { "country" => "ca", "region" => "Ontario", "city" => "Toronto" },
      "203.0.113.2" => { "country" => "GB", "region" => "ENG", "city" => "London" },
    }
    t = Harness.new("sqlite", { "geo" => ->(ip) { names[ip] } })
    names.each_key do |ip|
      t.rl.collect(Harness.hit("https://x.com/runlight/e", { "k" => "pageview", "u" => "https://x.com/" }, { "ua" => "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "ip" => ip }))
    end
    assert_equal %w[CA-Ontario GB-ENG], t.values(t.today, "region").sort
  end

  def test_tracker_requests_over_the_per_address_limit_are_dropped_until_the_next_minute
    t = Harness.new("sqlite", { "site" => { "hostnames" => ["example.com"] }, "rateLimit" => 3 })
    hit = lambda do |ip, n|
      t.rl.collect(Harness.hit("https://example.com/runlight/e", { "k" => "pageview", "u" => "https://example.com/#{n}" }, { "ua" => "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "ip" => ip }))
    end
    ip = "203.0.113.7"
    5.times { |n| hit.call(ip, n) }
    hit.call("198.51.100.7", 9)
    views = -> { t.store.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'")[0]["n"].to_i }
    assert_equal 4, views.call, "three from the busy address, one from the other"
    t.advance(60_000)
    hit.call(ip, 7)
    assert_equal 5, views.call, "a new minute starts a new count"
  end

  # A clock given in code names minutes that other runs replay too (the conformance scenarios play the same ones
  # on every database, and again on every run), so counts kept in the shared temporary folder carried one run's
  # hits into the next and dropped hits the limit allows.
  def test_a_core_on_a_clock_given_in_code_counts_the_rate_limit_on_its_own
    2.times do |run|
      t = Harness.new("sqlite", { "site" => { "hostnames" => ["example.com"] }, "rateLimit" => 3 })
      t.rl.init
      3.times do |n|
        t.rl.collect(Harness.hit("https://example.com/runlight/e", { "k" => "pageview", "u" => "https://example.com/#{n}" }, { "ua" => "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "ip" => "203.0.113.8" }))
      end
      views = t.store.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'")[0]["n"].to_i
      assert_equal 3, views, "run #{run + 1} counts its own three"
    end
  end

  def test_the_rate_limit_shares_its_counts_between_processes_through_the_folder
    Dir.mktmpdir do |dir|
      clock = -> { 1_791_280_800_000 }
      first = Runlight::RateLimit.new(2, clock, dir)
      second = Runlight::RateLimit.new(2, clock, dir)
      assert first.allow("203.0.113.9")
      assert second.allow("203.0.113.9")
      refute first.allow("203.0.113.9"), "the third in the minute, counted across both"
      apart = Runlight::RateLimit.new(2, clock, dir, shared: false)
      assert apart.allow("203.0.113.9"), "one kept in its process counts on its own"
    end
  end

  def test_a_tracker_hit_that_finds_the_database_busy_is_tried_again_at_the_time_it_arrived
    watched = WatchedDb.new(Databases.fresh("sqlite").db)
    t = Harness.new(Runlight::Store::SqlStore.new(watched), { "site" => { "hostnames" => ["example.com"], "timezone" => "UTC" } })
    t.rl.init
    refused = 0
    watched.before = lambda do |sql, _params|
      if refused < 2 && sql.include?("FROM rl_sessions WHERE site = ? AND visitor IN")
        refused += 1
        raise "timeout exceeded when trying to connect"
      end
    end
    arrived = t.now
    t.track({ "k" => "pageview", "u" => "https://example.com/", "i" => "busy" })
    watched.before = nil
    assert_equal 2, refused
    assert_equal 1, t.stats(t.today)["pageviews"]
    assert_equal arrived, t.store.db.all("SELECT ts FROM rl_events")[0]["ts"].to_i
  end

  def test_a_local_test_counts_while_a_site_is_being_set_up_and_local_traffic_is_ignored_after_its_first_visit
    t = Harness.new("sqlite", { "site" => { "hostnames" => ["example.com"] } })
    hit = ->(url) { t.rl.collect(Harness.hit("https://x.com/runlight/e", { "k" => "pageview", "u" => url }, { "ip" => "203.0.113.5" })) }
    views = -> { t.stats(t.today)["pageviews"] }
    hit.call("http://localhost:3000/")
    assert_equal 1, views.call, "the first local test shows up"
    hit.call("http://localhost:3000/again")
    hit.call("http://myapp.test/")
    assert_equal 1, views.call, "after that, local hits are ignored"
    hit.call("https://example.com/")
    assert_equal 2, views.call
  end

  def test_the_client_address_comes_from_the_header_trusted_or_the_connection
    request = ->(headers) { Request.new("https://example.com/", headers: headers, remote_address: "192.0.2.9") }
    store = Runlight::Stores.sqlite(":memory:")
    default = Runlight::Core.new({ "store" => store })
    assert_equal "198.51.100.2", default.client_ip(request.call({ "x-forwarded-for" => "203.0.113.1, 198.51.100.2" })), "the last entry, which the nearest proxy wrote"
    assert_equal "203.0.113.3", default.client_ip(request.call({ "x-real-ip" => "203.0.113.3" }))
    assert_equal "203.0.113.4", default.client_ip(request.call({ "cf-connecting-ip" => "203.0.113.4" }))
    assert_equal "192.0.2.9", default.client_ip(request.call({})), "the connection, with no header"
    assert_equal "192.0.2.1", default.client_ip(request.call({}), { "ip" => "192.0.2.1" }), "the context names the connection"
    off = Runlight::Core.new({ "store" => store, "trustProxy" => false })
    assert_equal "192.0.2.9", off.client_ip(request.call({ "x-forwarded-for" => "203.0.113.1" }))
    cf = Runlight::Core.new({ "store" => store, "trustProxy" => "cf-connecting-ip" })
    assert_equal "203.0.113.4", cf.client_ip(request.call({ "x-forwarded-for" => "203.0.113.1", "cf-connecting-ip" => "203.0.113.4" }))
    assert_equal "192.0.2.9", cf.client_ip(request.call({ "x-forwarded-for" => "203.0.113.1" }))
  end

  def test_options_are_checked_as_ts_checks_them
    store = Runlight::Stores.sqlite(":memory:")
    [
      [{ "site" => { "timezone" => "Mars/Base" } }, "unknown timezone"],
      [{ "site" => { "id" => "has space" } }, "must be letters"],
      [{ "sites" => [{ "id" => "a", "hostnames" => ["a.com"] }, { "id" => "b" }] }, "give each one its hostnames"],
      [{ "sites" => [{ "id" => "a", "hostnames" => ["a.com"] }, { "id" => "a", "hostnames" => ["b.com"] }] }, "share an id"],
    ].each do |options, error|
      e = assert_raises(ArgumentError, "accepted #{error}") { Runlight::Core.new({ "store" => store }.merge(options)) }
      assert_includes e.message, error
    end
    rl = Runlight::Core.new({ "store" => store, "site" => { "hostnames" => ["www.Example.com"] }, "linkPath" => "//links/" })
    assert_equal "/links", rl.link_path
    assert_equal [{ "id" => "default", "name" => "www.Example.com", "hostnames" => ["example.com"], "timezone" => "UTC" }], rl.sites
  end

  def test_ruby_callers_may_pass_options_as_symbols_in_snake_case
    rl = Runlight.new(store: Runlight::Stores.sqlite(":memory:"), site: { name: "Example", hostnames: ["example.com"] },
                      link_path: "/links", rate_limit: false, trust_proxy: false)
    assert_instance_of Runlight::Core, rl
    assert_equal "/links", rl.link_path
    assert_equal [{ "id" => "default", "name" => "Example", "hostnames" => ["example.com"], "timezone" => "UTC" }], rl.sites
    assert_equal "192.0.2.9", rl.client_ip(Request.new("https://example.com/", headers: { "x-forwarded-for" => "203.0.113.1" }, remote_address: "192.0.2.9"))
  end
end
