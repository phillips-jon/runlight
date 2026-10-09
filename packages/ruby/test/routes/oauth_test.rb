# frozen_string_literal: true

require "test_helper"
require "base64"
require_relative "make"

# oauth.test.ts, ported.
class RoutesOAuthTest < RoutesTestCase
  Json = Runlight::Json
  Request = Runlight::Http::Request
  SearchParams = Runlight::Http::SearchParams
  Url = Runlight::Http::Url

  def b64url(bytes)
    Base64.urlsafe_encode64(bytes, padding: false)
  end

  def at(url, method = "GET", headers = {}, body = nil)
    headers = headers.dup
    headers["content-type"] = "text/plain;charset=UTF-8" if !body.nil? && !headers.key?("content-type")
    Request.new(url, method: method, headers: headers, body: body || "")
  end

  def form(fields)
    SearchParams.new(fields).to_s
  end

  def test_an_app_connects_to_the_mcp_server_over_oauth
    rl = RoutesMake.runlight({ "sites" => [
      { "id" => "a", "name" => "Site A", "hostnames" => ["a.com"] },
      { "id" => "b", "name" => "Site B", "hostnames" => ["b.com"] },
    ] })
    routes = rl.routes({ "token" => "secret" })
    origin = "https://x.com"
    owner = { "authorization" => "Bearer secret" }
    form_type = { "content-type" => "application/x-www-form-urlencoded" }

    # The MCP endpoint points at the metadata.
    refused = routes.handle(at("#{origin}/runlight/mcp", "POST", { "content-type" => "application/json" }, "{}"))
    assert_equal 401, refused.status
    m = (refused.headers.get("www-authenticate") || "").match(/resource_metadata="([^"]+)"/)
    assert_equal "#{origin}/runlight/.well-known/oauth-protected-resource", m && m[1]
    resource = RoutesMake.body(routes.handle(at(m[1])))
    assert_equal ["#{origin}/runlight"], resource["authorization_servers"]
    assert_equal "#{origin}/runlight/mcp", resource["resource"]
    server = RoutesMake.body(routes.handle(at("#{origin}/.well-known/oauth-authorization-server/runlight")))
    assert_equal "#{origin}/runlight/oauth/token", server["token_endpoint"]
    assert_equal ["S256"], server["code_challenge_methods_supported"]

    # Registration.
    assert_equal 400, routes.handle(at("#{origin}/runlight/oauth/register", "POST", { "content-type" => "application/json" }, Json.encode({ "redirect_uris" => ["http://evil.example/cb"] }))).status
    registered = routes.handle(at("#{origin}/runlight/oauth/register", "POST", { "content-type" => "application/json" },
                                  Json.encode({ "client_name" => "Claude", "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"] })))
    assert_equal 201, registered.status
    client_id = RoutesMake.body(registered)["client_id"]

    # Consent: signed out it says so; signed in it asks; allowing sends a code back.
    verifier = b64url(SecureRandom.bytes(32))
    challenge = b64url(OpenSSL::Digest::SHA256.digest(verifier))
    params = form({ "response_type" => "code", "client_id" => client_id, "redirect_uri" => "https://claude.ai/api/mcp/auth_callback", "code_challenge" => challenge,
                    "code_challenge_method" => "S256", "state" => "xyz" })
    assert_equal 401, routes.handle(at("#{origin}/runlight/oauth/authorize?#{params}")).status
    wrong_redirect = SearchParams.new(params)
    wrong_redirect.set("redirect_uri", "https://evil.example/cb")
    assert_equal 400, routes.handle(at("#{origin}/runlight/oauth/authorize?#{wrong_redirect}", "GET", owner)).status, "never sends a code to an address the app did not register"
    consent = routes.handle(at("#{origin}/runlight/oauth/authorize?#{params}", "GET", owner))
    assert_equal 200, consent.status
    page = consent.text
    assert_match(%r{Claude</strong> wants to read your Runlight stats}, page)
    assert_match(%r{sends you back to <strong>claude\.ai</strong>}, page, "the page shows where the answer goes")
    deny = routes.handle(at("#{origin}/runlight/oauth/authorize", "POST", owner.merge(form_type), "#{params}&decision=deny"))
    assert_match(/error=access_denied&state=xyz/, deny.headers.get("location") || "")
    forged = routes.handle(at("#{origin}/runlight/oauth/authorize", "POST", owner.merge("origin" => "https://evil.example").merge(form_type), "#{params}&decision=allow"))
    assert_equal 403, forged.status
    allow = routes.handle(at("#{origin}/runlight/oauth/authorize", "POST", owner.merge("origin" => origin).merge(form_type), "#{params}&decision=allow&site=b"))
    back = Url.new(allow.headers.get("location") || "")
    assert_equal "https://claude.ai/api/mcp/auth_callback", "#{back.origin}#{back.pathname}"
    assert_equal "xyz", back.search_params.get("state")
    code = back.search_params.get("code")

    # The token: PKCE checked, the code good once.
    exchange = lambda do |c, used|
      routes.handle(at("#{origin}/runlight/oauth/token", "POST", form_type,
                       form({ "grant_type" => "authorization_code", "code" => c, "client_id" => client_id, "redirect_uri" => "https://claude.ai/api/mcp/auth_callback", "code_verifier" => used })))
    end
    assert_equal "invalid_grant", RoutesMake.body(exchange.call(code, "wrong-verifier"))["error"]
    assert_equal "invalid_grant", RoutesMake.body(exchange.call(code, verifier))["error"], "a code that failed once is spent"

    # Again, properly this time.
    second = routes.handle(at("#{origin}/runlight/oauth/authorize", "POST", owner.merge("origin" => origin).merge(form_type), "#{params}&decision=allow&site=b"))
    code2 = Url.new(second.headers.get("location") || "").search_params.get("code")
    issued = RoutesMake.body(exchange.call(code2, verifier))
    assert_equal "Bearer", issued["token_type"]
    assert_equal "read", issued["scope"]
    assert_equal "b", issued["site"]

    call = routes.handle(at("#{origin}/runlight/mcp", "POST", { "authorization" => "Bearer #{issued["access_token"]}", "content-type" => "application/json" },
                            Json.encode({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => { "name" => "list_sites", "arguments" => {} } })))
    sites = Json.decode(RoutesMake.body(call)["result"]["content"][0]["text"])["sites"]
    assert_equal ["b"], sites.map { |s| s["id"] }, "the token reads only the site chosen at consent"
    tokens = RoutesMake.body(routes.handle(at("#{origin}/runlight/api/tokens", "GET", owner)))
    assert_equal [["Claude (OAuth)", "b"]], tokens["tokens"].map { |t| [t["name"], t["site"]] }
  end

  def test_registering_stores_nothing_so_a_flood_of_registrations_never_keeps_a_real_app_out
    now = RoutesMake.utc(2026, 10, 7, 12)
    rl = RoutesMake.runlight({ "sites" => [{ "id" => "a", "name" => "Site A", "hostnames" => ["a.com"] }], "now" => -> { now } })
    routes = rl.routes({ "token" => "secret" })
    owner = { "authorization" => "Bearer secret" }
    register = lambda do |name, ip = "", redirect = "https://app.example/cb"|
      routes.handle(at("https://x.com/runlight/oauth/register", "POST", { "content-type" => "application/json" },
                       Json.encode({ "client_name" => name, "redirect_uris" => [redirect] })), { "ip" => ip })
    end
    500.times { |i| assert_equal 201, register.call("flood #{i}").status }
    assert_equal 0, rl.store.settings_starting_with("oauth-client:").length
    assert_equal 0, rl.store.settings_starting_with("oauth-used:").length

    # A real app still registers, and its id names it and its address, signed, so nobody can change them.
    claude = register.call("Claude", "", "https://claude.ai/cb")
    assert_equal 201, claude.status
    client_id = RoutesMake.body(claude)["client_id"]
    verifier = b64url(SecureRandom.bytes(32))
    fields = { "response_type" => "code", "client_id" => client_id, "redirect_uri" => "https://claude.ai/cb",
               "code_challenge" => b64url(OpenSSL::Digest::SHA256.digest(verifier)), "code_challenge_method" => "S256" }
    params = form(fields)
    assert_match(%r{Claude</strong> wants to read}, routes.handle(at("https://x.com/runlight/oauth/authorize?#{params}", "GET", owner)).text)
    payload, signature = client_id.split(".")
    forged = "#{b64url(Json.encode({ "n" => "Claude", "r" => ["https://evil.example/cb"], "t" => now }))}.#{signature}"
    refute_equal payload, forged.split(".").first
    assert_equal 400, routes.handle(at("https://x.com/runlight/oauth/authorize?#{form(fields.merge("client_id" => forged, "redirect_uri" => "https://evil.example/cb"))}", "GET", owner)).status

    # Allowed and swapped for a token, the app gets its first row.
    allow = routes.handle(at("https://x.com/runlight/oauth/authorize", "POST", owner.merge("origin" => "https://x.com", "content-type" => "application/x-www-form-urlencoded"), "#{params}&decision=allow"))
    code = Url.new(allow.headers.get("location") || "").search_params.get("code")
    issued = routes.handle(at("https://x.com/runlight/oauth/token", "POST", { "content-type" => "application/x-www-form-urlencoded" },
                              form({ "grant_type" => "authorization_code", "code" => code, "client_id" => client_id, "redirect_uri" => "https://claude.ai/cb", "code_verifier" => verifier })))
    assert_equal 200, issued.status
    assert_equal 1, rl.store.settings_starting_with("oauth-used:").length

    # An app stored before ids were signed still works, and one that never connected goes after a day.
    rl.store.set_setting("oauth-client:#{"a" * 32}", Json.encode({ "name" => "Old", "redirects" => ["https://old.example/cb"], "createdAt" => now }))
    old = form(fields.merge("client_id" => "a" * 32, "redirect_uri" => "https://old.example/cb"))
    assert_equal 200, routes.handle(at("https://x.com/runlight/oauth/authorize?#{old}", "GET", owner)).status
    now += 86_400_000
    register.call("Another")
    assert_equal 0, rl.store.settings_starting_with("oauth-client:").length

    # One address registers at most ten a minute.
    10.times { |i| assert_equal 201, register.call("app #{i}", "203.0.113.9").status }
    assert_equal 429, register.call("one more", "203.0.113.9").status
    assert_equal 201, register.call("one more", "203.0.113.10").status
  end

  def test_before_an_owner_has_allowed_an_app_once_a_request_it_got_wrong_ends_on_a_page
    rl = RoutesMake.runlight({ "sites" => [{ "id" => "a", "name" => "Site A", "hostnames" => ["a.com"] }] })
    routes = rl.routes({ "signIn" => "/login", "authorize" => ->(_r) { false } })
    registered = routes.handle(at("https://x.com/runlight/oauth/register", "POST", { "content-type" => "application/json" },
                                  Json.encode({ "client_name" => "x", "redirect_uris" => ["https://evil.example/landing"] })))
    client_id = RoutesMake.body(registered)["client_id"]
    [{ "response_type" => "token" }, { "response_type" => "code", "code_challenge_method" => "plain", "code_challenge" => "a" * 43 }].each do |asked|
      fields = { "client_id" => client_id, "redirect_uri" => "https://evil.example/landing", "state" => "x" }.merge(asked)
      answer = routes.handle(at("https://x.com/runlight/oauth/authorize?#{form(fields)}"))
      assert_equal 400, answer.status
      assert_nil answer.headers.get("location")
    end
  end

  def test_a_signed_in_viewer_is_told_only_an_owner_can_connect_never_sent_to_sign_in_again
    rl = RoutesMake.runlight({ "sites" => [{ "id" => "a", "name" => "Site A", "hostnames" => ["a.com"] }] })
    routes = rl.routes({ "signIn" => "/login", "authorize" => ->(r) { r.headers.get("cookie") == "viewer" ? "read" : false } })
    registered = routes.handle(at("https://x.com/runlight/oauth/register", "POST", { "content-type" => "application/json" },
                                  Json.encode({ "client_name" => "Claude", "redirect_uris" => ["https://claude.ai/cb"] })))
    client_id = RoutesMake.body(registered)["client_id"]
    params = form({ "response_type" => "code", "client_id" => client_id, "redirect_uri" => "https://claude.ai/cb", "code_challenge" => "a" * 43, "code_challenge_method" => "S256" })
    signed_out = routes.handle(at("https://x.com/runlight/oauth/authorize?#{params}"))
    assert_equal 303, signed_out.status
    assert (signed_out.headers.get("location") || "").start_with?("/login?next=%2Frunlight%2Foauth%2Fauthorize%3Fresponse_type%3Dcode")
    viewer = routes.handle(at("https://x.com/runlight/oauth/authorize?#{params}", "GET", { "cookie" => "viewer" }))
    assert_equal 403, viewer.status
    assert_match(/only an owner of this Runlight can connect Claude/, viewer.text)
  end

  def test_a_manage_grant_names_one_site_and_records_the_hubs_origin
    rl = RoutesMake.runlight({ "sites" => [{ "id" => "a", "name" => "Site A", "hostnames" => ["a.com"] }, { "id" => "b", "name" => "Site B", "hostnames" => ["b.com"] }] })
    routes = rl.routes({ "token" => "secret" })
    owner = { "authorization" => "Bearer secret" }
    client_id = RoutesMake.body(routes.handle(at("https://x.com/runlight/oauth/register", "POST", { "content-type" => "application/json" },
                                                 Json.encode({ "client_name" => "Hub", "redirect_uris" => ["https://hub.example.net/cb"] }))))["client_id"]
    verifier = b64url(SecureRandom.bytes(32))
    params = form({ "response_type" => "code", "client_id" => client_id, "redirect_uri" => "https://hub.example.net/cb", "code_challenge" => Runlight::OAuth.s256(verifier),
                    "code_challenge_method" => "S256", "scope" => "read manage", "site" => "b" })
    page = routes.handle(at("https://x.com/runlight/oauth/authorize?#{params}", "GET", owner)).text
    assert_includes page, '<option value="b" selected>Site B</option>', "the site asked for is offered first"
    refute_includes page, "Every site"
    form_headers = owner.merge("origin" => "https://x.com", "content-type" => "application/x-www-form-urlencoded")
    no_site = routes.handle(at("https://x.com/runlight/oauth/authorize", "POST", form_headers, "#{params.gsub("site=b", "site=")}&decision=allow"))
    assert_equal "https://hub.example.net/cb?error=invalid_request&error_description=Pick+the+site+to+manage", no_site.headers.get("location")
    allow = routes.handle(at("https://x.com/runlight/oauth/authorize", "POST", form_headers, "#{params.gsub("site=b", "site=a")}&decision=allow"))
    code = Url.new(allow.headers.get("location") || "").search_params.get("code")
    issued = RoutesMake.body(routes.handle(at("https://x.com/runlight/oauth/token", "POST", { "content-type" => "application/json" },
                                              Json.encode({ "grant_type" => "authorization_code", "code" => code, "client_id" => client_id,
                                                            "redirect_uri" => "https://hub.example.net/cb", "code_verifier" => verifier }))))
    assert_equal %w[manage a], [issued["scope"], issued["site"]]
    tokens = RoutesMake.body(routes.handle(at("https://x.com/runlight/api/tokens", "GET", owner)))["tokens"]
    assert_equal "https://hub.example.net", rl.store.setting("token-origin:#{tokens[0]["id"]}")
  end
end
