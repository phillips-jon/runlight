# frozen_string_literal: true

require "test_helper"
require "rack"
require "rack/mock"

# The standalone server's own behaviour, as packages/server/test/server.test.ts checks the Node one's.
class ServerStandaloneTest < Minitest::Test
  Json = Runlight::Json
  Request = Runlight::Http::Request
  Standalone = Runlight::Server::Standalone

  ORIGIN = "https://stats.example.com"
  CODE = "one-time-code"

  def setup
    @now = 1_791_374_400_000 # 2026-10-07 12:00 UTC
  end

  def make(options = {}, kind = "sqlite")
    Standalone.new({
      "store" => Databases.fresh(kind),
      "secret" => "s" * 64,
      "now" => -> { @now },
      "setupCode" => CODE,
    }.merge(options))
  end

  def req(path, method = "GET", headers = {}, body = "", host: nil)
    Request.new("#{host.nil? ? ORIGIN : "https://#{host}"}#{path}", method: method, headers: headers, body: body)
  end

  def form(path, fields, headers = {})
    req(path, "POST", { "content-type" => "application/x-www-form-urlencoded" }.merge(headers),
        Runlight::Http::SearchParams.new(fields).to_s)
  end

  def cookie_of(response)
    (response.headers.get("set-cookie") || "").split(";")[0].to_s
  end

  def json(body)
    Json.encode(body)
  end

  def each_kind(&block)
    Databases.kinds.each(&block)
  end

  def test_a_new_server_is_locked_until_the_setup_code_makes_the_first_account
    each_kind do |kind|
      server = make({ "setupWhere" => "in setup.txt" }, kind)
      assert_equal 403, server.handle(req("/")).status, "the dashboard waits for setup"
      assert_includes server.handle(req("/")).text, "Open the setup link in setup.txt"
      assert_equal 403, server.handle(req("/setup?code=wrong")).status
      assert_equal 403, server.handle(form("/setup", { "code" => "wrong", "email" => "a@b.co", "password" => "long enough pw" })).status
      assert_equal 200, server.handle(req("/setup?code=#{CODE}")).status
      mismatch = server.handle(form("/setup", { "code" => CODE, "email" => "a@b.co", "password" => "a long password", "again" => "a long pasword" }))
      assert_equal 400, mismatch.status, "the password is asked twice"
      made = server.handle(form("/setup", { "code" => CODE, "email" => "Jon@Example.com", "password" => "a long password", "again" => "a long password" }))
      assert_equal 303, made.status
      assert_equal "/", made.headers.get("location")
      assert_equal 200, server.handle(req("/", "GET", { "cookie" => cookie_of(made) })).status, "signed straight in"
      assert_equal "/login", server.handle(req("/setup?code=#{CODE}")).headers.get("location"), "setup closes once an account exists"
    end
  end

  def test_with_no_code_the_first_account_is_made_with_the_token
    server = make({ "setupCode" => nil, "token" => "script-token" })
    assert_equal "/setup", server.handle(req("/")).headers.get("location")
    assert_equal 403, server.handle(form("/setup", { "code" => "wrong", "email" => "a@b.co", "password" => "a long password", "again" => "a long password" })).status
    made = server.handle(form("/setup", { "code" => "script-token", "email" => "a@b.co", "password" => "a long password", "again" => "a long password" }))
    assert_equal 303, made.status
  end

  def test_sign_in_sign_out_and_sessions_that_end_with_a_password_change
    server = make
    server.accounts.set_password("jon@example.com", "a long password", @now)
    away = server.handle(req("/?period=7d"))
    assert_equal 303, away.status
    assert_equal "/login?next=#{Runlight::Js.encode_uri_component("/?period=7d")}", away.headers.get("location")
    assert_equal 401, server.handle(req("/api/sites")).status
    assert_equal 401, server.handle(form("/login", { "email" => "jon@example.com", "password" => "nope nope nope" })).status

    ok = server.handle(form("/login", { "email" => "JON@example.com", "password" => "a long password", "next" => "//evil.example" }))
    assert_equal 303, ok.status
    assert_equal "/", ok.headers.get("location"), "a next address off this server is ignored"
    cookie = cookie_of(ok)
    assert_equal 200, server.handle(req("/api/sites", "GET", { "cookie" => cookie })).status
    assert_includes server.handle(req("/", "GET", { "cookie" => cookie })).text, 'data-sign-out="/logout"'
    assert_includes server.handle(req("/logout")).headers.get("set-cookie").to_s, "Max-Age=0"

    server.accounts.set_password("jon@example.com", "another long password", @now)
    assert_equal 401, server.handle(req("/api/sites", "GET", { "cookie" => cookie })).status, "a new password signs out every browser"
  end

  def test_sites_are_added_counted_and_short_links_answer_on_their_own_domains
    each_kind do |kind|
      server = make({ "token" => "script-token" }, kind)
      server.accounts.set_password("jon@example.com", "a long password", @now)
      auth = { "authorization" => "Bearer script-token", "content-type" => "application/json" }

      assert_equal 201, server.handle(req("/api/sites", "POST", auth, json({ "name" => "Blog", "hostnames" => "blog.example.com" }))).status
      assert_equal 200, server.handle(req("/s.js")).status
      hit = server.handle(req("/e", "POST", { "user-agent" => "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for" => "203.0.113.9" },
                              json({ "k" => "pageview", "u" => "https://blog.example.com/post", "s" => "blog.example.com" })))
      assert_equal 202, hit.status
      stats = Json.decode(server.handle(req("/api/stats?site=blog.example.com&period=today", "GET", auth)).text)
      assert_equal 1, stats["stats"]["pageviews"]

      assert_equal 201, server.handle(req("/api/link-domains?site=blog.example.com", "POST", auth, json({ "domain" => "go.example.com" }))).status
      made = Json.decode(server.handle(req("/api/links?site=blog.example.com", "POST", auth,
                                           json({ "url" => "https://blog.example.com/launch", "slug" => "launch", "domain" => "go.example.com" }))).text)
      assert_equal "launch", made["link"]["slug"]
      short = server.handle(req("/launch", host: "go.example.com"))
      assert_equal 302, short.status
      assert_equal "https://blog.example.com/launch", short.headers.get("location")
      assert_equal 302, server.handle(req("/go/launch")).status, "every link also answers at /go/:slug on the server itself"

      health = server.handle(req("/healthz"))
      assert_equal [200, "ok"], [health.status, health.text]
      assert_equal 401, server.handle(req("/api/sites", "GET", { "authorization" => "Bearer wrong" })).status
    end
  end

  def test_a_link_domain_never_takes_over_the_dashboards_own_name_sign_in_or_api
    server = make({ "token" => "script-token" })
    server.accounts.set_password("jon@example.com", "a long password", @now)
    auth = { "authorization" => "Bearer script-token", "content-type" => "application/json" }
    server.handle(req("/api/sites", "POST", auth, json({ "name" => "Blog", "hostnames" => "blog.example.com" })))
    add_domain = ->(domain, host) { server.handle(req("/api/link-domains?site=blog.example.com", "POST", auth, json({ "domain" => domain }), host: host)) }

    # Someone signs in at stats.example.com, so a caller naming another Host cannot add it afterwards.
    cookie = cookie_of(server.handle(form("/login", { "email" => "jon@example.com", "password" => "a long password" })))
    assert_equal 200, server.handle(req("/api/sites", "GET", { "cookie" => cookie })).status
    ["decoy.example.org", "203.0.113.5", "stats.example.com."].each do |host|
      assert_equal 400, add_domain.call("stats.example.com", host).status, host
    end

    # Added anyway: its short links answer, and the server's own pages stay the server's.
    server.runlight.store.add_link_domain("stats.example.com", "blog.example.com", @now)
    server.runlight.forget_link_domains
    server.handle(req("/api/links?site=blog.example.com", "POST", auth, json({ "url" => "https://blog.example.com/a", "slug" => "login", "domain" => "stats.example.com" })))
    server.handle(req("/api/links?site=blog.example.com", "POST", auth, json({ "url" => "https://blog.example.com/b", "slug" => "sale", "domain" => "stats.example.com" })))
    assert_equal 302, server.handle(req("/sale")).status
    assert_equal 200, server.handle(req("/login")).status, "sign-in is still the sign-in page"
    assert_equal 200, server.handle(req("/", "GET", { "cookie" => cookie })).status, "the dashboard opens for someone signed in"
    assert_equal 404, server.handle(req("/")).status
    assert_equal 200, server.handle(req("/api/link-domains/stats.example.com?site=blog.example.com", "DELETE", { "cookie" => cookie })).status, "so it can be removed"
    assert_equal 404, server.handle(req("/sale")).status

    # With the public address set, short links never answer there, and nobody can add it under any Host.
    named = make({ "token" => "script-token", "url" => ORIGIN })
    named.handle(req("/api/sites", "POST", auth, json({ "name" => "Blog", "hostnames" => "blog.example.com" })))
    assert_equal 400, named.handle(req("/api/link-domains?site=blog.example.com", "POST", auth, json({ "domain" => "stats.example.com" }), host: "decoy.example.org")).status
    named.runlight.store.add_link_domain("stats.example.com", "blog.example.com", @now)
    named.runlight.forget_link_domains
    named.handle(req("/api/links?site=blog.example.com", "POST", auth, json({ "url" => "https://blog.example.com/b", "slug" => "sale", "domain" => "stats.example.com" })))
    assert_equal 404, named.handle(req("/sale")).status
    assert_equal 403, named.handle(req("/")).status, "the dashboard, waiting for setup"
  end

  def test_only_the_owner_and_admins_teach_the_server_its_names
    server = make
    owner = server.accounts.set_password("jon@example.com", "a long password", @now)
    viewer = server.accounts.set_password("viewer@example.com", "another long one", @now, "viewer")
    as = ->(user) { "runlight_session=#{Runlight::Js.encode_uri_component(server.accounts.session_for(user, @now))}" }
    names = -> { Json.decode(server.runlight.store.setting("server-hosts") || "[]") }
    25.times do |i|
      server.handle(req("/api/sites", "GET", { "cookie" => as.call(viewer), "x-forwarded-host" => "junk#{i}.example.org" }))
    end
    assert_equal [], names.call, "a viewer's made-up forwarded names fill nothing"
    server.handle(req("/api/sites", "GET", { "cookie" => as.call(owner), "x-forwarded-host" => "203.0.113.7:8080" }))
    server.handle(req("/api/sites", "GET", { "cookie" => as.call(owner) }))
    assert_equal ["stats.example.com"], names.call, "an owner's are learned, if they are domain names"

    # Another process serving the same database reads them back from it.
    again = Standalone.new({ "store" => server.runlight.store, "secret" => "s" * 64, "now" => -> { @now } })
    headers = { "cookie" => as.call(owner), "content-type" => "application/json" }
    again.handle(req("/api/sites", "POST", headers, json({ "name" => "Blog", "hostnames" => "blog.example.com" })))
    assert_equal 400, again.handle(req("/api/link-domains?site=blog.example.com", "POST", headers, json({ "domain" => "stats.example.com" }), host: "decoy.example.org")).status
  end

  def test_check_runs_the_scheduled_work
    assert_equal({ "ok" => true, "reports" => { "sent" => 0, "failed" => 0 } }, make.check)
  end

  # The Rack app: the request read from Rack's env, X-Forwarded-Proto for the scheme, HEAD answered without a body,
  # bodies past the limits refused as the Node server refuses them, and the work after answering run once the body
  # is closed.
  def test_the_rack_app
    server = make({ "token" => "script-token" })
    # As Standalone.app starts it.
    server.runlight.init
    status, headers, body = server.call(Rack::MockRequest.env_for("http://stats.example.com/healthz", "REMOTE_ADDR" => "203.0.113.9"))
    text = +""
    body.each { |part| text << part }
    body.close
    assert_equal [200, "text/plain", "ok"], [status, headers["content-type"], text]

    status, _, body = server.call(Rack::MockRequest.env_for("http://stats.example.com/healthz", method: "HEAD"))
    parts = []
    body.each { |part| parts << part }
    body.close
    assert_equal [200, []], [status, parts]

    status, headers, body = server.call(Rack::MockRequest.env_for("http://stats.example.com/e", method: "POST", input: "x" * (16 * 1024 + 1)))
    text = +""
    body.each { |part| text << part }
    assert_equal [413, "application/json", '{"error":"That request is too large"}'], [status, headers["content-type"], text]
    status, = server.call(Rack::MockRequest.env_for("http://stats.example.com/api/sites", method: "POST", input: "x" * (16 * 1024 + 1),
                                                                                           "HTTP_AUTHORIZATION" => "Bearer script-token", "CONTENT_TYPE" => "application/json"))
    assert_equal 400, status, "the limit is 16 KB for collection only"

    # Behind a proxy that ends TLS, the session cookie is still marked secure.
    server.accounts.set_password("jon@example.com", "a long password", @now)
    login = "email=jon%40example.com&password=a+long+password"
    _, plain, = server.call(Rack::MockRequest.env_for("http://stats.example.com/login", method: "POST", input: login,
                                                                                       "CONTENT_TYPE" => "application/x-www-form-urlencoded"))
    _, forwarded, = server.call(Rack::MockRequest.env_for("http://stats.example.com/login", method: "POST", input: login,
                                                                                           "CONTENT_TYPE" => "application/x-www-form-urlencoded", "HTTP_X_FORWARDED_PROTO" => "https"))
    refute_match(/;\s*Secure/i, plain["set-cookie"].to_s)
    assert_match(/;\s*Secure/i, forwarded["set-cookie"].to_s)
  end
end
