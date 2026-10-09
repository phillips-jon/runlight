# frozen_string_literal: true

require "test_helper"
require "openssl"
require "base64"
require_relative "../support/router"

# Connecting an install through its consent page, as hub.test.ts tests it, with the install played by a Router.
class CoreConnectTest < Minitest::Test
  APP = "http://127.0.0.1:4100/runlight"
  Connect = Runlight::Connect
  Json = Runlight::Json
  SearchParams = Runlight::Http::SearchParams
  Url = Runlight::Http::Url

  def setup
    @now = 1_791_288_000_000
  end

  DEFAULT_META = {
    "authorization_endpoint" => "http://127.0.0.1:4100/runlight/oauth/authorize",
    "token_endpoint" => "http://127.0.0.1:4100/runlight/oauth/token",
    "registration_endpoint" => "http://127.0.0.1:4100/runlight/oauth/register",
    "scopes_supported" => %w[read manage],
  }.freeze

  # An install that speaks OAuth, as an app's Runlight does.
  def install(meta = {}, registered = { "client_id" => "c1" }, register_status = 201)
    meta = DEFAULT_META if meta.empty?
    Router.new([
      [%r{/\.well-known/oauth-authorization-server\z}, ->(_u, _init) { meta }],
      [%r{/oauth/register\z}, ->(_u, _init) { [register_status, registered] }],
      [%r{/oauth/token\z}, ->(_u, _init) { { "access_token" => "rl_manage", "site" => "blog" } }],
      [%r{/api/sites\z}, lambda { |_u, _init|
        { "sites" => [{ "id" => "shop", "name" => "Shop", "timezone" => "UTC", "hostnames" => ["shop.example.com"] },
                      { "id" => "blog", "name" => "Blog", "timezone" => "Asia/Tokyo", "hostnames" => ["blog.example.com"] }] }
      }],
      [%r{/api/token\z}, ->(_u, _init) { { "scope" => "manage", "site" => "blog" } }],
    ])
  end

  def hub(router)
    Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "managedSites" => true, "secret" => "k" * 32, "fetcher" => router,
                         "now" => -> { @now } })
  end

  def refused(code, &block)
    error = assert_raises(Runlight::ConnectError, &block)
    assert_equal code, error.code
    error
  end

  def test_a_hub_connects_an_app_through_its_consent_page_for_the_one_site_the_owner_picked
    router = install
    hub = hub(router)
    hub.init
    back = "http://localhost:4900/runlight/api/sites/connect/done"
    consent = Url.new(Connect.start_connect(hub, "#{APP}/", back))
    assert_equal "http://127.0.0.1:4100/runlight/oauth/authorize", consent.origin + consent.pathname
    q = consent.search_params
    assert_equal ["code", "c1", back, "S256", "manage"], [q.get("response_type"), q.get("client_id"), q.get("redirect_uri"), q.get("code_challenge_method"), q.get("scope")]
    assert_match(/\A[a-f0-9]{32}\z/, q.get("state").to_s)
    assert_nil q.get("site")
    registration = Json.decode(router.requests[1]["init"]["body"])
    assert_equal Json.encode({ "client_name" => "Runlight at localhost:4900", "redirect_uris" => [back] }), Json.encode(registration)

    pending = Json.decode(hub.store.setting("connect:#{q.get("state")}").to_s)
    challenge = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(pending["verifier"]), padding: false)
    assert_equal challenge, q.get("code_challenge"), "the challenge is the verifier hashed"
    assert_equal @now + (15 * 60_000), pending["expires"]

    id = Connect.finish_connect(hub, SearchParams.new({ "state" => q.get("state").to_s, "code" => "the-code" }))
    assert_equal "blog.example.com", id
    assert_equal Json.encode({ "url" => APP, "token" => "rl_manage", "site" => "blog", "hostnames" => ["blog.example.com"], "scope" => "manage" }),
                 Json.encode(hub.remote(id))
    assert_equal Json.encode({ "id" => "blog.example.com", "name" => "Blog", "hostnames" => [], "timezone" => "Asia/Tokyo" }), Json.encode(hub.site(id))
    exchange = router.requests.find { |r| r["url"].end_with?("/oauth/token") }
    form = SearchParams.new(exchange["init"]["body"])
    assert_equal ["authorization_code", "the-code", "c1", back, pending["verifier"]],
                 [form.get("grant_type"), form.get("code"), form.get("client_id"), form.get("redirect_uri"), form.get("code_verifier")]

    # A code works once.
    refused("expired") { Connect.finish_connect(hub, SearchParams.new({ "state" => q.get("state").to_s, "code" => "the-code" })) }
  end

  def test_what_went_wrong_comes_back_as_a_code
    hub = hub(install)
    hub.init
    start = ->(site = "") { Url.new(Connect.start_connect(hub, APP, "https://hub.example/done", site)).search_params }
    assert_equal "blog", start.call("blog").get("site"), "which of its sites to offer first"
    denied = start.call
    refused("denied") { Connect.finish_connect(hub, SearchParams.new({ "state" => denied.get("state").to_s, "error" => "access_denied" })) }
    other = start.call
    e = refused("refused") do
      Connect.finish_connect(hub, SearchParams.new({ "state" => other.get("state").to_s, "error" => "server_error", "error_description" => "Sign in again" }))
    end
    assert_equal "Sign in again", e.message
    refused("expired") { Connect.finish_connect(hub, SearchParams.new({ "state" => "not-a-state" })) }
    # An attempt nobody came back from in time.
    late = start.call
    @now += 16 * 60_000
    refused("expired") { Connect.finish_connect(hub, SearchParams.new({ "state" => late.get("state").to_s })) }
    # Starting again clears the ones that ran out.
    start.call
    assert_equal 1, hub.store.settings_starting_with("connect:").length
  end

  def test_a_hub_only_follows_an_installs_own_endpoints_when_connecting
    hostile = install({ "authorization_endpoint" => "http://127.0.0.1:1/authorize", "token_endpoint" => "http://169.254.169.254/token",
                        "registration_endpoint" => "http://169.254.169.254/register", "scopes_supported" => %w[read manage] })
    hub = hub(hostile)
    e = refused("endpoints") { Connect.start_connect(hub, "http://127.0.0.1:4100", "https://hub.example/done") }
    assert_match(/named endpoints on another address/, e.message)
    assert_equal 1, hostile.requests.length, "nothing else was asked"
  end

  def test_an_install_that_cannot_connect_says_why
    refused("url") { Connect.start_connect(hub(install), "ftp://x", "https://hub.example/done") }
    refused("not_runlight") { Connect.start_connect(hub(Router.new([])), APP, "https://hub.example/done") }
    old = install({ "authorization_endpoint" => "#{APP}/oauth/authorize", "token_endpoint" => "#{APP}/oauth/token",
                    "registration_endpoint" => "#{APP}/oauth/register", "scopes_supported" => ["read"] })
    refused("old") { Connect.start_connect(hub(old), APP, "https://hub.example/done") }
    e = refused("register") do
      Connect.start_connect(hub(install({}, { "error_description" => "redirect_uris must use https" }, 400)), APP, "http://hub.example/done")
    end
    assert_equal({ "url" => APP, "reason" => "redirect_uris must use https." }, e.params)
    e = refused("register") { Connect.start_connect(hub(install({}, { "nope" => true }, 400)), APP, "http://hub.example/done") }
    assert_equal "This server's address must use https.", e.params["reason"]
    down = Object.new
    def down.fetch(_url, _init = {})
      raise Runlight::Http::FetchError, "refused"
    end
    hub = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "fetcher" => down })
    e = refused("unreachable") { Connect.start_connect(hub, APP, "https://hub.example/done") }
    assert_equal({ "host" => "127.0.0.1:4100" }, e.params)
  end
end
