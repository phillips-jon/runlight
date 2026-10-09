# frozen_string_literal: true

require "test_helper"
require_relative "stand_in"

# Accounts on the web, through Web#handle as the routes call it, with a stand-in for the Runlight. The cases
# follow accounts.test.ts and the accounts conformance scenario.
class AccountsWebTest < Minitest::Test
  Web = Runlight::Accounts::Web
  Pages = Runlight::Accounts::Pages
  Crypto = Runlight::Accounts::Crypto
  Accounts = Runlight::Accounts::Accounts
  Request = Runlight::Http::Request
  SearchParams = Runlight::Http::SearchParams
  Url = Runlight::Http::Url
  Json = Runlight::Json

  NOW = 1_791_288_000_000
  BASE = "/runlight"
  FORGOT = "https://runlight.sh/docs/configuration/#accounts"

  def setup
    @now = NOW
  end

  def web(first = { "token" => "app-token" }, home = nil)
    store = Runlight::Stores.sqlite(":memory:")
    store.migrate
    @rl = AccountsSupport::StandIn.new(store)
    options = {
      "runlight" => @rl,
      "secret" => "k" * 64,
      "base" => BASE,
      "now" => -> { @now },
      "firstAccount" => first,
      "forgot" => FORGOT,
    }
    options["home"] = -> { home } unless home.nil?
    Web.new(options)
  end

  def req(path, method = "GET", headers = {}, body = "")
    Request.new("https://example.com/runlight#{path}", method: method, headers: headers, body: body)
  end

  def form(path, fields, cookie = "")
    req(path, "POST", { "content-type" => "application/x-www-form-urlencoded" }.merge(cookie == "" ? {} : { "cookie" => cookie }), SearchParams.new(fields).to_s)
  end

  def json(cookie, method, path, body = nil)
    req(path, method, { "cookie" => cookie, "content-type" => "application/json" }, body.nil? ? "" : Json.encode(body))
  end

  def handle(web, request)
    path = Url.new(request.url).pathname[BASE.length..]
    web.handle(request, path.nil? || path.empty? ? "/" : path)
  end

  def cookie_of(response)
    (response.headers.get_set_cookie[0] || "").split(";")[0]
  end

  def owner(web)
    cookie_of(handle(web, form("/setup", { "code" => "app-token", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" })))
  end

  def test_an_app_makes_its_first_account_with_its_token
    web = web()
    start = handle(web, req("/"))
    assert_equal 303, start.status
    assert_equal "/runlight/setup", start.headers.get("location")
    assert_equal "no-store", start.headers.get("cache-control")
    page = handle(web, req("/setup"))
    assert_equal Pages.setup_page(BASE, { "code" => "", "askCode" => true }), page.text
    assert_equal "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
                 page.headers.get("content-security-policy")
    assert_match %r{href="/runlight/auth\.css"}, page.text

    wrong = handle(web, form("/setup", { "code" => "guess", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" }))
    assert_equal 403, wrong.status
    assert_equal Pages.setup_page(BASE, { "code" => "", "askCode" => true, "error" => "That is not this app's RUNLIGHT_TOKEN.", "email" => "jon@example.com" }), wrong.text
    typo = handle(web, form("/setup", { "code" => "app-token", "email" => "jon@example.com", "password" => "a long password", "again" => "a long passwore" }))
    assert_equal 400, typo.status
    assert_includes typo.text, "The two passwords are not the same."
    short = handle(web, form("/setup", { "code" => "app-token", "email" => "jon@example.com", "password" => "short", "again" => "short" }))
    assert_equal 400, short.status
    assert_includes short.text, "Use a password of at least 10 characters"

    made = handle(web, form("/setup", { "code" => "app-token", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" }))
    assert_equal 303, made.status
    assert_equal "/runlight/", made.headers.get("location")
    cookie = made.headers.get_set_cookie
    assert_equal 1, cookie.length
    assert_match %r{\Arunlight_session=[a-f0-9]{24}\.\d+\.[A-Za-z0-9_-]{43}; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=2592000; Secure\z}, cookie[0]
    assert_equal "/runlight/login", handle(web, req("/setup")).headers.get("location"), "setup closes once there is an account"

    owner = cookie_of(made)
    assert_nil handle(web, req("/", "GET", { "cookie" => owner })), "signed in, the dashboard is the routes' to answer"
    assert_equal true, web.access(req("/", "GET", { "cookie" => owner }))
    assert_equal false, web.access(req("/"))
    answer = handle(web, json(owner, "GET", "/api/account"))
    user = web.accounts.by_email("jon@example.com")
    assert_equal Json.encode({ "account" => { "id" => user["id"], "email" => "jon@example.com", "role" => "owner", "createdAt" => NOW, "twoFactor" => false, "recoveryLeft" => 0 } }),
                 answer.text
    assert_equal "application/json; charset=utf-8", answer.headers.get("content-type")
    assert_equal user["id"], web.account_of(req("/", "GET", { "cookie" => owner }))

    # Signed out, the dashboard sends you to sign in, and keeps where you were going.
    assert_equal "/runlight/login?next=%2Frunlight%2F%3Fperiod%3D7d", handle(web, req("/?period=7d")).headers.get("location")
    assert_equal "/runlight/login", handle(web, req("/")).headers.get("location")
  end

  def test_a_server_code_open_and_locked_setups
    code = Web.setup_code
    assert_match(/\A[A-Za-z0-9_-]{12}\z/, code)
    web = web({ "code" => code })
    assert_equal 403, handle(web, req("/")).status, "a server with no account and no code in the link stays shut"
    assert_equal Pages.setup_locked_page(BASE), handle(web, req("/setup?code=nope")).text
    assert_equal Pages.setup_page(BASE, { "code" => code }), handle(web, req("/setup?code=#{code}")).text
    assert_equal 403, handle(web, req("/login")).status
    assert_equal 403, handle(web, form("/setup", { "code" => "nope", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" })).status

    open = web("open")
    assert_equal "/runlight/setup", handle(open, req("/")).headers.get("location")
    assert_equal "/runlight/setup", handle(open, req("/login")).headers.get("location")
    refute_includes handle(open, req("/setup")).text, "RUNLIGHT_TOKEN"
    assert_equal 303, handle(open, form("/setup", { "code" => "", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" })).status

    locked = web("locked")
    shut = handle(locked, req("/setup"))
    assert_equal 403, shut.status
    assert_includes shut.text, "Set RUNLIGHT_TOKEN"
    assert_equal 403, handle(locked, form("/setup", { "code" => "", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" })).status

    css = handle(locked, req("/auth.css"))
    assert_equal Pages::AUTH_CSS, css.text
    assert_equal "text/css; charset=utf-8", css.headers.get("content-type")
    assert_equal "public, max-age=3600", css.headers.get("cache-control")
    assert_equal "application/javascript; charset=utf-8", handle(locked, req("/auth.js")).headers.get("content-type")
    assert_nil handle(locked, req("/somewhere"))
  end

  def test_signing_in_and_out_never_leaves_the_app
    web = web()
    owner(web)
    login = handle(web, req("/login?next=%2Frunlight%2F%3Fsite%3Dx"))
    assert_equal Pages.login_page(BASE, { "next" => "/runlight/?site=x", "forgot" => FORGOT }), login.text

    wrong = handle(web, form("/login", { "email" => "jon@example.com", "password" => "a wrong password" }))
    assert_equal 401, wrong.status
    assert_equal Pages.login_page(BASE, { "error" => "That email and password do not match an account.", "email" => "jon@example.com", "next" => "/runlight/", "forgot" => FORGOT }),
                 wrong.text

    back = handle(web, form("/login", { "email" => "JON@example.com", "password" => "a long password", "next" => "/runlight/?period=7d" }))
    assert_equal 303, back.status
    assert_equal "/runlight/?period=7d", back.headers.get("location")
    cookies = back.headers.get_set_cookie
    assert_equal 2, cookies.length, "a session, and the mark that this browser signed in to the account"
    assert_match %r{\Arunlight_device=[a-f0-9]{24}\.[A-Za-z0-9_-]{43}; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=31536000; Secure\z}, cookies[1]

    out = handle(web, req("/logout"))
    assert_equal "/runlight/login", out.headers.get("location")
    assert_equal ["runlight_session=; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=0; Secure"], out.headers.get_set_cookie

    ["//evil.example/", "/\\evil.example", "/\t/evil.example", "https://evil.example/", "", "runlight"].each do |nxt|
      assert_equal "/runlight/", web.safe_next(nxt), "never sent off the app: #{nxt}"
    end
    assert_equal "/runlight/", web.safe_next(nil)
    assert_equal "/runlight/x?y=1#z", web.safe_next("/runlight/a/../x?y=1#z")
    assert_equal "/%20a", web.safe_next("/ a")
  end

  def test_invites_people_and_roles
    web = web()
    owner = owner(web)
    sent = handle(web, json(owner, "POST", "/api/people", { "email" => "Mo@Example.com", "role" => "member" }))
    assert_equal 201, sent.status
    body = Json.decode(sent.text)
    assert_equal %w[invite link emailed], body.keys
    refute body["emailed"], "no mail service here, so the link is for passing on"
    link = Url.new(body["link"])
    assert_equal "https://example.com", link.origin
    assert_equal "/runlight/invite", link.pathname
    code = link.search_params.get("code").to_s
    assert_includes handle(web, req("/invite?code=#{code}")).text, "as a member"
    assert_equal 410, handle(web, req("/invite?code=nope")).status

    assert_equal 409, handle(web, json(owner, "POST", "/api/people", { "email" => "jon@example.com", "role" => "admin" })).status
    no_role = handle(web, json(owner, "POST", "/api/people", { "email" => "x@example.com", "role" => "owner" }))
    assert_equal '{"error":"Pick admin, member, or viewer","code":"role_needed"}', no_role.text
    assert_equal "nosniff", no_role.headers.get("x-content-type-options")
    bad_email = handle(web, json(owner, "POST", "/api/people", { "email" => "nobody", "role" => "admin" }))
    assert_equal '{"error":"Enter an email address","code":"email_invalid","params":{}}', bad_email.text
    plain = handle(web, req("/api/people", "POST", { "cookie" => owner, "content-type" => "text/plain" }, "{}"))
    assert_equal 415, plain.status, "a write must be JSON"
    assert_equal '{"error":"Sign in first","code":"sign_in"}', handle(web, req("/api/people")).text

    typo = handle(web, form("/invite", { "code" => code, "password" => "another long one", "again" => "another long two" }))
    assert_equal 400, typo.status
    joined = handle(web, form("/invite", { "code" => code, "password" => "another long one", "again" => "another long one" }))
    assert_equal 303, joined.status
    assert_equal "/runlight/", joined.headers.get("location")
    member = cookie_of(joined)
    assert_equal "member", web.access(req("/", "GET", { "cookie" => member }))
    assert_equal 403, handle(web, json(member, "GET", "/api/people")).status
    assert_equal 410, handle(web, form("/invite", { "code" => code, "password" => "another long one", "again" => "another long one" })).status, "an invite works once"

    # A member's tokens go when they become a viewer.
    mo = web.accounts.by_email("mo@example.com")
    token = { "id" => "b" * 24, "name" => "Script", "site" => "", "scope" => "read", "hash" => "c" * 64, "hint" => "abcd", "createdAt" => NOW, "lastUsedAt" => nil }
    @rl.store.insert_token(token)
    assert web.token_made(token, mo["id"])
    refute web.token_made(token, "d" * 24), "nobody by that id makes tokens"
    changed = handle(web, json(owner, "PATCH", "/api/people/#{mo["id"]}", { "role" => "viewer" }))
    assert_equal Json.encode({ "person" => { "id" => mo["id"], "email" => "mo@example.com", "role" => "viewer", "createdAt" => NOW, "twoFactor" => false, "recoveryLeft" => 0 } }),
                 changed.text
    assert_equal [], @rl.store.tokens
    assert_equal "read", web.access(req("/", "GET", { "cookie" => member }))
    refute web.token_made(token, mo["id"]), "a viewer makes no tokens"

    jon = web.accounts.by_email("jon@example.com")
    assert_equal '{"error":"Only the owner can change their own role, by handing ownership to an admin","code":"owner_protected","params":{}}',
                 handle(web, json(owner, "PATCH", "/api/people/#{jon["id"]}", { "role" => "admin" })).text
    assert_equal 403, handle(web, json(owner, "PATCH", "/api/people/#{jon["id"]}", { "role" => "admin" })).status
    assert_equal 404, handle(web, json(owner, "PATCH", "/api/people/#{"a" * 24}", { "role" => "admin" })).status
    assert_equal "remove_self", Json.decode(handle(web, json(owner, "DELETE", "/api/people/#{jon["id"]}")).text)["code"]

    # Invites listed, resent, and cancelled.
    handle(web, json(owner, "POST", "/api/people", { "email" => "zed@example.com", "role" => "viewer" }))
    people = Json.decode(handle(web, json(owner, "GET", "/api/people")).text)
    assert_equal ["jon@example.com", "mo@example.com"].sort, people["people"].map { |p| p["email"] }.sort
    assert_equal ["zed@example.com"], people["invites"].map { |i| i["email"] }
    id = people["invites"][0]["id"]
    resent = handle(web, json(owner, "POST", "/api/invites/#{id}/resend"))
    assert_equal 200, resent.status
    new_id = Json.decode(resent.text)["invite"]["id"]
    refute_equal id, new_id
    assert_equal 404, handle(web, json(owner, "DELETE", "/api/invites/#{id}")).status
    assert_equal '{"ok":true}', handle(web, json(owner, "DELETE", "/api/invites/#{new_id}")).text

    assert_equal '{"ok":true}', handle(web, json(owner, "DELETE", "/api/people/#{mo["id"]}")).text
    assert_nil web.signed_in(req("/", "GET", { "cookie" => member })), "someone removed is signed out"
  end

  def test_invites_are_emailed_when_there_is_a_mail_service
    web = web({ "token" => "app-token" }, "https://stats.example.com")
    owner = owner(web)
    @rl.mail = { "service" => "smtp", "from" => "runlight@example.com" }
    body = Json.decode(handle(web, json(owner, "POST", "/api/people", { "email" => "mo@example.com", "role" => "viewer" })).text)
    assert body["emailed"]
    assert body["link"].start_with?("https://stats.example.com/runlight/invite?code="), "the install's own address, never the request's Host"
    assert_equal "jon@example.com invited you to Runlight", @rl.sent[0]["subject"]
    assert_equal "jon@example.com invited you to the Runlight at stats.example.com as a viewer, who can read every site's stats.\n\nChoose a password to join:\n" \
                 "#{body["link"]}\n\nThe link works for seven days.\n", @rl.sent[0]["text"]

    @rl.mail_fails = Runlight::Mail::MailError.new("The server refused the password", "mail_auth", { "host" => "smtp.example.com" })
    failed = handle(web, json(owner, "POST", "/api/people", { "email" => "ada@example.com", "role" => "admin" }))
    body = Json.decode(failed.text)
    assert_equal %w[invite link emailed mailError mailCode mailParams], body.keys
    assert_equal "mail_auth", body["mailCode"]
    assert_equal({ "host" => "smtp.example.com" }, body["mailParams"])
    @rl.mail_fails = RuntimeError.new("Something else")
    other = Json.decode(handle(web, json(owner, "POST", "/api/people", { "email" => "zed@example.com", "role" => "admin" })).text)
    assert_equal %w[invite link emailed mailError], other.keys, "an error without a code of its own has none here"
  end

  def test_two_factor_through_the_account_api_and_the_code_step
    web = web()
    owner = owner(web)
    wrong = handle(web, json(owner, "POST", "/api/account/2fa/start", { "password" => "a wrong password" }))
    assert_equal '{"error":"Your password is not right","code":"password_wrong"}', wrong.text
    start = Json.decode(handle(web, json(owner, "POST", "/api/account/2fa/start", { "password" => "a long password" })).text)
    assert_equal Crypto.otpauth_uri(start["secret"], "jon@example.com", "example.com"), start["uri"]
    assert_equal '{"error":"Turn on two-factor sign-in first","code":"twofactor_off"}',
                 handle(web, json(owner, "POST", "/api/account/2fa/recovery", { "password" => "a long password" })).text

    code = Crypto.totp(start["secret"], @now / 30_000)
    confirmed = handle(web, json(owner, "POST", "/api/account/2fa/confirm", { "code" => "#{code[0, 3]} #{code[3..]}" }))
    assert_equal 200, confirmed.status
    assert_equal 10, Json.decode(confirmed.text)["recovery"].length
    assert_nil web.signed_in(req("/", "GET", { "cookie" => owner })), "turning it on signs out every other browser"
    owner = cookie_of(confirmed)
    assert web.signed_in(req("/", "GET", { "cookie" => owner }))["twoFactor"]

    # Signing in now earns only the code step.
    @now += 60_000
    step = handle(web, form("/login", { "email" => "jon@example.com", "password" => "a long password", "next" => "/runlight/?x=1" }))
    assert_equal 200, step.status
    assert_equal [], step.headers.get_set_cookie
    m = step.text.match(/name="pending" value="([^"]+)"/)
    refute_nil m
    pending = m[1]
    bad = handle(web, form("/login/code", { "pending" => pending, "code" => "12345x", "next" => "/runlight/?x=1" }))
    assert_equal 401, bad.status
    assert_equal Pages.code_page(BASE, { "pending" => pending, "next" => "/runlight/?x=1", "error" => "That code is not right. Check the time on your phone, or use a recovery code." }),
                 bad.text
    signed = handle(web, form("/login/code", { "pending" => pending, "code" => Crypto.totp(start["secret"], @now / 30_000), "next" => "/runlight/?x=1" }))
    assert_equal 303, signed.status
    assert_equal "/runlight/?x=1", signed.headers.get("location")
    assert_equal "/runlight/login?next=%2Frunlight%2F", handle(web, form("/login/code", { "pending" => "made.up.ticket", "code" => "123456" })).headers.get("location")

    # Turning it off keeps this browser signed in.
    off = handle(web, json(cookie_of(signed), "POST", "/api/account/2fa/disable", { "password" => "a long password" }))
    assert_equal '{"ok":true}', off.text
    refute web.signed_in(req("/", "GET", { "cookie" => cookie_of(off) }))["twoFactor"]
    assert_equal 404, handle(web, json(cookie_of(off), "POST", "/api/account/2fa/other", { "password" => "a long password" })).status
  end

  def test_confirming_has_five_tries_and_then_starts_again
    web = web()
    owner = owner(web)
    start = Json.decode(handle(web, json(owner, "POST", "/api/account/2fa/start", { "password" => "a long password" })).text)
    right = Crypto.totp(start["secret"], @now / 30_000)
    wrong = right == "000000" ? "111111" : "000000"
    5.times do
      assert_equal "code_wrong", Json.decode(handle(web, json(owner, "POST", "/api/account/2fa/confirm", { "code" => wrong })).text)["code"]
    end
    restart = handle(web, json(owner, "POST", "/api/account/2fa/confirm", { "code" => right }))
    assert_equal 429, restart.status
    assert_equal "twofactor_restart", Json.decode(restart.text)["code"]
    assert_nil web.accounts.confirm_two_factor(web.accounts.by_email("jon@example.com")["id"], right, @now), "the set-up was dropped"
    # Starting again with the password opens five more tries.
    again = Json.decode(handle(web, json(owner, "POST", "/api/account/2fa/start", { "password" => "a long password" })).text)
    code = Crypto.totp(again["secret"], @now / 30_000)
    assert_equal 200, handle(web, json(owner, "POST", "/api/account/2fa/confirm", { "code" => code })).status
  end

  def test_password_changes_end_other_sessions
    web = web()
    owner = owner(web)
    assert_equal '{"error":"Your current password is not right","code":"password_current_wrong"}',
                 handle(web, json(owner, "POST", "/api/account/password", { "current" => "nope", "next" => "a newer long one" })).text
    short = handle(web, json(owner, "POST", "/api/account/password", { "current" => "a long password", "next" => "short" }))
    assert_equal '{"error":"Use a password of at least 10 characters","code":"password_short","params":{"min":"10"}}', short.text
    changed = handle(web, json(owner, "POST", "/api/account/password", { "current" => "a long password", "next" => "a newer long one" }))
    assert_equal '{"ok":true}', changed.text
    assert_nil web.signed_in(req("/", "GET", { "cookie" => owner }))
    refute_nil web.signed_in(req("/", "GET", { "cookie" => cookie_of(changed) }))
  end

  def test_ten_wrong_passwords_from_one_address_wait
    web = web()
    owner(web)
    headers = { "content-type" => "application/x-www-form-urlencoded", "x-forwarded-for" => "203.0.113.9" }
    body = SearchParams.new({ "email" => "jon@example.com", "password" => "a wrong password" }).to_s
    10.times { assert_equal 401, handle(web, req("/login", "POST", headers, body)).status }
    held = handle(web, req("/login", "POST", headers, body))
    assert_equal 429, held.status
    assert_includes held.text, "Too many tries. Wait fifteen minutes and try again."
    right = SearchParams.new({ "email" => "jon@example.com", "password" => "a long password" }).to_s
    assert_equal 429, handle(web, req("/login", "POST", headers, right)).status, "even the right password waits"
    assert_equal 303, handle(web, req("/login", "POST", headers.merge("x-forwarded-for" => "203.0.113.10"), right)).status, "another address is not held up"
    @now += 15 * 60_000
    assert_equal 303, handle(web, req("/login", "POST", headers, right)).status, "fifteen minutes later"
  end

  def test_an_account_held_up_by_others_gets_a_sign_in_link
    web = web({ "token" => "app-token" }, "https://stats.example.com")
    owner(web)
    @rl.mail = { "service" => "smtp", "from" => "runlight@example.com" }
    accounts = web.accounts
    # Fifty failures against the account from fifty addresses, counted as the throttle counts them.
    throttle = Runlight::Accounts::Throttle.new(@rl.store, "account", 50)
    50.times { throttle.record_failure("jon@example.com", @now) }
    held = handle(web, form("/login", { "email" => "jon@example.com", "password" => "a long password", "next" => "/runlight/?a=1" }))
    assert_equal 429, held.status
    assert_includes held.text, "a link to sign in is on its way"
    assert_equal 1, @rl.sent.length
    assert_equal "Sign in to Runlight", @rl.sent[0]["subject"]
    m = @rl.sent[0]["text"].match(%r{(https://stats\.example\.com/runlight/login/link\?\S+)})
    refute_nil m
    link = Url.new(m[1])
    assert_equal "/runlight/?a=1", link.search_params.get("next")
    handle(web, form("/login", { "email" => "jon@example.com", "password" => "a long password" }))
    assert_equal 1, @rl.sent.length, "at most one link a minute"
    wrong_too = handle(web, form("/login", { "email" => "jon@example.com", "password" => "a wrong password" }))
    assert_equal 429, wrong_too.status, "a wrong password gets the same answer"

    signed = handle(web, req("/login/link#{link.search}"))
    assert_equal 303, signed.status
    assert_equal "/runlight/?a=1", signed.headers.get("location")
    assert_equal 410, handle(web, req("/login/link#{link.search}")).status, "a link works once"
    refute_nil accounts.by_email("jon@example.com")
  end

  def test_a_broken_session_cookie_raises_as_decode_uri_component_does
    web = web()
    assert_raises(ArgumentError) { web.signed_in(req("/", "GET", { "cookie" => "runlight_session=%E0%A4%A" })) }
  end

  def test_the_session_cookie_is_read_among_others
    web = web()
    owner = owner(web)
    refute_nil web.signed_in(req("/", "GET", { "cookie" => "a=b; #{owner} ; c=d=e" }))
    assert_equal Accounts::SESSION_COOKIE, owner.split("=")[0]
    plain = Request.new("http://example.com/runlight/login", method: "POST", headers: { "content-type" => "application/x-www-form-urlencoded" },
                                                             body: SearchParams.new({ "email" => "jon@example.com", "password" => "a long password" }).to_s)
    refute_includes handle(web, plain).headers.get_set_cookie[0], "Secure", "Secure only over https"
    proxied = Request.new("http://example.com/runlight/logout", method: "GET", headers: { "x-forwarded-proto" => "https" })
    assert handle(web, proxied).headers.get_set_cookie[0].end_with?("; Secure")
  end
end
