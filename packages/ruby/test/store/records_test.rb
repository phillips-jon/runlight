# frozen_string_literal: true

require "test_helper"
require_relative "../support/store_test_case"

# Sites, links, shares, tokens, reports, settings, salts, and the live view, at the store, on every database.
class StoreRecordsTest < StoreTestCase
  on_each "sites_are_kept_with_their_overrides_and_a_deleted_sites_records_go_with_it" do |kind|
    store = store(kind)
    store.upsert_site({ "id" => "shop", "name" => "Shop", "hostnames" => ["shop.example.com", "store.example.com"], "timezone" => "Europe/London" }, NOW)
    # Unchanged, it is left alone; changed, it is updated, keeping when it was made.
    store.upsert_site({ "id" => "shop", "name" => "Shop", "hostnames" => ["shop.example.com", "store.example.com"], "timezone" => "Europe/London" }, NOW + 1)
    store.upsert_site({ "id" => "shop", "name" => "A shop", "hostnames" => ["shop.example.com"], "timezone" => "Europe/London" }, NOW + 2)
    assert_equal [
      { "id" => "shop", "name" => "A shop", "hostnames" => ["shop.example.com"], "timezone" => "Europe/London" },
      { "id" => "default", "name" => "Example", "hostnames" => ["example.com"], "timezone" => "UTC" },
    ], store.sites
    assert_equal [NOW], store.db.all("SELECT created_at FROM rl_sites WHERE id = 'shop'").map { |r| Integer(r["created_at"]) }
    store.set_site_overrides("shop", { "name" => "Renamed", "timezone" => "Asia/Tokyo" })
    store.set_site_overrides("default", {})
    assert_equal({ "default" => {}, "shop" => { "name" => "Renamed", "timezone" => "Asia/Tokyo" } }, store.site_overrides.sort.to_h)
    assert_equal "{}", store.db.all("SELECT overrides FROM rl_sites WHERE id = 'default'")[0]["overrides"], "no overrides is an empty object"

    t = NOW - HOUR
    Seed.visit(store, "s1", "v1", t, {}, [["pageview", "/", t, "p1"]], "shop")
    Seed.visit(store, "s2", "v2", t - 40 * DAY, {}, [["pageview", "/", t - 40 * DAY, "p2"]], "shop")
    Seed.visit(store, "s3", "v3", t, {}, [["pageview", "/", t, "p3"]])
    store.save_goal(goal("g1", { "site" => "shop", "match" => "x" }))
    store.insert_share({ "id" => "sh", "site" => "shop", "name" => "", "createdAt" => 1 })
    store.add_link_domain("go.shop.example", "shop", 1)
    store.build_rollup_day("shop", "2026-10-05", NOW - 36 * HOUR, NOW - 12 * HOUR)
    assert_equal t, store.last_seen("shop")
    store.delete_site("shop")
    assert_equal ["default"], store.sites.map { |s| s["id"] }
    %w[rl_events rl_sessions rl_goals rl_shares rl_link_domains rl_rollups rl_rollup_days].each do |table|
      assert_equal 0, Integer(store.db.all("SELECT COUNT(*) AS n FROM #{table} WHERE site = 'shop'")[0]["n"]), table
    end
    assert_equal 1, store.stats(today)["visits"], "the other site keeps its visits"
    assert_nil store.last_seen("shop")
  end

  on_each "short_links_and_their_clicks" do |kind|
    store = store(kind)
    link = { "id" => "l" * 24, "site" => "default", "domain" => "", "slug" => "launch", "name" => "Launch", "url" => "https://example.com/launch", "createdAt" => NOW - DAY, "updatedAt" => NOW - DAY }
    store.insert_link(link)
    assert_equal link, store.link_by_slug("launch")
    # A slug is unique across every domain while its link lives.
    assert_raises(ActiveRecord::RecordNotUnique, "a second live link with the slug") do
      store.insert_link(link.merge("id" => "m" * 24, "domain" => "go.example.com"))
    end
    store.update_link(link.merge("domain" => "go.example.com", "name" => "Moved", "updatedAt" => NOW))
    found = store.link_by_id(link["id"])
    assert_equal ["go.example.com", "Moved", NOW], [found["domain"], found["name"], found["updatedAt"]]
    40.times do |i|
      ts = NOW - i * HOUR
      session = (i % 4).zero? ? "" : "c#{i}"
      Seed.visit(store, session, "cv#{i % 3}", ts, { "source" => i.odd? ? "Twitter" : "Direct", "country" => i.odd? ? "GB" : "US" }) unless session.empty?
      store.insert_event({ "site" => "default", "ts" => ts, "kind" => "click", "visitor" => session.empty? ? "" : "cv#{i % 3}", "session" => session, "pageview" => "", "path" => "", "hostname" => "", "title" => "", "name" => "", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => link["id"] })
      store.touch_session(session, ts, "click", "") unless session.empty?
    end
    listed = store.links("default", NOW - 2 * DAY, NOW + 1)
    assert_equal [40, 3], [listed[0]["clicks"], listed[0]["visitors"]], "clicks imported as counts add to clicks only"
    buckets = Array.new(45) { |h| { "start" => NOW - 44 * HOUR + h * HOUR, "end" => NOW - 43 * HOUR + h * HOUR } }
    series = store.link_series("default", link["id"], buckets)
    assert_equal 45, series.length, "more buckets than one statement takes"
    assert_equal 40, series.sum { |p| p["clicks"] }
    assert_equal [{ "value" => "Twitter", "visitors" => 3, "events" => 20 }, { "value" => "Direct", "visitors" => 3, "events" => 10 }],
                 store.link_breakdown("default", link["id"], 0, NOW + 1, "source", 5)
    assert_equal 0, store.stats(q(0, NOW + 1))["visits"], "a click alone is not a visit"

    store.delete_link(link["id"], NOW)
    assert_nil store.link_by_slug("launch")
    assert_nil store.link_by_id(link["id"])
    assert_equal [], store.links("default", 0, NOW + 1)
    store.insert_link(link.merge("id" => "n" * 24))
    assert_equal "n" * 24, store.link_by_slug("launch")["id"], "a deleted link frees its slug"

    store.add_link_domain("go.example.com", "default", 1)
    store.add_link_domain("go.example.com", "other", 2)
    store.add_link_domain("a.example.com", "default", 3)
    assert_equal [{ "domain" => "a.example.com", "site" => "default" }, { "domain" => "go.example.com", "site" => "default" }], store.link_domains,
                 "a domain stays with its first site"
    store.remove_link_domain("go.example.com")
    assert_equal ["a.example.com"], store.link_domains.map { |d| d["domain"] }
  end

  on_each "shares_tokens_reports_and_settings" do |kind|
    store = store(kind)
    store.insert_share({ "id" => "s1", "site" => "default", "name" => "Client", "createdAt" => 1 })
    store.insert_share({ "id" => "s2", "site" => "default", "name" => "", "createdAt" => 2 })
    store.rename_share("s1", "Renamed")
    assert_equal %w[s2 s1], store.shares("default").map { |s| s["id"] }
    assert_equal({ "id" => "s1", "site" => "default", "name" => "Renamed", "createdAt" => 1 }, store.share_by_id("s1"))
    store.delete_share("s1")
    assert_nil store.share_by_id("s1")

    token = { "id" => "t1", "name" => "Script", "site" => "", "scope" => "read", "hash" => "h" * 64, "hint" => "abcd", "createdAt" => 5, "lastUsedAt" => nil }
    store.insert_token(token)
    store.insert_token(token.merge("id" => "t2", "site" => "default", "scope" => "manage", "hash" => "g" * 64, "createdAt" => 6))
    store.touch_token("t1", 99)
    assert_equal token.merge("lastUsedAt" => 99), store.token_by_hash("h" * 64)
    assert_equal %w[t2 t1], store.tokens.map { |t| t["id"] }
    assert store.delete_token("t1"), "a token that was there"
    refute store.delete_token("t1"), "and once it is gone"

    report = { "id" => "r1", "site" => "default", "email" => "a@example.com", "frequency" => "weekly", "lang" => "en", "token" => "q" * 32, "origin" => "", "lastPeriod" => "", "lastSentAt" => nil, "createdAt" => 7 }
    store.insert_report(report)
    assert store.claim_report("r1", "w:2026-09-28", 100), "the first claim wins"
    refute store.claim_report("r1", "w:2026-09-28", 101), "a second, at once, does not"
    assert_equal report.merge("lastPeriod" => "w:2026-09-28", "lastSentAt" => 100), store.report_by("token", "q" * 32)
    store.release_report("r1", "w:2026-09-28", "")
    assert_equal "", store.report_by("id", "r1")["lastPeriod"]
    assert_equal 1, store.reports.length
    assert_equal 1, store.reports("default").length
    assert_equal [], store.reports("elsewhere")
    store.delete_report("r1")
    assert_nil store.report_by("id", "r1")

    store.set_setting("remote:a", "1")
    store.set_setting("remote:a", "2")
    store.set_setting("remote_b", "3")
    store.set_setting("remote%c", "4")
    store.set_setting("remote\\d", "5")
    assert_equal "2", store.setting("remote:a")
    assert_equal [{ "key" => "remote:a", "value" => "2" }], store.settings_starting_with("remote:")
    assert_equal [{ "key" => "remote_b", "value" => "3" }], store.settings_starting_with("remote_"), "an underscore is taken literally"
    assert_equal [{ "key" => "remote%c", "value" => "4" }], store.settings_starting_with("remote%")
    assert_equal [{ "key" => "remote\\d", "value" => "5" }], store.settings_starting_with("remote\\"), "and a backslash, on MySQL too"
    store.set_setting("remote:a", nil)
    assert_nil store.setting("remote:a")
  end

  on_each "salts_sessions_and_the_live_view" do |kind|
    store = store(kind)
    assert_equal "first", store.salt("2026-10-06", "first")
    assert_equal "first", store.salt("2026-10-06", "second"), "two racing callers agree on one"
    store.salt("2026-10-05", "old")
    store.drop_salts_before("2026-10-06")
    assert_nil store.salt_if_exists("2026-10-05")
    assert_equal "first", store.salt_if_exists("2026-10-06")

    t = NOW - 3 * MIN
    Seed.visit(store, "s1", "v1", t - HOUR, { "source" => "Google", "country" => "GB", "city" => "London", "device" => "Desktop" },
               [["pageview", "/", t - HOUR, "old"], ["pageview", "/pricing", t, "p1"], ["event", "Signup", t + 1000, nil]])
    Seed.visit(store, "s2", "v2", t, { "country" => "US" }, [["pageview", "/", t, "p2"]])
    assert_equal({ "id" => "s1", "visitor" => "v1" }, store.open_session("default", %w[v0 v1], t - 1))
    assert_nil store.open_session("default", ["v1"], t + 2000)
    assert_nil store.open_session("default", [], 0)
    assert_equal({ "session" => "s1", "visitor" => "v1", "path" => "/pricing", "hostname" => "example.com", "ts" => t, "startedAt" => t - HOUR, "lastAt" => t + 1000 },
                 store.pageview("default", "p1"))
    assert_nil store.pageview("default", "nope")

    live = store.realtime("default", NOW)
    assert_equal 2, live["visitors"]
    assert_equal [{ "value" => "/", "visitors" => 1 }, { "value" => "/pricing", "visitors" => 1 }], live["pages"]
    assert_equal [{ "value" => "Google", "visitors" => 1 }], live["sources"]
    assert_equal [{ "value" => "GB", "visitors" => 1 }, { "value" => "US", "visitors" => 1 }], live["countries"]
    assert_equal 30, live["minutes"].length
    assert_equal 2, live["minutes"][26]
    assert_equal({ "ts" => t + 1000, "kind" => "event", "path" => "/pricing", "name" => "Signup", "country" => "GB", "city" => "London", "source" => "Google", "device" => "Desktop" },
                 live["recent"][0])
    assert_equal 3, live["recent"].length
  end

  on_each "ai_agent_fetches_are_their_own_rows_outside_visits" do |kind|
    store = store(kind)
    %w[GPTBot GPTBot ClaudeBot ClaudeBot Amazonbot].each_with_index do |agent, i|
      store.insert_event({ "site" => "default", "ts" => NOW - i * MIN, "kind" => "fetch", "visitor" => "", "session" => "", "pageview" => "", "path" => i.odd? ? "/a" : "/b", "hostname" => "example.com", "title" => "", "name" => agent, "props" => { "company" => "X", "kind" => "crawler" }, "engagedMs" => 0, "scroll" => nil, "link" => "" })
    end
    assert_equal [{ "value" => "ClaudeBot", "visitors" => 0, "fetches" => 2 }, { "value" => "GPTBot", "visitors" => 0, "fetches" => 2 }, { "value" => "Amazonbot", "visitors" => 0, "fetches" => 1 }],
                 store.breakdown(today, "ai_agent", 10, 0)
    assert_equal [{ "value" => "/a", "visitors" => 0, "fetches" => 2 }], store.breakdown(today, "ai_page", 1, 1)
    assert_equal 0, store.stats(today)["visits"]
    assert_equal '{"company":"X","kind":"crawler"}', store.db.all("SELECT props FROM rl_events WHERE kind = 'fetch' LIMIT 1")[0]["props"]
  end
end
