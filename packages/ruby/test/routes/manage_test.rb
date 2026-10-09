# frozen_string_literal: true

require "test_helper"
require_relative "make"

# manage.test.ts, ported: what a hub's manage token may change, link domains kept off the dashboard's own names,
# and a hub that never shows an install's answer as a page.
class RoutesManageTest < RoutesTestCase
  Json = Runlight::Json
  Request = Runlight::Http::Request
  Response = Runlight::Http::Response

  # A mail webhook that keeps what it is sent, standing in for the small HTTP server manage.test.ts starts.
  class MailCatcher
    attr_reader :mail

    def initialize
      @mail = []
    end

    def fetch(_url, init = {})
      @mail << Json.decode((init["body"] || "{}").to_s)
      Response.new("ok")
    end
  end

  # An app with two sites and an owner token, as a hub would connect to.
  def app(options = {})
    rl = RoutesMake.runlight({ "sites" => [{ "id" => "blog", "hostnames" => ["blog.example.com"] }, { "id" => "shop", "hostnames" => ["shop.example.com"] }] }.merge(options))
    routes = rl.routes({ "token" => "owner", "origin" => "https://app.example.com" })
    call = lambda do |method, path, auth, body = nil|
      headers = { "authorization" => "Bearer #{auth}" }
      headers["content-type"] = "application/json" unless body.nil?
      answer = routes.handle(Request.new("https://app.example.com/runlight#{path}", method: method, headers: headers, body: body.nil? ? "" : Json.encode(body)))
      { "status" => answer.status, "body" => Json.try_decode(answer.text) }
    end
    make = ->(scope, site) { call.call("POST", "/api/tokens", "owner", { "name" => "Hub", "scope" => scope, "site" => site })["body"]["secret"] }
    [rl, call, make]
  end

  def test_a_manage_token_changes_its_own_sites_settings_and_nothing_else
    _, call, make = app
    assert_equal 400, call.call("POST", "/api/tokens", "owner", { "name" => "Hub", "scope" => "manage" })["status"], "a manage token is for one site"
    manage = make.call("manage", "blog")

    assert_equal({ "scope" => "manage", "site" => "blog" }, call.call("GET", "/api/token", manage)["body"])
    assert_equal 201, call.call("POST", "/api/goals?site=blog", manage, { "name" => "Signup", "kind" => "event", "match" => "Signup" })["status"]
    assert_equal 201, call.call("POST", "/api/goals", manage, { "name" => "No site given", "kind" => "event", "match" => "x" })["status"], "its site is assumed"
    assert_equal 2, call.call("GET", "/api/goals?site=blog", "owner")["body"]["goals"].length
    assert_equal 404, call.call("POST", "/api/goals?site=shop", manage, { "name" => "Elsewhere", "kind" => "event", "match" => "x" })["status"], "never another site"
    assert_equal 0, call.call("GET", "/api/goals?site=shop", "owner")["body"]["goals"].length
    assert_equal 404, call.call("PATCH", "/api/sites/shop", manage, { "name" => "Mine now" })["status"]
    assert_equal 403, call.call("PATCH", "/api/sites/blog", manage, { "hostnames" => "evil.example" })["status"]

    # Everything beyond one site's settings stays the owner's.
    assert_equal 401, call.call("GET", "/api/tokens", manage)["status"]
    assert_equal 403, call.call("POST", "/api/tokens", manage, { "name" => "More", "site" => "blog" })["status"]
    assert_equal 403, call.call("PUT", "/api/mail", manage, { "service" => "webhook" })["status"]
    assert_equal 200, call.call("GET", "/api/mail?site=blog", manage)["status"], "it can see which mail service sends reports"
    assert_equal 201, call.call("POST", "/api/shares?site=blog", manage, { "name" => "For the team" })["status"], "share links for its site are its to make"
    assert_equal 404, call.call("POST", "/api/shares?site=shop", manage, { "name" => "x" })["status"]
    assert_equal 403, call.call("DELETE", "/api/sites/blog", manage)["status"]
    assert_equal 403, call.call("POST", "/api/links/import?site=blog", manage, { "rows" => [] })["status"]

    assert_equal 201, call.call("POST", "/api/links?site=blog", manage, { "url" => "https://example.org/", "slug" => "hello" })["status"]
    assert_equal 1, call.call("GET", "/api/links?site=blog", manage)["body"]["links"].length
    assert_equal 201, call.call("POST", "/api/reports?site=blog", manage, { "email" => "me@example.com" })["status"]
    assert_equal 200, call.call("PATCH", "/api/sites/blog", manage, { "name" => "The blog", "retentionMonths" => 12 })["status"]
  end

  def test_a_read_token_still_only_reads
    _, call, make = app
    read = make.call("read", "blog")
    assert_equal({ "scope" => "read", "site" => "blog" }, call.call("GET", "/api/token", read)["body"])
    assert_equal 403, call.call("POST", "/api/goals?site=blog", read, { "name" => "Signup", "kind" => "event", "match" => "Signup" })["status"]
    assert_equal 200, call.call("GET", "/api/stats?site=blog&period=today", read)["status"]
  end

  def test_a_link_domain_can_never_be_where_the_dashboard_or_a_counted_site_lives
    _, call, = app
    assert_equal 400, call.call("POST", "/api/link-domains?site=blog", "owner", { "domain" => "app.example.com" })["status"], "the dashboard's own host"
    assert_equal 400, call.call("POST", "/api/link-domains?site=blog", "owner", { "domain" => "shop.example.com" })["status"], "a site's domain"
    assert_equal 201, call.call("POST", "/api/link-domains?site=blog", "owner", { "domain" => "go.example.com" })["status"]
  end

  def test_link_domains_stay_off_the_configured_address_and_the_names_people_signed_in_from
    sent = MailCatcher.new
    rl = RoutesMake.runlight({ "sites" => [{ "id" => "blog", "hostnames" => ["blog.example.com"] }], "fetcher" => sent, "secret" => "k" })
    routes = rl.routes({ "token" => "owner", "origin" => "https://stats.example.com", "ownHosts" => -> { ["dash.example.net:443"] } })
    call = lambda do |method, path, auth = "owner", body = nil|
      routes.handle(Request.new("https://decoy.example.org/runlight#{path}", method: method,
                                                                          headers: { "authorization" => "Bearer #{auth}", "content-type" => "application/json" },
                                                                          body: body.nil? ? "" : Json.encode(body)))
    end
    add = ->(domain) { call.call("POST", "/api/link-domains?site=blog", "owner", { "domain" => domain }).status }
    ["stats.example.com", "stats.example.com.", "www.stats.example.com", "dash.example.net", "decoy.example.org"].each do |taken|
      assert_equal 400, add.call(taken), taken
    end
    # Names inside private networks, which the check would make the install fetch.
    ["metadata.google.internal", "db.corp", "printer.local", "nas.home.arpa", "router.lan", "10.0.0.5.nip.io", "app.localhost"].each do |inside|
      assert_equal 400, add.call(inside), inside
    end
    assert_equal 201, add.call("go.example.org")
    # One saved before that rule is never fetched.
    rl.store.add_link_domain("db.internal", "blog", 0)
    check = RoutesMake.body(call.call("GET", "/api/link-domains/db.internal/check?site=blog"))
    assert check.key?("target"), "and where a domain should point"
    check.delete("target")
    assert_equal({ "domain" => "db.internal", "working" => false, "reason" => "is not a public domain name", "code" => "check_not_public" }, check)

    # A hub's reports link to the configured address, never to the Host it names, and its samples share one wait.
    rl.save_mail_settings({ "service" => "webhook", "url" => "https://hooks.example.net/mail", "from" => "reports@example.com" })
    manage = RoutesMake.body(call.call("POST", "/api/tokens", "owner", { "name" => "Hub", "scope" => "manage", "site" => "blog" }))["secret"]
    first = RoutesMake.body(call.call("POST", "/api/reports?site=blog", manage, { "email" => "a@example.com" }))["report"]
    second = RoutesMake.body(call.call("POST", "/api/reports?site=blog", manage, { "email" => "b@example.com" }))["report"]
    assert_equal ["https://stats.example.com/runlight", "https://stats.example.com/runlight"], rl.store.reports("blog").map { |r| r["origin"] }
    assert_equal 200, call.call("POST", "/api/reports/#{first["id"]}/send?site=blog", manage).status, "the first sample goes out"
    assert_equal 1, sent.mail.length
    assert_equal "a@example.com", sent.mail[0]["to"]
    assert_includes sent.mail[0]["text"], "https://stats.example.com/runlight", "its links point at the configured address"
    waits = call.call("POST", "/api/reports/#{second["id"]}/send?site=blog", manage)
    assert_equal 429, waits.status, "another report waits too"
    assert_equal "sample_soon_hub", RoutesMake.body(waits)["code"]
    call.call("DELETE", "/api/reports/#{second["id"]}?site=blog", manage)
    again = RoutesMake.body(call.call("POST", "/api/reports?site=blog", manage, { "email" => "b@example.com" }))["report"]
    assert_equal 429, call.call("POST", "/api/reports/#{again["id"]}/send?site=blog", manage).status, "and so does one added again"
    assert_equal 1, sent.mail.length
  end

  def test_without_its_own_address_an_app_gives_a_hub_no_link_domains_or_reports
    # As the quickstart sets it up: one site, no origin, and the app answers on more names than the site's.
    rl = RoutesMake.runlight({ "site" => { "name" => "example.com", "hostnames" => ["example.com"] } })
    routes = rl.routes({ "token" => "owner" })
    call = lambda do |host, method, path, auth, body = nil|
      headers = { "host" => host, "authorization" => "Bearer #{auth}" }
      headers["content-type"] = "application/json" unless body.nil?
      answer = routes.handle(Request.new("https://#{host}/runlight#{path}", method: method, headers: headers, body: body.nil? ? "" : Json.encode(body)))
      { "status" => answer.status, "body" => Json.try_decode(answer.text) }
    end
    manage = call.call("app.example.com", "POST", "/api/tokens", "owner", { "name" => "Hub", "site" => "default", "scope" => "manage" })["body"]["secret"]
    # From the deployment's other name, where the app's own name is not the request's Host.
    add = call.call("example-app.vercel.app", "POST", "/api/link-domains", manage, { "domain" => "app.example.com" })
    assert_equal 400, add["status"]
    assert_equal "origin_needed", add["body"]["code"]
    assert_equal "origin_needed", call.call("example-app.vercel.app", "POST", "/api/reports", manage, { "email" => "cfo@example.com" })["body"]["code"]
    assert_equal 201, call.call("app.example.com", "POST", "/api/link-domains", "owner", { "domain" => "go.example.com" })["status"], "the owner still adds them"

    # On a link domain the dashboard's paths pass to the app, so the owner can always reach it there.
    ["/runlight", "/runlight/api/sites"].each do |path|
      assert_nil rl.link_domain_response(Request.new("https://go.example.com#{path}", headers: { "host" => "go.example.com" })), path
    end
    assert_equal 404, rl.link_domain_response(Request.new("https://go.example.com/nothing", headers: { "host" => "go.example.com" }))&.status
    # Middleware that never made the routes leaves the default path alone too.
    apart = RoutesMake.runlight({ "store" => rl.store, "site" => { "name" => "example.com", "hostnames" => ["example.com"] } })
    assert_nil apart.link_domain_response(Request.new("https://go.example.com/runlight", headers: { "host" => "go.example.com" }))
  end

  def test_the_hub_never_passes_on_an_installs_answer_as_a_page_nor_follows_its_redirects
    evil = Object.new
    def evil.fetch(url, _init = {})
      path = Runlight::Http::Url.new(url).pathname
      if path.start_with?("/runlight/api/sites")
        Response.new(Json.encode({ "sites" => [{ "id" => "x", "name" => "X", "timezone" => "UTC", "hostnames" => ["x.example.com"] }] }), status: 200, headers: { "content-type" => "application/json" })
      elsif path.start_with?("/runlight/api/stats")
        Response.new("<script>alert(1)</script>", status: 200, headers: { "content-type" => "text/html" })
      elsif path.start_with?("/runlight/api/series")
        Response.new("", status: 302, headers: { "location" => "http://169.254.169.254/" })
      elsif path.start_with?("/runlight/api/rhythm")
        Response.new(Json.encode({ "error" => "Your session ended. Sign in again at https://evil.example/login #{"x" * 1000}", "code" => "link_taken", "params" => { "slug" => "a", "n" => 5 } }),
                     status: 400, headers: { "content-type" => "application/json" })
      else
        Response.new("{}", status: 404)
      end
    end
    hub = RoutesMake.runlight({ "managedSites" => true, "secret" => "k" * 32, "fetcher" => evil })
    routes = hub.routes({ "token" => "owner" })
    call = lambda do |path, method = "GET", body = nil|
      routes.handle(Request.new("https://hub.example.com/runlight#{path}", method: method, headers: { "authorization" => "Bearer owner", "content-type" => "application/json" }, body: body || ""))
    end
    added = call.call("/api/sites", "POST", Json.encode({ "remote" => { "url" => "http://127.0.0.1:9/runlight", "token" => "rl_x" } }))
    id = RoutesMake.body(added)["site"]["id"]
    page = call.call("/api/stats?site=#{id}&period=today")
    assert_match(%r{\Aapplication/json}, page.headers.get("content-type") || "")
    assert_equal "nosniff", page.headers.get("x-content-type-options")
    assert_match(/default-src 'none'/, page.headers.get("content-security-policy") || "")
    assert_equal 502, call.call("/api/series?site=#{id}&period=today").status, "a redirect is reported, not followed"
    # An install's error says where it came from, short, with only its code and string params.
    said = RoutesMake.body(call.call("/api/rhythm?site=#{id}&period=today"))
    assert_match(/\A127\.0\.0\.1:9: Your session ended/, said["error"])
    assert_operator said["error"].bytesize, :<, 340
    assert_equal "link_taken", said["code"]
    assert_equal({ "slug" => "a" }, said["params"])
  end
end
