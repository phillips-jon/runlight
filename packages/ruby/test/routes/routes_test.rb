# frozen_string_literal: true

require "test_helper"
require_relative "make"

# routes.test.ts, ported, then the unit checks of the routes' own helpers: cookies, bearer tokens, JSON-only
# writes, and the dashboard's page.
class RoutesRoutesTest < RoutesTestCase
  Json = Runlight::Json
  Routes = Runlight::Routes
  Version = Runlight::Version

  def req(...)
    RoutesMake.req(...)
  end

  def test_the_tracker_is_public_cached_and_answers_304_to_its_etag
    routes = RoutesMake.runlight.routes({ "token" => "secret" })
    first = routes.handle(req("/runlight/s.js"))
    assert_equal 200, first.status
    assert_match(/javascript/, first.headers.get("content-type") || "")
    assert_match(/sendBeacon/, first.text)
    etag = first.headers.get("etag") || ""
    assert etag.start_with?("\"#{Version.build["trackerHash"]}-"), "the etag covers the script and its click rules"
    again = routes.handle(req("/runlight/s.js", "GET", { "if-none-match" => etag }))
    assert_equal 304, again.status
  end

  def test_stats_need_the_token_as_a_bearer_or_through_the_cookie
    routes = RoutesMake.runlight.routes({ "token" => "secret" })
    assert_equal 401, routes.handle(req("/runlight/api/stats")).status
    assert_equal 401, routes.handle(req("/runlight/api/stats", "GET", { "authorization" => "Bearer wrong" })).status
    assert_equal 200, routes.handle(req("/runlight/api/stats", "GET", { "authorization" => "Bearer secret" })).status

    sign_in = routes.handle(req("/runlight/?token=secret"))
    assert_equal 303, sign_in.status
    assert_equal "/runlight/", sign_in.headers.get("location")
    cookie = sign_in.headers.get("set-cookie") || ""
    assert_includes cookie, "HttpOnly"
    assert_includes cookie, "Secure"
    refute_includes cookie, "secret", "the cookie holds a digest, not the token"
    value = cookie.split(";").first
    assert_equal 200, routes.handle(req("/runlight/api/stats", "GET", { "cookie" => value })).status
    assert_equal 200, routes.handle(req("/runlight/", "GET", { "cookie" => value })).status
  end

  def test_with_no_token_everything_but_development_refuses_writes_included
    ["production", "", "staging"].each do |value|
      value == "" ? ENV.delete("NODE_ENV") : ENV["NODE_ENV"] = value
      routes = RoutesMake.runlight.routes({})
      assert_equal 503, routes.handle(req("/runlight/api/stats")).status, "NODE_ENV=#{value == "" ? "(unset)" : value}"
      minted = routes.handle(req("/runlight/api/tokens", "POST", { "content-type" => "application/json" }, Json.encode({ "name" => "x" })))
      assert_equal 503, minted.status, "nobody can make a token on an install with no token"
    end
    ENV["NODE_ENV"] = "development"
    RoutesMake.quietly do
      assert_equal 200, RoutesMake.runlight.routes({}).handle(req("/runlight/api/stats")).status
    end
  end

  def test_authorize_replaces_the_token
    routes = RoutesMake.runlight.routes({ "authorize" => ->(r) { r.headers.get("x-admin") == "yes" } })
    assert_equal 401, routes.handle(req("/runlight/api/sites")).status
    assert_equal 200, routes.handle(req("/runlight/api/sites", "GET", { "x-admin" => "yes" })).status
  end

  def test_the_element_picker_sends_its_choice_only_to_the_dashboard_its_ticket_names
    now = RoutesMake.utc(2026, 10, 7, 12)
    rl = RoutesMake.runlight({ "sites" => [{ "id" => "blog", "hostnames" => ["blog.example.com"] }], "now" => -> { now } })
    routes = rl.routes({ "token" => "secret" })
    ask = ->(body, auth = "secret") { routes.handle(RoutesMake.owner("/runlight/api/pick?site=blog", "POST", body, auth)) }
    target = lambda do |ticket|
      script = routes.handle(req("/runlight/pick.js?runlight=pick&runlight_ticket=#{Runlight::Js.encode_uri_component(ticket)}")).text
      script.match(/var \w+="([^"]*)";if\(/)&.[](1)
    end

    assert_equal 401, ask.call({ "origin" => "https://stats.example.com" }, "wrong").status, "only the owner gets a ticket"
    assert_equal 400, ask.call({ "origin" => "javascript:alert(1)" }).status
    ticket = RoutesMake.body(ask.call({ "origin" => "https://stats.example.com" }))["ticket"]
    assert_equal "https://stats.example.com", target.call(ticket)
    # A page that opens the site some other way has no ticket, or only a changed one, and the picker sends nowhere.
    assert_equal "", target.call("")
    assert_equal "", target.call(ticket.sub(/\.[a-f0-9]+\./, ".#{"https://evil.example".unpack1("H*")}."))
    assert_equal "no-store", routes.handle(req("/runlight/pick.js")).headers.get("cache-control")
    now += 31 * 60_000
    assert_equal "", target.call(ticket), "a ticket runs out after half an hour"

    # The script also learns the site the ticket is for, and does nothing on any other site's pages.
    fresh = RoutesMake.body(ask.call({ "origin" => "https://stats.example.com" }))["ticket"]
    script = routes.handle(req("/runlight/pick.js?runlight_ticket=#{Runlight::Js.encode_uri_component(fresh)}")).text
    assert_includes script, Json.encode(Json.encode(["blog.example.com"]))
    refute_includes script, "__RUNLIGHT_PICK_HOSTS__"

    # A hub's manage token gets one only for the hub it connected from, recorded when it did.
    made = RoutesMake.body(routes.handle(RoutesMake.owner("/runlight/api/tokens", "POST", { "name" => "Hub", "scope" => "manage", "site" => "blog" })))
    manage = made["secret"]
    refused = ask.call({ "origin" => "https://hub.example.net" }, manage)
    assert_equal 403, refused.status
    assert_equal "pick_hub", RoutesMake.body(refused)["code"]
    rl.store.set_setting("token-origin:#{made["token"]["id"]}", "https://hub.example.net")
    assert_equal 403, ask.call({ "origin" => "https://evil.example" }, manage).status, "never another origin"
    hub = RoutesMake.body(ask.call({ "origin" => "https://hub.example.net" }, manage))["ticket"]
    assert_equal "https://hub.example.net", target.call(hub)
  end

  def test_the_check_endpoint_takes_the_cron_secret
    routes = RoutesMake.runlight.routes({ "token" => "secret", "cronSecret" => "cron" })
    assert_equal 401, routes.handle(req("/runlight/api/check", "POST", { "content-type" => "application/json" })).status
    assert_equal 200, routes.handle(req("/runlight/api/check", "POST", { "authorization" => "Bearer cron" })).status
    assert_equal 200, routes.handle(req("/runlight/api/check", "POST", { "authorization" => "Bearer secret" })).status
    routes = RoutesMake.runlight.routes({ "token" => "secret", "cronSecret" => "cron" })
    assert_equal 200, routes.handle(req("/runlight/api/check", "GET", { "authorization" => "Bearer cron" })).status, "Vercel Cron sends GET"
    assert_equal 401, routes.handle(req("/runlight/api/check")).status
  end

  def test_base_path_moves_everything
    routes = RoutesMake.runlight.routes({ "token" => "secret", "basePath" => "/admin/runlight/" })
    assert_equal 200, routes.handle(req("/admin/runlight/s.js")).status
    assert_equal 404, routes.handle(req("/runlight/s.js")).status
    info = RoutesMake.body(routes.handle(req("/admin/runlight/api")))
    assert_equal "runlight", info["name"]
    assert_equal "runlight", info["library"]
    assert_equal "ruby", info["language"]
  end

  def test_bad_queries_are_400s_with_a_reason
    routes = RoutesMake.runlight.routes({ "token" => nil })
    ["/runlight/api/stats?period=forever", "/runlight/api/stats?filter=nope", "/runlight/api/stats?filter=page:like:x",
     "/runlight/api/breakdown?dimension=shoe_size"].each do |path|
      response = routes.handle(req(path))
      assert_equal 400, response.status, path
      refute_empty RoutesMake.body(response)["error"]
    end
  end

  def test_the_dashboard_page_loads_its_hashed_assets_under_a_strict_csp
    hash = Version.build["dashboardHash"]
    locales = Version.build["localesHash"]
    routes = RoutesMake.runlight.routes({ "token" => "secret", "basePath" => "/admin/runlight" })
    page = routes.handle(req("/admin/runlight/"))
    assert_equal 200, page.status, "the shell holds no data, so it loads signed out"
    assert_match(/script-src 'self'/, page.headers.get("content-security-policy") || "")
    html = page.text
    assert_includes html, "/admin/runlight/assets/app.#{hash}.js"
    assert_includes html, 'data-base="/admin/runlight"'
    js = routes.handle(req("/admin/runlight/assets/app.#{hash}.js"))
    assert_equal 200, js.status
    assert_match(/immutable/, js.headers.get("cache-control") || "")
    assert_equal 200, routes.handle(req("/admin/runlight/assets/app.#{hash}.css")).status
    assert_equal 404, routes.handle(req("/admin/runlight/assets/app.old.js")).status
    assert_includes html, "/admin/runlight/assets/locale.fr.#{locales}.json", "the page lists its languages"
    french = routes.handle(req("/admin/runlight/assets/locale.fr.#{locales}.json"))
    assert_equal 200, french.status
    assert_equal "Filtrer", RoutesMake.body(french)["filter.button"]
    assert_equal 404, routes.handle(req("/admin/runlight/assets/locale.xx.#{locales}.json")).status
    assert_equal 401, routes.handle(req("/admin/runlight/api/stats")).status, "the data stays behind the token"
  end

  def test_a_sites_name_and_timezone_can_be_changed_and_survive_a_restart
    store = Runlight::Stores.sqlite(":memory:")
    first = RoutesMake.runlight({ "store" => store, "site" => { "name" => "From code", "timezone" => "UTC" } })
    routes = first.routes({ "token" => nil })
    patch = lambda do |body, type = "application/json"|
      routes.handle(req("/runlight/api/sites/default", "PATCH", { "content-type" => type }, Json.encode(body)))
    end
    assert_equal 200, patch.call({ "name" => "Jon's site", "timezone" => "America/Toronto" }).status
    assert_equal 400, patch.call({ "timezone" => "Mars/Olympus" }).status
    assert_equal 400, patch.call({ "name" => "" }).status
    assert_equal 415, patch.call({ "name" => "x" }, "text/plain").status
    assert_equal 404, routes.handle(req("/runlight/api/sites/nope", "PATCH", { "content-type" => "application/json" }, "{}")).status
    listed = RoutesMake.body(routes.handle(req("/runlight/api/sites")))
    assert_equal "Jon's site", listed["sites"][0]["name"]
    assert_nil listed["sites"][0]["lastSeen"]

    # Code still says "From code"; the dashboard's change wins after a restart.
    again = RoutesMake.runlight({ "store" => store, "site" => { "name" => "From code", "timezone" => "UTC" } })
    again.init
    assert_equal "Jon's site", again.site("default")["name"]
    assert_equal "America/Toronto", again.site("default")["timezone"]
  end

  def test_a_share_reads_one_sites_reports_and_nothing_else_until_it_is_deleted
    rl = RoutesMake.runlight({ "sites" => [
      { "id" => "a", "name" => "Site A", "hostnames" => ["a.com"], "timezone" => "UTC" },
      { "id" => "b", "name" => "Site B", "hostnames" => ["b.com"], "timezone" => "UTC" },
    ] })
    routes = rl.routes({ "token" => "secret" })

    assert_equal 401, routes.handle(req("/runlight/api/shares?site=a", "POST", { "content-type" => "application/json" }, "{}")).status
    made = routes.handle(RoutesMake.owner("/runlight/api/shares?site=a", "POST", { "name" => "Client" }))
    assert_equal 201, made.status
    share = RoutesMake.body(made)["share"]
    assert_match(/\A[a-f0-9]{32}\z/, share["id"])
    assert_equal "/runlight/share/#{share["id"]}", share["path"]

    page = routes.handle(req(share["path"]))
    assert_equal 200, page.status
    assert_includes page.text, "data-share=\"#{share["id"]}\""
    assert_equal "no-referrer", page.headers.get("referrer-policy")

    as = { "x-runlight-share" => share["id"] }
    assert_equal 200, routes.handle(req("/runlight/api/stats?site=b", "GET", as)).status
    assert_equal "a", RoutesMake.body(routes.handle(req("/runlight/api/stats?site=b", "GET", as)))["site"], "a share is pinned to its own site whatever is asked"
    sites = RoutesMake.body(routes.handle(req("/runlight/api/sites", "GET", as)))
    assert_equal [["a", []]], sites["sites"].map { |s| [s["id"], s["hostnames"]] }
    assert_equal 401, routes.handle(req("/runlight/api/links?site=a", "GET", as)).status, "links need the token"
    assert_equal 401, routes.handle(req("/runlight/api/shares?site=a", "GET", as)).status, "a share cannot list shares"
    assert_equal 404, routes.handle(req("/runlight/api/stats", "GET", { "x-runlight-share" => "0" * 32 })).status

    renamed = routes.handle(RoutesMake.owner("/runlight/api/shares/#{share["id"]}?site=a", "PATCH", { "name" => "Board" }))
    assert_equal "Board", RoutesMake.body(renamed)["share"]["name"]
    assert_equal 404, routes.handle(RoutesMake.owner("/runlight/api/shares/#{share["id"]}?site=b", "DELETE")).status, "only from its own site"
    assert_equal 200, routes.handle(RoutesMake.owner("/runlight/api/shares/#{share["id"]}?site=a", "DELETE")).status
    assert_equal 404, routes.handle(req("/runlight/api/stats", "GET", as)).status
    assert_equal 404, routes.handle(req(share["path"])).status
  end

  def test_a_cms_plugin_reports_ai_agent_fetches_with_its_own_key_which_reads_nothing
    rl = RoutesMake.runlight({ "site" => { "hostnames" => ["blog.example.com"] } })
    routes = rl.routes({ "token" => "secret", "observeKey" => "agents" })
    send = ->(key, body) { routes.handle(RoutesMake.owner("/runlight/api/observe", "POST", body, key)) }
    gpt = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot"
    assert_equal 401, send.call("wrong", { "url" => "https://blog.example.com/post", "userAgent" => gpt }).status
    assert_equal 400, send.call("agents", { "url" => "not a url", "userAgent" => gpt }).status
    assert_equal 204, send.call("agents", { "url" => "https://blog.example.com/post", "userAgent" => gpt }).status
    assert_equal 204, send.call("agents", { "url" => "https://blog.example.com/style.css", "userAgent" => gpt }).status, "assets are ignored, quietly"
    assert_equal 204, send.call("agents", { "url" => "https://elsewhere.example/post", "userAgent" => gpt }).status, "other sites are ignored, quietly"
    assert_equal 401, routes.handle(RoutesMake.owner("/runlight/api/stats", "GET", nil, "agents")).status, "the observe key reads nothing"
    rows = RoutesMake.body(routes.handle(RoutesMake.owner("/runlight/api/breakdown?period=today&dimension=ai_page")))
    assert_equal ["/post"], rows["rows"].map { |r| r["value"] }
  end

  def test_a_gone_share_link_says_so_in_the_visitors_language_and_a_read_tokens_write_is_refused_with_a_code
    rl = RoutesMake.runlight({ "sites" => [{ "id" => "blog", "hostnames" => ["blog.example.com"] }] })
    routes = rl.routes({ "token" => "secret" })
    gone = routes.handle(req("/runlight/share/#{"a" * 32}", "GET", { "accept-language" => "fr-CA,fr;q=0.9,en;q=0.8" }))
    assert_equal 404, gone.status
    assert_match(%r{\Atext/html}, gone.headers.get("content-type") || "")
    page = gone.text
    assert_includes page, '<html lang="fr">'
    assert_includes page, "Ce lien de partage ne fonctionne plus"
    assert_includes routes.handle(req("/runlight/share/#{"a" * 32}")).text, "This share link no longer works"

    read = RoutesMake.body(routes.handle(RoutesMake.owner("/runlight/api/tokens", "POST", { "name" => "Script" })))["secret"]
    write = routes.handle(RoutesMake.owner("/runlight/api/goals?site=blog", "POST", { "name" => "X", "kind" => "event", "match" => "X" }, read))
    assert_equal 403, write.status
    assert_equal "token_read_only", RoutesMake.body(write)["code"]
  end

  def test_goal_funnel_site_and_assistant_refusals_carry_their_own_codes_and_params
    rl = RoutesMake.runlight({ "managedSites" => true })
    routes = rl.routes({ "token" => "secret" })
    send = lambda do |method, path, body|
      json = RoutesMake.body(routes.handle(RoutesMake.owner("/runlight#{path}", method, body)))
      { "code" => json["code"], "params" => json["params"] }
    end
    assert_equal({ "code" => "site_domain_invalid", "params" => { "host" => "nope" } }, send.call("POST", "/api/sites", { "name" => "Blog", "hostnames" => "nope" }))
    send.call("POST", "/api/sites", { "name" => "Blog", "hostnames" => "blog.example.com" })
    assert_equal({ "code" => "site_domain_taken", "params" => { "host" => "blog.example.com", "site" => "Blog" } },
                 send.call("POST", "/api/sites", { "name" => "Again", "hostnames" => "blog.example.com" }))
    send.call("POST", "/api/goals?site=blog.example.com", { "name" => "Signup", "kind" => "event", "match" => "Signup" })
    assert_equal({ "code" => "goal_exists", "params" => { "name" => "signup" } },
                 send.call("POST", "/api/goals?site=blog.example.com", { "name" => "signup", "kind" => "event", "match" => "x" }))
    assert_equal({ "code" => "funnel_short", "params" => {} },
                 send.call("POST", "/api/funnels?site=blog.example.com", { "name" => "F", "steps" => [{ "kind" => "page", "match" => "/" }] }))
    assert_equal({ "code" => "assistant_provider", "params" => {} }, send.call("PUT", "/api/assistant", { "provider" => "nope" }))
  end

  # The routes' own helpers.

  def test_cookies_are_read_by_name_with_equals_signs_kept_in_their_values
    request = req("/", "GET", { "cookie" => "a=1; runlight_token=x=y=z ;  other=2" })
    assert_equal "x=y=z", Routes.read_cookie(request, "runlight_token")
    assert_equal "2", Routes.read_cookie(request, "other")
    assert_equal "", Routes.read_cookie(request, "missing")
    assert_equal "", Routes.read_cookie(req("/"), "a")
    assert_equal OpenSSL::Digest::SHA256.hexdigest("runlight-cookie:secret"), Routes.cookie_value("secret")
  end

  def test_bearer_tokens_are_read_whatever_the_schemes_case
    assert_equal "abc", Routes.bearer(req("/", "GET", { "authorization" => "Bearer abc" }))
    assert_equal "abc", Routes.bearer(req("/", "GET", { "authorization" => "bEaReR   abc  " }))
    assert_equal "", Routes.bearer(req("/", "GET", { "authorization" => "Basic abc" }))
    assert_equal "", Routes.bearer(req("/"))
  end

  def test_only_a_json_media_type_counts_as_json
    { "application/json" => true, "Application/JSON; charset=utf-8" => true, " application/json " => true,
      "text/plain; application/json" => false, "application/json-patch+json" => false, "text/plain;charset=UTF-8" => false }.each do |type, want|
      assert_equal want, Routes.json?(req("/", "POST", { "content-type" => type }, "{}")), type
    end
    refute Routes.json?(req("/", "POST"))
  end

  def test_writes_must_be_json_unless_a_bearer_token_is_sent
    routes = RoutesMake.runlight({ "sites" => [{ "id" => "blog", "hostnames" => ["blog.example.com"] }] }).routes({ "token" => nil })
    # A form from another page cannot send JSON, so a cookie or an open install never lets it write.
    { "POST" => "/runlight/api/goals?site=blog", "PUT" => "/runlight/api/mail", "PATCH" => "/runlight/api/sites/blog" }.each do |method, path|
      answer = routes.handle(req(path, method, { "content-type" => "application/x-www-form-urlencoded" }, "name=x"))
      assert_equal 415, answer.status, "#{method} #{path}"
      assert_equal({ "error" => "Send JSON", "code" => "send_json" }, RoutesMake.body(answer))
    end
    assert_equal 415, routes.handle(req("/runlight/api/check", "POST")).status, "even a write with no body"
    assert_equal 200, routes.handle(req("/runlight/api/check", "POST", { "authorization" => "Bearer x" })).status, "a bearer token is never sent by a browser on its own"
    assert_equal 404, routes.handle(req("/runlight/api/goals/nope?site=blog", "DELETE")).status, "a DELETE carries no body to check"
  end

  def test_errors_are_json_with_their_code_and_never_sniffed
    answer = Routes.coded("Unknown site", "unknown_site", 404)
    assert_equal '{"error":"Unknown site","code":"unknown_site"}', answer.text
    assert_equal "nosniff", answer.headers.get("x-content-type-options")
    assert_equal '{"error":"x","code":"y","params":{}}', Routes.coded("x", "y", 400, {}).text, "empty params are an object"
    assert_equal "private, max-age=3600", Routes.coded("No icon", "icon_none", 404, nil, { "cache-control" => "private, max-age=3600" }).headers.get("cache-control")
  end

  def test_an_error_inside_a_route_is_an_internal_error_that_says_nothing_more
    routes = RoutesMake.runlight({ "sites" => [{ "id" => "blog", "hostnames" => ["blog.example.com"] }] }).routes({ "token" => nil })
    answer = nil
    RoutesMake.quietly do
      # A broken escape in a path makes decodeURIComponent throw, as it does in TypeScript.
      answer = routes.handle(req("/runlight/api/goals/%E0%A4%A?site=blog", "DELETE"))
    end
    assert_equal 500, answer.status
    assert_equal({ "error" => "Internal error", "code" => "internal" }, RoutesMake.body(answer))
  end

  def test_the_dashboard_shell_escapes_what_it_is_given
    html = Routes.dashboard('/a"b', "share<", "/out?x=1&y=2", true, true, "/in")
    assert_includes html, 'data-base="/a&#34;b"'
    assert_includes html, 'data-share="share&#60;"'
    assert_includes html, 'data-sign-out="/out?x=1&#38;y=2"'
    assert_includes html, 'data-sign-in="/in" data-geo-credit="" data-accounts=""'
    refute_includes Routes.dashboard("/runlight"), "data-share"
  end

  def test_rack_answers_as_handle_does_and_a_head_has_no_body
    routes = RoutesMake.runlight.routes({ "token" => "secret" })
    env = { "REQUEST_METHOD" => "GET", "rack.url_scheme" => "https", "HTTP_HOST" => "example.com", "SCRIPT_NAME" => "",
            "PATH_INFO" => "/runlight/s.js", "QUERY_STRING" => "", "rack.input" => StringIO.new("") }
    status, headers, body = routes.call(env)
    assert_equal 200, status
    assert_match(/javascript/, headers["content-type"])
    text = +""
    body.each { |part| text << part }
    assert_match(/sendBeacon/, text)
    status, _headers, body = routes.call(env.merge("REQUEST_METHOD" => "HEAD"))
    assert_equal 404, status, "a HEAD is its own method, as the TypeScript routes see it"
    assert_equal [], body
  end
end
