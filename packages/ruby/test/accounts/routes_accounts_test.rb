# frozen_string_literal: true

require "test_helper"
require_relative "../routes/make"

# accounts.test.ts's route-level tests: an app with routes({ "accounts" => true }).
class AccountsRoutesAccountsTest < RoutesTestCase
  Json = Runlight::Json
  Request = Runlight::Http::Request
  SearchParams = Runlight::Http::SearchParams
  Url = Runlight::Http::Url

  def req(path, method = "GET", headers = {}, body = "")
    Request.new("https://example.com#{path}", method: method, headers: headers, body: body)
  end

  def form(path, fields, cookie = "")
    headers = { "content-type" => "application/x-www-form-urlencoded" }
    headers["cookie"] = cookie if cookie != ""
    req(path, "POST", headers, SearchParams.new(fields).to_s)
  end

  def cookie_of(response)
    (response.headers.get("set-cookie") || "").split(";").first.to_s
  end

  on_every_database("an app with accounts on makes its first account with its token then invites people by role") do |kind|
    rl = Runlight::Core.new({ "store" => Databases.fresh(kind), "secret" => "k" * 64 })
    routes = rl.routes({ "token" => "app-token", "accounts" => true })
    handler = ->(r) { routes.handle(r) }
    json = lambda do |cookie, method, path, body = nil|
      handler.call(req("/runlight#{path}", method, { "cookie" => cookie, "content-type" => "application/json" }, body.nil? ? "" : Json.encode(body)))
    end

    # Nobody yet: the dashboard sends you to set up, which asks for the app's token.
    start = handler.call(req("/runlight/"))
    assert_equal 303, start.status
    assert_equal "/runlight/setup", start.headers.get("location")
    page = handler.call(req("/runlight/setup")).text
    assert_match(/RUNLIGHT_TOKEN/, page)
    assert_match(%r{action="/runlight/setup"}, page)
    assert_match(%r{href="/runlight/auth\.css"}, page)
    wrong = handler.call(form("/runlight/setup", { "code" => "guess", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" }))
    assert_equal 403, wrong.status
    made = handler.call(form("/runlight/setup", { "code" => "app-token", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" }))
    assert_equal 303, made.status
    assert_equal "/runlight/", made.headers.get("location")
    assert_match(%r{Path=/runlight;}, made.headers.get("set-cookie") || "", "the session is for Runlight's paths only")
    owner = cookie_of(made)
    assert_equal "/runlight/login", handler.call(req("/runlight/setup")).headers.get("location"), "setup closes once there is an account"

    # Signed in, the dashboard and its API answer; signed out, they do not.
    assert_equal 200, handler.call(req("/runlight/", "GET", { "cookie" => owner })).status
    assert_match(/data-accounts=""/, handler.call(req("/runlight/", "GET", { "cookie" => owner })).text)
    assert_equal 401, handler.call(req("/runlight/api/sites")).status
    assert_equal 200, handler.call(req("/runlight/api/sites", "GET", { "cookie" => owner })).status
    assert_equal 200, handler.call(req("/runlight/api/sites", "GET", { "authorization" => "Bearer app-token" })).status, "a script's token still works"
    assert_equal "owner", Json.decode(json.call(owner, "GET", "/api/account").text)["account"]["role"]

    # The owner invites a member, who joins with their own password.
    sent = Json.decode(json.call(owner, "POST", "/api/people", { "email" => "mo@example.com", "role" => "member" }).text)
    assert_equal false, sent["emailed"], "no mail service here, so the link is for passing on"
    link = Url.new(sent["link"])
    assert_equal "/runlight/invite", link.pathname
    assert_match(/as a member/, handler.call(req("#{link.pathname}#{link.search}")).text)
    joined = handler.call(form("/runlight/invite", { "code" => link.search_params.get("code").to_s, "password" => "another long one", "again" => "another long one" }))
    assert_equal 303, joined.status
    member = cookie_of(joined)

    # A member changes a site's settings, but not people, the mail service, or the assistant's settings.
    assert_equal 201, json.call(member, "POST", "/api/goals", { "name" => "Signup", "kind" => "page", "match" => "/thanks" }).status
    assert_equal 403, json.call(member, "GET", "/api/people").status
    assert_equal "admin_only", Json.decode(json.call(member, "PUT", "/api/mail", {}).text)["code"]
    assert_equal 403, json.call(member, "PUT", "/api/assistant", {}).status

    # Signing out ends the session; signing in again with the password starts one.
    out = handler.call(req("/runlight/logout"))
    assert_equal "/runlight/login", out.headers.get("location")
    assert_equal "/runlight/login", handler.call(req("/runlight/")).headers.get("location")
    back = handler.call(form("/runlight/login", { "email" => "mo@example.com", "password" => "another long one", "next" => "/runlight/?period=7d" }))
    assert_equal 303, back.status
    assert_equal "/runlight/?period=7d", back.headers.get("location")
    elsewhere = handler.call(form("/runlight/login", { "email" => "mo@example.com", "password" => "another long one", "next" => "//evil.example/" }))
    assert_equal "/runlight/", elsewhere.headers.get("location"), "never sent off the app"
  end

  def test_in_development_or_left_open_on_purpose_the_first_account_needs_no_proof_in_production_without_a_token_setup_stays_shut
    ENV["NODE_ENV"] = "development"
    dev = Runlight::Core.new({ "store" => Databases.fresh("sqlite") }).routes({ "accounts" => true })
    page = dev.handle(req("/runlight/setup")).text
    refute_match(/RUNLIGHT_TOKEN/, page)
    made = dev.handle(form("/runlight/setup", { "code" => "", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" }))
    assert_equal 303, made.status

    ENV["NODE_ENV"] = "production"
    open = Runlight::Core.new({ "store" => Databases.fresh("sqlite") }).routes({ "token" => nil, "accounts" => true })
    assert_equal 200, open.handle(req("/runlight/setup")).status, "token: nil leaves setup open, as it leaves everything"
    prod = Runlight::Core.new({ "store" => Databases.fresh("sqlite"), "secret" => "k" * 64 }).routes({ "accounts" => true })
    shut = prod.handle(req("/runlight/setup"))
    assert_equal 403, shut.status
    assert_match(/Set RUNLIGHT_TOKEN/, shut.text)
    tried = prod.handle(form("/runlight/setup", { "code" => "", "email" => "jon@example.com", "password" => "a long password", "again" => "a long password" }))
    assert_equal 403, tried.status
  end
end
