# frozen_string_literal: true

# Visits written through the store as the tracker writes them (a session, then its rows, each counted into
# the session), for store tests that do not go through the core and its routes.
module Seed
  DAY = 86_400_000
  HOUR = 3_600_000
  MIN = 60_000

  module_function

  # Milliseconds since the epoch for a UTC date and time.
  def utc(year, month, day, hour = 0)
    Time.utc(year, month, day, hour).to_i * 1000
  end

  # A session with its fields, then its rows in order. A row is one of:
  # ["pageview", path, ts, pageview_id] (optional fifth: hostname),
  # ["event", name, ts, props or nil] (optional fifth: path),
  # ["engagement", pageview_id, ts, ms, scroll or nil].
  def visit(store, id, visitor, started_at, fields = {}, rows = [], site = "default")
    store.insert_session({
      "id" => id, "site" => site, "visitor" => visitor, "startedAt" => started_at, "hostname" => "example.com", "referrerHost" => "", "referrerPath" => "",
      "source" => "", "channel" => "Direct", "utmSource" => "", "utmMedium" => "", "utmCampaign" => "", "utmTerm" => "", "utmContent" => "",
      "country" => "", "region" => "", "city" => "", "browser" => "Chrome", "browserVersion" => "129", "os" => "macOS", "osVersion" => "", "device" => "Desktop",
      "screen" => "", "language" => "en",
    }.merge(fields))
    paths = {}
    last = "/"
    rows.each do |row|
      event = { "site" => site, "visitor" => visitor, "session" => id, "pageview" => "", "path" => last, "hostname" => fields["hostname"] || "example.com",
                "title" => "", "name" => "", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => "" }
      case row[0]
      when "pageview"
        _, path, ts, pv = row
        paths[pv] = path
        last = path
        store.insert_event(event.merge("ts" => ts, "kind" => "pageview", "pageview" => pv, "path" => path, "hostname" => row[4] || event["hostname"], "title" => "Title #{path}"[0, 500]))
        store.touch_session(id, ts, "pageview", path)
      when "event"
        _, name, ts, props = row
        store.insert_event(event.merge("ts" => ts, "kind" => "event", "name" => name, "props" => props, "path" => row[4] || last))
        store.touch_session(id, ts, "event", row[4] || last)
      else
        _, pv, ts, ms, scroll = row
        store.insert_event(event.merge("ts" => ts, "kind" => "engagement", "pageview" => pv, "path" => paths[pv] || last, "engagedMs" => ms, "scroll" => scroll))
        store.add_engagement(id, ms)
      end
    end
  end

  # A site's days built as the core builds them, a UTC day at a time, for every whole day before `before`
  # that has a visit.
  def build_days(store, site, from, before)
    built = 0
    day = from / DAY * DAY
    while day + DAY <= before
      store.build_rollup_day(site, Time.at(day / 1000).utc.strftime("%Y-%m-%d"), day, day + DAY)
      built += 1
      day += DAY
    end
    built
  end

  # A database with a bit of everything, written through the Ruby store, and the reads to compare over it:
  # [{"method" => TypeScript name, "args" => [...]}].
  def everything(store)
    store.migrate
    now = utc(2026, 10, 6, 12)
    store.upsert_site({ "id" => "default", "name" => "Example", "hostnames" => ["example.com"], "timezone" => "UTC" }, now)
    store.upsert_site({ "id" => "b", "name" => "Bee", "hostnames" => [], "timezone" => "Asia/Tokyo" }, now)
    store.set_site_overrides("b", { "name" => "Renamed" })
    pages = ["/", "/pricing", "/blog/one", "/caf%C3%A9", "/%C3%9Cber-uns", "/thanks", "/#/cart"]
    countries = %w[GB US DE FR]
    campaigns = ["alpha", "Zeta", "émile", "Émile", "a-b", "ab", ""]
    n = 0
    9.downto(0) do |day|
      5.times do |v|
        n += 1
        start = now - day * DAY - 10 * HOUR + v * 2 * HOUR + n * 1000
        rows = []
        t = start
        (1 + n % 3).times do |p|
          rows << ["pageview", pages[(n + p) % pages.length], t, "pv#{n}x#{p}"]
          rows << ["engagement", "pv#{n}x#{p}", t + 5000, 8000 + n * 100, n % 3 != 0 ? 30 + n % 50 : nil] if n.even?
          rows << ["event", "Signup", t + 6000, { "plan" => n.odd? ? "pro" : "team", "amount" => "#{5 + n % 4}.5" }] if (n % 3).zero?
          t += 30_000
        end
        visit(store, "s#{n}", "v#{n % 17}", start, {
          "country" => countries[n % 4], "source" => n.odd? ? "Google" : "", "channel" => n.odd? ? "Search" : "Direct",
          "utmCampaign" => campaigns[n % campaigns.length], "device" => n % 3 != 0 ? "Desktop" : "Mobile", "browser" => n % 4 != 0 ? "Chrome" : "Safari",
        }, rows)
      end
    end
    store.save_goal({ "id" => "a" * 24, "site" => "default", "name" => "Signup", "kind" => "event", "match" => "Signup", "clickBy" => "", "valueMode" => "prop", "value" => 0, "valueProp" => "amount", "currency" => "USD", "createdAt" => now })
    store.save_goal({ "id" => "b" * 24, "site" => "default", "name" => "Thanks", "kind" => "page", "match" => "/th*", "clickBy" => "", "valueMode" => "fixed", "value" => 4.25, "valueProp" => "", "currency" => "EUR", "createdAt" => now })
    store.save_goal({ "id" => "c" * 24, "site" => "default", "name" => "Cart", "kind" => "page", "match" => "/#/cart", "clickBy" => "", "valueMode" => "none", "value" => 0, "valueProp" => "", "currency" => "USD", "createdAt" => now })
    store.save_funnel({ "id" => "f" * 24, "site" => "default", "name" => "F", "steps" => [{ "kind" => "page", "match" => "/" }, { "kind" => "page", "match" => "/pricing" }, { "kind" => "event", "match" => "Signup" }], "createdAt" => now })
    store.insert_link({ "id" => "l" * 24, "site" => "default", "domain" => "", "slug" => "go", "name" => "Go", "url" => "https://example.com/", "createdAt" => now - DAY, "updatedAt" => now - DAY })
    store.add_link_domain("go.example.com", "default", now)
    6.times do |i|
      store.insert_event({ "site" => "default", "ts" => now - i * 7 * HOUR, "kind" => "click", "visitor" => i.odd? ? "cv#{i}" : "", "session" => "", "pageview" => "", "path" => "", "hostname" => "", "title" => "", "name" => "", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => "l" * 24 })
      store.insert_event({ "site" => "default", "ts" => now - i * 5 * HOUR, "kind" => "fetch", "visitor" => "", "session" => "", "pageview" => "", "path" => pages[i % 3], "hostname" => "example.com", "title" => "", "name" => i.odd? ? "GPTBot" : "ClaudeBot", "props" => { "company" => "X" }, "engagedMs" => 0, "scroll" => nil, "link" => "" })
    end
    store.insert_share({ "id" => "s" * 24, "site" => "default", "name" => "Client", "createdAt" => now })
    store.insert_token({ "id" => "k" * 24, "name" => "Script", "site" => "", "scope" => "manage", "hash" => "h" * 64, "hint" => "abcd", "createdAt" => now, "lastUsedAt" => nil })
    store.insert_report({ "id" => "r" * 24, "site" => "default", "email" => "a@example.com", "frequency" => "weekly", "lang" => "en", "token" => "q" * 32, "origin" => "", "lastPeriod" => "", "lastSentAt" => nil, "createdAt" => now })
    store.set_setting("remote:a", "1")
    store.salt("2026-10-06", "9" * 64)
    build_days(store, "default", now - 7 * DAY, now - 3 * DAY)

    calls = []
    add = ->(method, *args) { calls << { "method" => method, "args" => args } }
    add.call("sites")
    add.call("siteOverrides")
    add.call("rollupDays", "default")
    filters = [
      [], [{ "dimension" => "country", "op" => "is", "value" => "GB" }], [{ "dimension" => "page", "op" => "contains", "value" => "über" }],
      [{ "dimension" => "event", "op" => "not", "value" => "Signup" }], [{ "dimension" => "utm_campaign", "op" => "contains", "value" => "ÉMILE" }]
    ]
    [[now - 8 * DAY, now + DAY], [now - 5 * DAY - 3 * HOUR, now - DAY]].each do |from, to|
      filters.each do |f|
        query = { "site" => "default", "from" => from, "to" => to, "filters" => f }
        add.call("stats", query)
        add.call("hourly", query)
        %w[page hostname event entry exit source channel utm_campaign country device browser ai_agent ai_page].each do |dimension|
          add.call("breakdown", query, dimension, 5, 0)
        end
        add.call("goalTotalsAll", query, store.goals("default"))
        add.call("funnelCounts", query, store.funnels("default")[0])
        add.call("journeyPages", query, 3)
        add.call("eventPropKeys", query, "Signup")
        add.call("eventPropValues", query, "Signup", "plan", 5)
        store.goals("default").each { |g| add.call("goalBreakdown", query, g, "path", 5) }
      end
      add.call("links", "default", from, to)
    end
    buckets = Array.new(12) { |i| { "start" => now - (11 - i) * DAY, "end" => now - (10 - i) * DAY } }
    filters.each do |f|
      add.call("series", { "site" => "default", "filters" => f }, buckets)
      add.call("goalSeries", { "site" => "default", "filters" => f }, store.goals("default")[0], buckets)
    end
    add.call("linkSeries", "default", "l" * 24, buckets)
    add.call("realtime", "default", now - 9 * HOUR)
    add.call("goals")
    add.call("funnels", "default")
    add.call("linkBySlug", "go")
    add.call("linkDomains")
    add.call("shares", "default")
    add.call("tokens")
    add.call("reports")
    add.call("settingsStartingWith", "remote:")
    add.call("saltIfExists", "2026-10-06")
    add.call("pageview", "default", "pv3x1")
    calls
  end
end
