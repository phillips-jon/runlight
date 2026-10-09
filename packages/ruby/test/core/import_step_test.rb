# frozen_string_literal: true

require "test_helper"
require_relative "../support/router"

# Link imports written into the store, as importers.test.ts tests them.
class CoreImportStepTest < Minitest::Test
  NOW = 1_791_288_000_000
  Index = Runlight::Importers::Index
  Write = Runlight::Importers::Write
  Json = Runlight::Json

  def runlight(router)
    Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "fetcher" => router, "now" => -> { NOW } })
  end

  # Runs an import to the end: [core, totals, done].
  def run_all(router, source, credentials)
    rl = runlight(router)
    cursor = nil
    done = 0
    totals = { "links" => 0, "clicks" => 0, "skipped" => 0, "failed" => [] }
    loop do
      step = Index.import_step(rl, "default", source, credentials, cursor, done)
      cursor = step["cursor"]
      done = step["done"]
      totals["links"] += step["links"]
      totals["clicks"] += step["clicks"]
      totals["skipped"] += step["skipped"]
      totals["failed"].concat(step["failed"])
      break if cursor.nil?
    end
    [rl, totals, done]
  end

  def links(rl)
    rl.store.links("default", 0, NOW + 1)
  end

  def test_dub_every_click_where_the_plan_allows
    router = Router.new([
      [/api\.dub\.co\/links\?.*startingAfter=l2/, ->(_u, _i) { [] }],
      [/api\.dub\.co\/links\?/, lambda { |_u, _i|
        [
          { "id" => "l1", "domain" => "dub.sh", "key" => "launch", "url" => "https://a.com/launch", "title" => "Launch", "createdAt" => "2026-01-02T00:00:00Z" },
          { "id" => "l2", "domain" => "go.brand.com", "key" => "sale", "url" => "https://a.com/sale", "title" => nil, "createdAt" => "2026-02-03T00:00:00Z" },
        ]
      }],
      [/\/events\?.*linkId=l1/, lambda { |_u, _i|
        [
          { "timestamp" => "2026-03-01T10:00:00Z", "click" => { "id" => "c1", "country" => "CA", "city" => "Toronto", "device" => "Mobile", "browser" => "Chrome",
                                                                 "os" => "iOS", "referer" => "instagram.com", "refererUrl" => "https://instagram.com/" } },
          { "timestamp" => "2026-03-02T10:00:00Z", "click" => { "id" => "c2", "country" => "US", "device" => "Desktop", "browser" => "Safari", "os" => "Mac OS",
                                                                 "referer" => "(direct)" } },
        ]
      }],
      [/\/events\?.*linkId=l2/, ->(_u, _i) { [] }],
    ])
    rl, totals, = run_all(router, "dub", { "apiKey" => "dub_test" })
    assert_equal 2, totals["links"]
    assert_equal 2, totals["clicks"]
    by_slug = links(rl).to_h { |l| [l["slug"], l] }
    assert_equal "", by_slug["launch"]["domain"], "dub.sh stays behind; the link moves to /go"
    assert_equal "go.brand.com", by_slug["sale"]["domain"], "branded domains come across"
    assert_equal({ "domain" => "go.brand.com", "site" => "default" }, rl.store.link_domains[0])
    session = rl.store.db.all("SELECT country, source, device FROM rl_sessions ORDER BY started_at LIMIT 1")[0]
    assert_equal({ "country" => "CA", "source" => "Instagram", "device" => "mobile" }, session)
    assert_equal 1, rl.store.db.all("SELECT imported FROM rl_sessions LIMIT 1")[0]["imported"].to_i
  end

  def test_dub_daily_counts_when_the_plan_has_no_events_api
    router = Router.new([
      [/api\.dub\.co\/links\?/, ->(_u, _i) { [{ "id" => "l1", "domain" => "dub.sh", "key" => "x", "url" => "https://a.com", "title" => "X", "createdAt" => "2026-01-02T00:00:00Z" }] }],
      [/\/events\?/, ->(_u, _i) { [403, { "error" => { "message" => "Business plan required" } }] }],
      [/\/analytics\?/, ->(_u, _i) { [{ "start" => "2026-03-01T00:00:00.000Z", "clicks" => 3 }, { "start" => "2026-03-02T00:00:00.000Z", "clicks" => 0 }] }],
    ])
    rl, totals, = run_all(router, "dub", { "apiKey" => "dub_test" })
    assert_equal 3, totals["clicks"]
    row = links(rl)[0]
    assert_equal 3, row["clicks"]
    assert_equal 0, row["visitors"], "daily counts add clicks, not made-up visitors"
    times = rl.store.db.all("SELECT ts FROM rl_events ORDER BY ts").map { |r| r["ts"].to_i }
    day = Time.utc(2026, 3, 1).to_i * 1000
    assert_equal [day + 14_400_000, day + 43_200_000, day + 72_000_000], times, "spread through the day"
  end

  def test_bitly_every_group_custom_back_halves_daily_counts
    router = Router.new([
      [%r{/v4/groups\z}, ->(_u, _i) { { "groups" => [{ "guid" => "G1" }, { "guid" => "G2" }] } }],
      [%r{/groups/G1/bitlinks}, lambda { |_u, _i|
        { "links" => [
          { "id" => "bit.ly/3abc", "link" => "https://bit.ly/3abc", "long_url" => "https://a.com/1", "title" => "One", "created_at" => "2026-01-01T00:00:00+0000",
            "custom_bitlinks" => ["https://t.brand.com/one"] },
          { "id" => "bit.ly/gone", "link" => "https://bit.ly/gone", "long_url" => "https://a.com/x", "title" => "Gone", "created_at" => "2026-01-01T00:00:00+0000",
            "is_deleted" => true },
        ], "pagination" => { "search_after" => "" } }
      }],
      [%r{/groups/G2/bitlinks}, lambda { |_u, _i|
        { "links" => [{ "id" => "bit.ly/4def", "link" => "https://bit.ly/4def", "long_url" => "https://a.com/2", "title" => nil,
                        "created_at" => "2026-02-01T00:00:00+0000" }], "pagination" => {} }
      }],
      [%r{/bitlinks/bit\.ly%2F3abc/clicks}, lambda { |_u, _i|
        { "link_clicks" => [{ "clicks" => 5, "date" => "2026-03-01T00:00:00+0000" }, { "clicks" => 2, "date" => "2026-03-02T00:00:00+0000" }] }
      }],
      [%r{/bitlinks/bit\.ly%2F4def/clicks}, ->(_u, _i) { [402, { "message" => "UPGRADE_REQUIRED" }] }],
    ])
    rl, totals, = run_all(router, "bitly", { "token" => "bitly_test" })
    assert_equal 2, totals["links"], "the deleted link is skipped"
    assert_equal 7, totals["clicks"]
    pairs = links(rl).map { |l| [l["domain"], l["slug"]] }.sort
    assert_equal [["", "4def"], ["t.brand.com", "one"]], pairs
  end

  def test_short_io_every_domain_paged_with_daily_counts_in_either_shape
    router = Router.new([
      [/api\.short\.io\/api\/domains/, ->(_u, _i) { [{ "id" => 7, "hostname" => "s.brand.com" }] }],
      [/api\/links\?.*pageToken=P2/, lambda { |_u, _i|
        { "links" => [{ "idString" => "lnk2", "id" => 2, "path" => "two", "originalURL" => "https://a.com/2", "createdAt" => "2026-02-01T00:00:00Z" }], "nextPageToken" => nil }
      }],
      [/api\/links\?domain_id=7/, lambda { |_u, _i|
        { "links" => [{ "idString" => "lnk1", "id" => 1, "path" => "one", "originalURL" => "https://a.com/1", "title" => "One", "createdAt" => "2026-01-01T00:00:00Z" }],
          "nextPageToken" => "P2" }
      }],
      [%r{statistics/link/lnk1/by_interval}, ->(_u, _i) { { "clickStatistics" => [{ "x" => "2026-03-01T00:00:00Z", "y" => 4 }] } }],
      [%r{statistics/link/lnk2/by_interval}, lambda { |_u, _i|
        { "clickStatistics" => { "datasets" => [{ "data" => [{ "x" => Time.utc(2026, 3, 2).to_i * 1000, "y" => 1 }] }] } }
      }],
    ])
    _, totals, = run_all(router, "shortio", { "apiKey" => "sk_test" })
    assert_equal 2, totals["links"]
    assert_equal 5, totals["clicks"]
  end

  def test_rebrandly_links_only_paged_by_the_last_id
    page = lambda do |from, n|
      (from...(from + n)).map do |i|
        { "id" => "r#{i}", "slashtag" => "s#{i}", "destination" => "https://a.com/#{i}", "domain" => { "fullName" => "rebrand.ly" }, "createdAt" => "2026-01-01T00:00:00Z" }
      end
    end
    router = Router.new([
      [/\/links\?.*last=r24/, ->(_u, _i) { page.call(25, 3) }],
      [/rebrandly\.com\/v1\/links\?/, ->(_u, _i) { page.call(0, 25) }],
    ])
    rl, totals, = run_all(router, "rebrandly", { "apiKey" => "rb_test" })
    assert_equal 28, totals["links"]
    assert_equal 0, totals["clicks"]
    assert_equal "", links(rl)[0]["domain"], "rebrand.ly stays behind"
  end

  def test_umami_signs_in_with_a_username_and_password_and_re_runs_skip_what_is_there
    router = Router.new([
      [%r{/api/auth/login}, ->(_u, init) { Json.decode(init["body"])["password"] == "pw" ? { "token" => "tok" } : {} }],
      [%r{/api/links\?}, lambda { |_u, _i|
        { "data" => [{ "id" => "u-1", "name" => "Golden", "url" => "https://a.com", "slug" => "golden", "createdAt" => "2026-01-01T00:00:00Z", "deletedAt" => nil,
                       "customDomain" => { "domain" => "t.brand.com" } }], "count" => 1 }
      }],
      [%r{/websites/u-1/events}, lambda { |_u, _i|
        { "data" => [{ "sessionId" => "s1", "createdAt" => "2026-03-01T00:00:00Z", "urlPath" => "/golden", "urlQuery" => "utm_source=newsletter", "referrerDomain" => "",
                       "referrerPath" => "", "country" => "GB", "city" => "London", "device" => "mobile", "os" => "iOS", "browser" => "ios" }], "count" => 1 }
      }],
      [%r{/websites/u-1/sessions}, ->(_u, _i) { { "data" => [{ "id" => "s1", "screen" => "390x844", "language" => "en-GB", "region" => "ENG" }], "count" => 1 } }],
    ])
    rl = runlight(router)
    creds = { "url" => "https://stats.example.com/", "username" => "jon", "password" => "pw" }
    first = Index.import_step(rl, "default", "umami", creds, nil, 0)
    assert_equal 1, first["links"]
    assert_equal 1, first["clicks"]
    assert router.calls[0].start_with?("POST stats.example.com/api/auth/login")
    s = rl.store.db.all("SELECT region, source, browser FROM rl_sessions")[0]
    assert_equal({ "region" => "GB-ENG", "source" => "Newsletter", "browser" => "Safari" }, s)
    again = Index.import_step(rl, "default", "umami", creds, nil, 0)
    assert_equal 1, again["skipped"]
    e = assert_raises(Runlight::Importers::ImportError) { Index.import_step(rl, "default", "umami", { "url" => "nope" }, nil, 0) }
    assert_includes e.message, "Umami address"
    e = assert_raises(Runlight::Importers::ImportError) { Index.import_step(rl, "default", "nowhere", {}, nil, 0) }
    assert_includes e.message, "cannot import"
    assert_equal({ "source" => "nowhere" }, e.params)
  end

  def test_umami_a_link_already_here_with_the_same_slug_and_destination_is_skipped_before_its_history_is_fetched
    router = Router.new([
      [%r{/api/links\?}, lambda { |_u, _i|
        { "data" => [{ "id" => "u-9", "name" => "Golden", "url" => "https://a.com/", "slug" => "golden", "createdAt" => "2026-01-01T00:00:00Z", "deletedAt" => nil }],
          "count" => 1 }
      }],
      [%r{/websites/u-9/}, ->(_u, _i) { { "data" => [], "count" => 0 } }],
    ])
    rl = runlight(router)
    rl.init
    # Brought in earlier some other way, such as a CSV, so it has no Umami id.
    rl.links.create("default", { "url" => "https://a.com", "slug" => "golden", "name" => "Golden" })
    step = Index.import_step(rl, "default", "umami", { "url" => "https://stats.example.com/", "apiKey" => "k" }, nil, 0)
    assert_equal 1, step["skipped"]
    assert_equal 0, step["links"]
    assert_equal [], router.calls.select { |c| c.include?("/websites/u-9/") }, "no history was fetched for it"
  end

  def test_a_link_whose_slug_is_taken_or_unusable_is_reported_with_a_code
    rl = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:") })
    rl.init
    rl.links.create("default", { "url" => "https://elsewhere.com", "slug" => "taken", "name" => "Other" })
    taken = Write.write_link(rl, "default", "dub", { "sourceId" => "x", "slug" => "taken", "domain" => "", "name" => "X", "url" => "https://a.com", "createdAt" => 0 }, {})
    assert_equal Json.encode({ "status" => "failed", "clicks" => 0, "reason" => '/taken is already used by "Other"', "code" => "import_slug_taken",
                               "params" => { "slug" => "taken", "name" => "Other" } }), Json.encode(taken)
    bad = Write.write_link(rl, "default", "dub", { "sourceId" => "y", "slug" => "a/b", "domain" => "", "name" => "", "url" => "https://a.com", "createdAt" => 0 }, {})
    assert_equal "import_slug_bad", bad["code"]
    made = Write.write_link(rl, "default", "dub", { "sourceId" => "z", "slug" => "fine", "domain" => "www.Go.Brand.com", "name" => "", "url" => "https://a.com/z", "createdAt" => 0 },
                            { "clicks" => [{ "ts" => 5_000, "visit" => "v", "path" => "/fine", "query" => "?utm_campaign=c" }] })
    assert_equal({ "status" => "created", "clicks" => 1 }, made)
    link = rl.store.link_by_slug("fine")
    assert_equal ["go.brand.com", "fine", Write.imported_link_id("dub", "z")], [link["domain"], link["name"], link["id"]]
    assert_equal "c", rl.store.db.all("SELECT utm_campaign FROM rl_sessions")[0]["utm_campaign"]
    again = Write.write_link(rl, "default", "dub", { "sourceId" => "z", "slug" => "fine", "domain" => "", "name" => "", "url" => "https://a.com/z", "createdAt" => 0 }, {})
    assert_equal({ "status" => "skipped", "clicks" => 0 }, again, "the same link again")
  end
end
