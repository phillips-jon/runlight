# frozen_string_literal: true

require "test_helper"
require_relative "../support/store_test_case"

# What the reports count, at the store: the store-level parts of counting.test.ts, filters.test.ts,
# goals.test.ts, funnels.test.ts, journeys.test.ts, props.test.ts, and mysql.test.ts. Visits are written
# through the store as the tracker writes them.
class StoreCountingTest < StoreTestCase
  # The stats numbers asked for.
  def pick(stats, *keys)
    keys.map { |k| stats[k] }
  end

  on_each "goals_funnels_and_event_properties_count_visits_by_when_they_started_with_or_without_a_filter" do |kind|
    store = store(kind)
    # Two people start at 23:50 on the 5th and sign up at 00:10 on the 6th; a third visits on the 6th.
    start = NOW - 12 * HOUR - 10 * MIN
    [1, 2].each do |i|
      Seed.visit(store, "s#{i}", "v#{i}", start, { "country" => "GB" }, [
        ["pageview", "/signup", start, "p#{i}"],
        ["event", "Signup", start + 20 * MIN, { "plan" => "pro" }],
      ])
    end
    Seed.visit(store, "s3", "v3", start + 80 * MIN, {}, [["pageview", "/", start + 80 * MIN, "q"]])
    goal = goal("a" * 24, { "name" => "Signup", "match" => "Signup" })
    store.save_goal(goal)
    funnel = { "id" => "b" * 24, "site" => "default", "name" => "Signup", "steps" => [{ "kind" => "page", "match" => "/signup" }, { "kind" => "event", "match" => "Signup" }], "createdAt" => 0 }
    store.save_funnel(funnel)
    day5 = Seed.utc(2026, 10, 5)
    [[], [%w[country not ZZ]], [["page", "contains", "/"]]].each do |filters|
      read = lambda do |from|
        query = q(from, from + DAY, *filters)
        totals = store.goal_totals(query, goal)
        visitors = store.visitors(query)
        events = store.breakdown(query, "event", 10, 0).map { |r| "#{r["value"]}:#{r["events"]}" }
        [totals["conversions"], visitors.positive? ? totals["visitors"].fdiv(visitors) : 0, store.funnel_counts(query, funnel), store.event_prop_keys(query, "Signup").length, events]
      end
      label = Runlight::Json.encode(filters)
      assert_equal [2, 1, [2, 2], 1, ["Signup:2"]], read.call(day5), "the visits that started on the 5th #{label}"
      assert_equal [0, 0, [0, 0], 0, []], read.call(day5 + DAY), "nothing that started on the 6th converted #{label}"
    end
  end

  on_each "contains_finds_capitals_beyond_ascii_and_two_page_filters_count_both_pages" do |kind|
    store = store(kind)
    t = NOW - HOUR
    Seed.visit(store, "s1", "v1", t, { "utmCampaign" => "Über" }, [["pageview", "/a", t, "a"], ["pageview", "/b", t + MIN, "b"]])
    %w[über Über ÜBER ber].each do |value|
      assert_equal 1, store.stats(today(["utm_campaign", "contains", value]))["visits"], "contains #{value}"
    end
    both = store.stats(today(["page", "is", "/a"], ["page", "is", "/b"]))
    assert_equal [1, 2], pick(both, "visits", "pageviews")
  end

  on_each "a_page_goal_funnel_or_filter_written_in_plain_letters_matches_the_encoded_path" do |kind|
    store = store(kind)
    t = NOW - HOUR
    Seed.visit(store, "s1", "v1", t, {}, [["pageview", Runlight::Sources.recorded_path("/café").to_s, t, "a"]])
    goal = Runlight::Goals.goal_from({ "name" => "Café", "kind" => "page", "match" => "/café" }, "default", [], NOW)
    store.save_goal(goal)
    assert_equal 1, store.goal_totals(today, goal)["conversions"]
    assert_equal 1, store.stats(today(["page", "is", "/café"]))["visits"]
  end

  on_each "an_event_that_joins_a_visit_already_ended_counts_without_reopening_it" do |kind|
    store = store(kind)
    t = NOW - 6 * HOUR
    Seed.visit(store, "s1", "v1", t, {}, [["pageview", "/", t, "p1"]])
    store.insert_event({ "site" => "default", "ts" => t + 2 * HOUR, "kind" => "event", "visitor" => "v1", "session" => "s1", "pageview" => "p1", "path" => "/", "hostname" => "example.com", "title" => "", "name" => "Late", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => "" })
    store.touch_session("s1", t + 2 * HOUR, "event", "/", false)
    assert_nil store.open_session("default", ["v1"], t + HOUR), "still ended"
    assert_equal [{ "value" => "Late", "visitors" => 1, "events" => 1 }], store.breakdown(today, "event", 10, 0)
    assert_equal 0, store.stats(today)["bounceRate"]
  end

  on_each "time_on_page_is_over_every_pageview_counting_quick_ones_as_none" do |kind|
    store = store(kind)
    t = NOW - HOUR
    4.times do |i|
      rows = [["pageview", "/a", t, "v#{i}"]]
      rows << ["engagement", "v0", t + 1000, 60_000, 50] if i.zero?
      Seed.visit(store, "s#{i}", "v#{i}", t, {}, rows)
    end
    row = store.breakdown(today, "page", 10, 0)[0]
    assert_equal [15_000, 50], [row["timeOnPage"], row["scrollDepth"]]
  end

  def test_journeys_applies_a_filter_before_its_cap_on_visits_and_says_when_the_cap_was_reached
    store = store("sqlite")
    start = Seed.utc(2026, 10, 6)
    # Ten visits from Britain early in the day, then more from the US than journeys reads.
    store.transaction do |tx|
      (10 + Runlight::Store::SqlStore::JOURNEY_VISITS).times do |i|
        ts = start + i
        tx.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, country) VALUES (?, 'default', ?, ?, ?, 1, '/', '/', ?)", ["s#{i}", "v#{i}", ts, ts, i < 10 ? "GB" : "US"])
        tx.db.run("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, ?, '/', 'example.com')", [ts, "v#{i}", "s#{i}", "p#{i}"])
      end
    end
    sessions = ->(answer) { answer["rows"].map { |r| r["session"] }.uniq.length }
    britain = store.journey_pages(q(start, start + DAY, %w[country is GB]), 5)
    assert_equal 10, sessions.call(britain), "every British visit, though they are older than the newest visits read"
    refute britain["sampled"]
    all = store.journey_pages(q(start, start + DAY), 5)
    assert_equal Runlight::Store::SqlStore::JOURNEY_VISITS, sessions.call(all)
    assert all["sampled"]
  end

  on_each "a_page_goal_or_funnel_step_for_a_hash_route_counts_that_route_only" do |kind|
    store = store(kind)
    t = NOW - HOUR
    5.times do |i|
      rows = [["pageview", "/", t, "h#{i}"]]
      if i < 2
        rows << ["pageview", "/#/cart", t + 1000, "c#{i}"]
        rows << ["pageview", "/#/thanks", t + 2000, "t#{i}"]
      end
      Seed.visit(store, "s#{i}", "v#{i}", t, {}, rows)
    end
    goal = Runlight::Goals.goal_from({ "name" => "Thanks", "kind" => "page", "match" => "/#/thanks" }, "default", [], NOW)
    funnel = Runlight::Funnels.funnel_from({ "name" => "Checkout", "steps" => [{ "kind" => "page", "match" => "/#/cart" }, { "kind" => "page", "match" => "https://example.com/#/thanks" }] }, "default", [], NOW)
    totals = store.goal_totals(today, goal)
    assert_equal ["/#/thanks", 2, 2], [goal["match"], totals["conversions"], totals["visitors"]]
    assert_equal ["/#/cart", "/#/thanks"], funnel["steps"].map { |s| s["match"] }
    assert_equal [2, 2], store.funnel_counts(today, funnel)
  end

  on_each "page_and_hostname_filters_together_count_pageviews_matching_both" do |kind|
    store = store(kind)
    t = NOW - HOUR
    Seed.visit(store, "s1", "v1", t, {}, [
      ["pageview", "/pricing", t, "a", "example.com"],
      ["pageview", "/start", t + 1000, "b", "docs.example.com"],
      ["pageview", "/pricing", t + 2000, "c", "docs.example.com"],
    ])
    query = today(["page", "is", "/pricing"], ["hostname", "is", "docs.example.com"])
    assert_equal 1, store.stats(query)["pageviews"]
    assert_equal [["/pricing", 1]], store.breakdown(query, "page", 10, 0).map { |r| [r["value"], r["pageviews"]] }
  end

  on_each "contains_ignores_case_in_any_mix_in_paths_too_and_filters_take_paths_as_the_browser_writes_them" do |kind|
    store = store(kind)
    t = NOW - HOUR
    Seed.visit(store, "s1", "v1", t, { "utmCampaign" => "ÉcoleÉté" }, [["pageview", Runlight::Sources.recorded_path("/Über-uns").to_s, t, "a"]])
    Seed.visit(store, "s2", "v2", t, {}, [["pageview", Runlight::Sources.recorded_path("/a^b").to_s, t, "b"]])
    Seed.visit(store, "s3", "v3", t, {}, [["pageview", Runlight::Sources.recorded_path("/#/x{y}").to_s, t, "c"]])
    visits = ->(d, op, v) { store.stats(today([d, op, v]))["visits"] }
    %w[écoleété ÉCOLEÉTÉ eÉté].each { |value| assert_equal 1, visits.call("utm_campaign", "contains", value), value }
    %w[über ÜBER Über-Uns].each { |value| assert_equal 1, visits.call("page", "contains", value), value }
    assert_equal 1, visits.call("page", "is", "/a^b")
    assert_equal 1, visits.call("page", "is", "/#/x{y}")
  end

  on_each "time_on_page_leaves_out_imported_views_which_can_report_no_time" do |kind|
    store = store(kind)
    # Nine pageviews written as the Umami import writes them: no pageview id, never any engaged time.
    day = Seed.utc(2026, 10, 5, 10)
    9.times do |i|
      store.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, imported) VALUES (?, 'default', ?, ?, ?, 1, '/pricing', '/pricing', 1)", ["i#{i}", "v#{i}", day + i, day + i])
      store.db.run("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, '', '/pricing', 'example.com')", [day + i, "v#{i}", "i#{i}"])
    end
    t = NOW - HOUR
    Seed.visit(store, "live", "lv", t, {}, [["pageview", "/pricing", t, "live"], ["engagement", "live", t + 1000, 60_000, nil]])
    week = q(NOW - 7 * DAY, NOW + DAY)
    row = -> { store.breakdown(week, "page", 10, 0).find { |r| r["value"] == "/pricing" } }
    assert_equal [10, 60_000], [row.call["pageviews"], row.call["timeOnPage"]]
    Seed.build_days(store, "default", NOW - 7 * DAY, NOW + DAY)
    assert_equal 60_000, row.call["timeOnPage"], "the same once the days are built"
  end

  on_each "a_filter_picks_visits_and_the_numbers_describe_those_whole_visits" do |kind|
    store = store(kind)
    t = NOW - 3 * HOUR
    # Visit A: two pages and a Signup. Visit B: one page, no Signup.
    Seed.visit(store, "a", "va", t, {}, [["pageview", "/", t, "a1"], ["pageview", "/pricing", t + 30_000, "a2"], ["event", "Signup", t + 60_000, nil]])
    Seed.visit(store, "b", "vb", t + 60_000, {}, [["pageview", "/blog", t + 60_000, "b1"]])
    stats = ->(*f) { store.stats(today(*f)) }
    assert_equal [1, 1, 2], pick(stats.call(%w[event is Signup]), "visitors", "visits", "pageviews"), "the visits with a Signup, and all their pageviews"
    assert_equal [1, 1], pick(stats.call(["page", "is", "/pricing"]), "visits", "pageviews"), "a page filter counts that page's views"
    assert_equal 1, stats.call(["page", "is", "/pricing"], %w[event is Signup])["visits"], "a page and an event in the same visit"
    assert_equal [1, 1], pick(stats.call(%w[event not Signup]), "visits", "pageviews"), "is not means visits that never had one"

    buckets = Array.new(24) { |h| { "start" => NOW - 12 * HOUR + h * HOUR, "end" => NOW - 11 * HOUR + h * HOUR } }
    points = store.series({ "site" => "default", "filters" => [{ "dimension" => "event", "op" => "is", "value" => "Signup" }] }, buckets)
    assert_equal [1, 2], [points.sum { |p| p["visits"] }, points.sum { |p| p["pageviews"] }], "the chart agrees"
    pages = store.breakdown(today(%w[event is Signup]), "page", 10, 0).map { |r| r["value"] }.sort
    assert_equal ["/", "/pricing"], pages, "the pages of the visits that signed up"
    assert_equal ["Signup"], store.breakdown(today(["page", "is", "/pricing"]), "event", 10, 0).map { |r| r["value"] }
  end

  on_each "goals_count_events_page_patterns_and_revenue_including_visits_from_before_the_goal" do |kind|
    store = store(kind)
    t = NOW - HOUR
    Seed.visit(store, "a", "v1", t, { "source" => "Google" }, [["pageview", "/pricing", t, "a1"], ["event", "Purchase", t + 1, { "revenue" => 49 }], ["pageview", "/thanks", t + 2, "a2"]])
    Seed.visit(store, "b", "v2", t, {}, [["pageview", "/pricing", t, "b1"], ["event", "Purchase", t + 1, { "revenue" => "19.50" }], ["pageview", "/thanks/pro", t + 2, "b2"]])
    Seed.visit(store, "c", "v3", t, {}, [["pageview", "/", t, "c1"], ["event", "Purchase", t + 1, { "revenue" => "not a number" }]])

    purchase = Runlight::Goals.goal_from({ "name" => "Purchase", "kind" => "event", "match" => "Purchase", "valueMode" => "prop", "valueProp" => "revenue", "currency" => "usd" }, "default", [], NOW)
    thanks = Runlight::Goals.goal_from({ "name" => "Thank you page", "kind" => "page", "match" => "https://example.com/thanks*", "valueMode" => "fixed", "value" => 9.99 }, "default", [purchase], NOW)
    button = Runlight::Goals.goal_from({ "name" => "Buy button", "kind" => "click", "clickBy" => "selector", "match" => ".buy" }, "default", [purchase, thanks], NOW)
    [purchase, thanks, button].each { |g| store.save_goal(g) }
    assert_equal 3, store.visitors(today)
    all = store.goal_totals_all(today, store.goals("default"))
    assert_equal({ "conversions" => 3, "visitors" => 3, "revenue" => 68.5 }, all[purchase["id"]], "numbers and numeric strings add up; anything else counts as nothing")
    assert_equal "USD", purchase["currency"]
    assert_equal "/thanks*", thanks["match"], "a pasted URL keeps only its path"
    assert_equal 2, all[thanks["id"]]["conversions"]
    assert_in_delta 19.98, all[thanks["id"]]["revenue"], 1e-9, "a decimal fixed value works on every database, Postgres too"
    assert_equal 0, all[button["id"]]["conversions"]
    assert_equal all[thanks["id"]], store.goal_totals(today, thanks)

    pages = store.goal_breakdown(today, purchase, "path")
    assert_equal [["/pricing", 2], ["/", 1]], pages.map { |r| [r["value"], r["conversions"]] }
    assert_equal 68.5, store.goal_totals(today, purchase)["revenue"]
    series = store.goal_series({ "site" => "default", "filters" => [] }, purchase, [{ "start" => NOW - 12 * HOUR, "end" => NOW }, { "start" => NOW, "end" => NOW + 12 * HOUR }])
    assert_equal 3, series.sum { |p| p["conversions"] }
    assert_equal [["s", ".buy", "Buy button"]], Runlight::Goals.click_rules(store.sites, store.goals)["default"]
  end

  on_each "renaming_a_click_goal_renames_its_past_clicks" do |kind|
    store = store(kind)
    t = NOW - HOUR
    Seed.visit(store, "a", "v1", t, {}, [["pageview", "/", t, "a1"], ["event", "Buy", t + 1, nil]])
    before = goal("c" * 24, { "name" => "Buy", "kind" => "click", "clickBy" => "selector", "match" => ".buy" })
    store.save_goal(before)
    after = before.merge("name" => "Buy now")
    store.save_goal(after, before)
    assert_equal 1, store.goal_totals(today, after)["conversions"]
    assert_equal "Buy now", store.goal_by_id(before["id"])["name"]
    store.delete_goal(before["id"])
    assert_equal [], store.goals("default")
  end

  on_each "funnel_steps_in_the_same_millisecond_both_count_and_one_row_never_counts_as_two_steps" do |kind|
    store = store(kind)
    t = NOW - MIN
    Seed.visit(store, "a", "v1", t, {}, [["pageview", "/pricing", t, "a1"], ["event", "Signup", t, nil]])
    same = Runlight::Funnels.funnel_from({ "name" => "Same moment", "steps" => [{ "kind" => "page", "match" => "/pricing" }, { "kind" => "event", "match" => "Signup" }] }, "default", [], NOW)
    twice = Runlight::Funnels.funnel_from({ "name" => "Twice", "steps" => [{ "kind" => "page", "match" => "/pricing" }, { "kind" => "page", "match" => "/pricing" }] }, "default", [same], NOW)
    assert_equal [1, 1], store.funnel_counts(today, same)
    assert_equal [1, 0], store.funnel_counts(today, twice), "one pageview is not two steps"
  end

  on_each "a_funnel_counts_visits_that_took_each_step_in_order_within_one_visit" do |kind|
    store = store(kind)
    n = 0
    visit = lambda do |steps|
      n += 1
      t = NOW - 3 * HOUR + n * 10 * MIN
      rows = steps.each_with_index.map do |(path, event), i|
        event.nil? ? ["pageview", path, t + i * MIN, "p#{n}x#{i}"] : ["event", event, t + i * MIN, nil, path]
      end
      Seed.visit(store, "s#{n}", "v#{n}", t, {}, rows)
    end
    # All three steps in order; two steps, then gone; the right pages in the wrong order; never on pricing.
    visit.call([["/pricing", nil], ["/signup", "Signup"], ["/welcome", nil]])
    visit.call([["/pricing", nil], ["/signup", "Signup"]])
    visit.call([["/welcome", nil], ["/pricing", nil]])
    visit.call([["/blog", nil], ["/welcome", nil]])

    error = assert_raises(Runlight::FunnelError) do
      Runlight::Funnels.funnel_from({ "name" => "One step", "steps" => [{ "kind" => "page", "match" => "/pricing" }] }, "default", [], NOW)
    end
    assert_equal "funnel_short", error.code
    funnel = Runlight::Funnels.funnel_from({ "name" => "Signup", "steps" => [{ "kind" => "page", "match" => "https://example.com/pricing*" }, { "kind" => "event", "match" => "Signup" }, { "kind" => "page", "match" => "welcome" }] }, "default", [], NOW)
    assert_equal ["/pricing*", "Signup", "/welcome"], funnel["steps"].map { |s| s["match"] }, "a pasted URL keeps its path; a bare path gains its slash"
    store.save_funnel(funnel)
    assert_equal [3, 2, 1], store.funnel_counts(today, store.funnels("default")[0])
    # Filters choose which visits enter. The Signup events were sent from /signup, so a page filter finds them.
    assert_equal [2, 2, 1], store.funnel_counts(today(["page", "is", "/signup"]), funnel)
    changed = Runlight::Funnels.funnel_from({ "name" => "Signup flow", "steps" => [{ "kind" => "page", "match" => "/pricing" }, { "kind" => "page", "match" => "/welcome" }] }, "default", [funnel], NOW + 1, funnel["id"])
    assert_equal funnel["createdAt"], changed["createdAt"]
    store.save_funnel(changed)
    assert_equal [3, 1], store.funnel_counts(today, store.funnels("default")[0])
    store.delete_funnel(funnel["id"])
    assert_equal [], store.funnels("default")
  end

  on_each "journey_pages_reads_each_visits_pages_in_order" do |kind|
    store = store(kind)
    t = NOW - HOUR
    [["/", "/pricing", "/signup"], ["/", "/pricing", "/pricing", "/about"], ["/blog"]].each_with_index do |pages, i|
      rows = pages.each_with_index.map { |page, j| ["pageview", page, t + i * MIN + j * 10_000, "p#{i}x#{j}"] }
      Seed.visit(store, "s#{i}", "v#{i}", t + i * MIN, {}, rows)
    end
    answer = store.journey_pages(today, 3)
    refute answer["sampled"]
    assert_equal [
      { "session" => "s0", "path" => "/" }, { "session" => "s0", "path" => "/pricing" }, { "session" => "s0", "path" => "/signup" },
      { "session" => "s1", "path" => "/" }, { "session" => "s1", "path" => "/pricing" }, { "session" => "s1", "path" => "/about" },
      { "session" => "s2", "path" => "/blog" },
    ], answer["rows"], "a refresh is not a step"
    assert_equal({ "rows" => [], "sampled" => false }, store.journey_pages(q(0, 1), 3))
  end

  on_each "an_events_properties_and_their_values_filtered_like_everything_else" do |kind|
    store = store(kind)
    t = NOW - HOUR
    Seed.visit(store, "a", "v1", t, {}, [
      ["pageview", "/", t, "a1"],
      ["event", "Outbound link", t + 1, { "url" => "https://github.com/x" }],
      ["event", "Outbound link", t + 2, { "url" => "https://news.ycombinator.com/" }],
      ["event", "Signup", t + 3, { "plan" => "pro", "seats" => 3 }],
      ["event", "Signup", t + 4, { "plan" => "team" }],
      ["event", "404", t + 5, { "path" => "/missing" }],
    ])
    Seed.visit(store, "b", "v2", t, {}, [["pageview", "/blog", t, "b1"], ["event", "Outbound link", t + 1, { "url" => "https://github.com/x" }, "/blog"]])

    assert_equal [{ "key" => "url", "events" => 3 }], store.event_prop_keys(today, "Outbound link")
    assert_equal [
      { "value" => "https://github.com/x", "events" => 2, "visitors" => 2 },
      { "value" => "https://news.ycombinator.com/", "events" => 1, "visitors" => 1 },
    ], store.event_prop_values(today, "Outbound link", "url", 10)
    assert_equal %w[plan seats], store.event_prop_keys(today, "Signup").map { |r| r["key"] }
    assert_equal [{ "value" => "3", "events" => 1, "visitors" => 1 }], store.event_prop_values(today, "Signup", "seats", 10)
    assert_equal ["https://github.com/x"], store.event_prop_values(today(["page", "is", "/blog"]), "Outbound link", "url", 10).map { |r| r["value"] }
    assert_equal [], store.event_prop_keys(today, "Nothing")
  end

  on_each "the_longest_values_the_tracker_accepts_are_kept_whole" do |kind|
    store = store(kind)
    t = NOW - 3 * HOUR
    path = "/#{"p" * 999}"
    utm = ->(c) { c * 200 }
    Seed.visit(store, "a", "v1", t, {
      "referrerHost" => "#{"r" * 60}.example.org", "referrerPath" => "/#{"q" * 499}",
      "utmSource" => utm.("s"), "utmMedium" => utm.("m"), "utmCampaign" => utm.("c"), "utmTerm" => utm.("t"), "utmContent" => utm.("o"),
    }, [["pageview", path, t, "a1"]])
    props = {}
    8.times { |i| props["#{i}#{"k" * 59}"] = "v" * 500 }
    store.insert_event({ "site" => "default", "ts" => t + 1, "kind" => "pageview", "visitor" => "v1", "session" => "a", "pageview" => "a2", "path" => "/x", "hostname" => "example.com", "title" => "t" * 500, "name" => "", "props" => nil, "engagedMs" => 0, "scroll" => nil, "link" => "" })
    Seed.visit(store, "b", "v2", t, {}, [["pageview", "/", t, "b1"], ["event", "n" * 120, t + 1, props]])

    assert_includes store.breakdown(today, "page", 10, 0).map { |r| r["value"] }, path
    { "utm_source" => "s", "utm_medium" => "m", "utm_campaign" => "c", "utm_term" => "t", "utm_content" => "o" }.each do |dimension, c|
      assert_equal [utm.(c)], store.breakdown(today, dimension, 10, 0).map { |r| r["value"] }
    end
    assert_equal "n" * 120, store.breakdown(today, "event", 10, 0)[0]["value"]
    assert_equal 8, store.event_prop_keys(today, "n" * 120).length
    assert_equal ["v" * 500], store.event_prop_values(today, "n" * 120, "0#{"k" * 59}", 10).map { |r| r["value"] }
    # A day of them adds up the same way.
    Seed.build_days(store, "default", NOW - DAY, NOW + 12 * HOUR)
    assert_includes store.breakdown(q(NOW - 7 * DAY, NOW + DAY), "page", 10, 0).map { |r| r["value"] }, path
  end

  on_each "text_is_compared_exactly_and_sorted_by_code_point_case_and_trailing_spaces_included" do |kind|
    store = store(kind)
    values = ["a", "a ", "A", "b", "é", "É", "\u{1F600}", "\u{FFFD}", "a\t"]
    t = NOW - HOUR
    values.each_with_index do |value, i|
      Seed.visit(store, "s#{i}", "v#{i}", t, { "utmCampaign" => value }, [["pageview", "/", t, "x#{i}"], ["event", "Pick", t + 1, { "choice" => value }]])
    end
    sorted = values.sort_by(&:b)
    rows = store.event_prop_values(today, "Pick", "choice", 20)
    assert_equal sorted, rows.map { |r| r["value"] }
    assert_equal [1] * values.length, rows.map { |r| r["events"] }, "no two values counted as one"
    assert_equal sorted, store.breakdown(today, "utm_campaign", 20, 0).map { |r| r["value"] }
    assert_equal 1, store.stats(today(["utm_campaign", "is", "a "]))["visits"], "a trailing space is part of the value"
  end

  on_each "short_link_clicks_are_not_visits_in_the_heatmap_raw_or_rolled_up_nor_the_first_visit" do |kind|
    store = store(kind)
    day = Seed.utc(2026, 10, 5, 15)
    # A session opened only by a short link click, then a real visit.
    store.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'default', 'v1', ?, ?, 0, 0, 0)", [day - HOUR, day - HOUR])
    store.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'default', 'v2', ?, ?, 1, 0, 0)", [day, day])
    assert_equal day, store.first_own_visit("default")
    assert_equal day - HOUR, store.first_seen("default")
    query = q(Seed.utc(2026, 10, 1), Seed.utc(2026, 10, 7))
    sum = ->(rows) { rows.sum { |r| r["visits"] } }
    assert_equal 1, sum.call(store.hourly(query)), "raw"
    Seed.build_days(store, "default", query["from"], query["to"])
    assert_equal 1, sum.call(store.hourly(query)), "rolled up"
  end
end
