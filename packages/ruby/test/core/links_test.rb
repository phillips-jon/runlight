# frozen_string_literal: true

require "test_helper"
require_relative "../support/core_test_case"

# Short links, as links.test.ts tests them: made through Links, followed through link_handler and link_domain_response.
class CoreLinksTest < CoreTestCase
  Request = Runlight::Http::Request

  # A link domain added as the routes add one.
  def add_domain(t, domain, site = "default")
    t.store.add_link_domain(domain, site, t.now)
    t.rl.forget_link_domains
  end

  def remove_domain(t, domain)
    t.store.remove_link_domain(domain)
    t.rl.forget_link_domains
  end

  on_every_database("create follow and count a short link") do |kind|
    t = Harness.new(kind)
    link = t.rl.links.create("default", { "url" => "https://thedailypreset.com/presets/golden?ref=x" })
    assert_match(/\A[a-z2-9]{6}\z/, link["slug"])
    assert_equal "thedailypreset.com/presets/golden", link["name"]

    follow = t.rl.link_handler
    go = lambda do |path, headers = {}|
      follow.call(Request.new("https://example.com#{path}", headers: { "user-agent" => Harness::CHROME_MAC, "x-forwarded-for" => "203.0.113.9" }.merge(headers)))
    end
    response = go.call("/go/#{link["slug"]}?utm_source=newsletter&utm_medium=email", { "referer" => "https://mail.google.com/" })
    assert_equal 302, response.status
    assert_equal "https://thedailypreset.com/presets/golden?ref=x", response.headers.get("location")
    assert_equal "no-store", response.headers.get("cache-control")
    assert_equal "no-referrer-when-downgrade", response.headers.get("referrer-policy")
    missing = go.call("/go/nope")
    assert_equal 404, missing.status
    assert_equal "Not found", missing.text
    assert_equal "text/plain; charset=utf-8", missing.headers.get("content-type")
    # Link previews and crawlers are sent on but not counted.
    assert_equal 302, go.call("/go/#{link["slug"]}", { "user-agent" => "facebookexternalhit/1.1" }).status

    today = t.today
    list = t.store.links("default", today["from"], today["to"])
    assert_equal 1, list[0]["clicks"]
    assert_equal 1, list[0]["visitors"]
    assert_equal [{ "value" => "Newsletter", "visitors" => 1, "events" => 1 }],
                 t.store.link_breakdown("default", link["id"], today["from"], today["to"], "source", 10)

    # Clicks are not visits: the site's own numbers do not move.
    site = t.stats(today)
    assert_equal 0, site["visitors"]
    assert_equal 0, site["pageviews"]
  end

  on_every_database("slugs are checked unique per domain and freed by deleting") do |kind|
    t = Harness.new(kind)
    links = t.rl.links
    links.create("default", { "url" => "https://a.com", "slug" => "launch" })
    e = assert_raises(Runlight::LinkError) { links.create("default", { "url" => "https://b.com", "slug" => "launch" }) }
    assert_includes e.message, "taken"
    assert_equal ["link_taken", { "slug" => "launch" }], [e.code, e.params], "a code the dashboard can translate"
    [
      [{ "url" => "https://b.com", "slug" => "has space" }, "link_slug"],
      [{ "url" => "javascript:alert(1)" }, "link_protocol"],
      [{ "url" => "not a url" }, "link_url"],
      [{ "url" => "https://b.com", "domain" => "t.unknown.com" }, "link_domain"],
    ].each do |input, code|
      e = assert_raises(Runlight::LinkError, code) { links.create("default", input) }
      assert_equal code, e.code
    end
    id = t.store.links("default", 0, t.now + 1)[0]["id"]
    renamed = links.update(id, { "slug" => "launch-2", "name" => "Launch" })
    assert_equal "launch-2", renamed["slug"]
    assert_equal "Launch", renamed["name"]
    assert_equal "https://a.com/", renamed["url"], "a key left out is left alone"
    links.remove(id)
    links.create("default", { "url" => "https://c.com", "slug" => "launch-2" })
    assert_equal 1, t.store.links("default", 0, t.now + 1).length, "a deleted link's slug is free again"
    assert_raises(RangeError) { links.remove("nope") }
  end

  on_every_database("custom link domains answer at their root and only for their own links") do |kind|
    t = Harness.new(kind)
    t.rl.init
    add_domain(t, "t.thedailypreset.com")
    t.rl.links.create("default", { "url" => "https://thedailypreset.com/a", "slug" => "a", "domain" => "t.thedailypreset.com" })
    t.rl.links.create("default", { "url" => "https://example.com/b", "slug" => "b" })

    at = ->(host, path) { t.rl.link_domain_response(Request.new("https://#{host}#{path}", headers: { "host" => host, "user-agent" => Harness::CHROME_MAC })) }
    assert_equal "https://thedailypreset.com/a", at.call("t.thedailypreset.com", "/a")&.headers&.get("location")
    assert_equal 404, at.call("t.thedailypreset.com", "/b")&.status, "the main site's links are not on the link domain"
    assert_nil at.call("example.com", "/a"), "other hosts carry on as normal"
    assert_nil at.call("t.thedailypreset.com", "/runlight/api/sites"), "the dashboard's own paths are left alone"
    # The app's own link path answers for every link, as a fallback that never changes.
    assert_equal 302, t.rl.link_handler.call(Request.new("https://example.com/go/a", headers: { "user-agent" => Harness::CHROME_MAC })).status
    check = at.call("t.thedailypreset.com", Runlight::Core::LINK_DOMAIN_CHECK)
    assert_equal '{"runlight":true,"domain":"t.thedailypreset.com"}', check&.text
    assert_equal "application/json", check&.headers&.get("content-type")

    # Removing the domain keeps its links: they fall back to the app's own path.
    remove_domain(t, "t.thedailypreset.com")
    assert_nil at.call("t.thedailypreset.com", "/a"), "the removed domain is no longer answered"
    assert_equal "https://thedailypreset.com/a",
                 t.rl.link_handler.call(Request.new("https://example.com/go/a", headers: { "user-agent" => Harness::CHROME_MAC })).headers.get("location")
    a = t.store.links("default", 0, t.now + 1).find { |l| l["slug"] == "a" }
    assert_equal "t.thedailypreset.com", a["domain"], "the link remembers its domain"

    # Adding it back brings the links home again.
    add_domain(t, "t.thedailypreset.com")
    assert_equal "https://thedailypreset.com/a", at.call("t.thedailypreset.com", "/a")&.headers&.get("location")
  end

  on_every_database("a slug is unique across every domain") do |kind|
    t = Harness.new(kind)
    t.rl.init
    add_domain(t, "t.a.com")
    t.rl.links.create("default", { "url" => "https://a.com/sale", "slug" => "sale", "domain" => "t.a.com" })
    assert_raises(Runlight::LinkError) { t.rl.links.create("default", { "url" => "https://b.com/sale", "slug" => "sale" }) }
  end

  on_every_database("csv rows in the umami forks format import and bad rows say why") do |kind|
    t = Harness.new(kind)
    t.rl.init
    add_domain(t, "t.thedailypreset.com")
    result = t.rl.links.import("default", [
      { "link_name" => "Golden hour", "destination_url" => "https://thedailypreset.com/golden", "link_slug" => "golden", "tracking_domain" => "t.thedailypreset.com" },
      { "name" => "Plain", "url" => "https://example.com/plain" },
      { "name" => "Broken", "url" => "not a url" },
      { "name" => "Duplicate", "url" => "https://example.com/x", "slug" => "golden", "domain" => "t.thedailypreset.com" },
    ])
    assert_equal 2, result["created"]
    assert_equal [3, 4], result["failed"].map { |f| f["row"] }
    assert_equal '{"row":3,"reason":"The destination must be a full URL, starting with https://","code":"link_url","params":{}}',
                 Runlight::Json.encode(result["failed"][0])
    links = t.store.links("default", 0, t.now + 1)
    assert_equal 2, links.length
    assert(links.any? { |l| l["domain"] == "t.thedailypreset.com" && l["slug"] == "golden" })
  end

  def test_a_link_on_another_sites_domain_is_refused
    rl = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "sites" => [{ "id" => "a", "hostnames" => ["a.com"] }, { "id" => "b", "hostnames" => ["b.com"] }] })
    rl.init
    rl.store.add_link_domain("go.a.com", "a", 0)
    assert_equal "go.a.com", rl.links.create("a", { "url" => "https://a.com/x", "domain" => "go.a.com" })["domain"]
    assert_raises(Runlight::LinkError) { rl.links.create("b", { "url" => "https://b.com/x", "domain" => "go.a.com" }) }
  end

  def test_a_click_is_counted_as_a_click_with_its_source_and_never_with_an_address
    t = Harness.new("sqlite")
    link = t.rl.links.create("default", { "url" => "https://a.com/", "slug" => "x" })
    t.rl.link_handler.call(Request.new("https://example.com/go/x", headers: {
      "user-agent" => Harness::CHROME_MAC, "x-forwarded-for" => "192.0.2.77", "accept-language" => "fr-CA,fr;q=0.9", "host" => "example.com:8080",
    }))
    event = t.store.db.all("SELECT kind, name, link, path, hostname FROM rl_events")[0]
    assert_equal({ "kind" => "click", "name" => "x", "link" => link["id"], "path" => "/go/x", "hostname" => "example.com" }, event.transform_values(&:to_s))
    session = t.store.db.all("SELECT language, pageviews FROM rl_sessions")[0]
    assert_equal "fr-CA", session["language"]
    refute_includes Runlight::Json.encode(t.store.db.all("SELECT * FROM rl_sessions")), "192.0.2.77"
    # A HEAD request, as a link checker sends, is answered and not counted.
    t.rl.link_handler.call(Request.new("https://example.com/go/x", method: "HEAD", headers: { "user-agent" => Harness::CHROME_MAC }))
    assert_equal 1, t.count("SELECT COUNT(*) AS n FROM rl_events")
  end
end
