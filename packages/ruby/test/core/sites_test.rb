# frozen_string_literal: true

require "test_helper"
require_relative "../support/core_test_case"

# Sites in code and in the dashboard, retention, and connected installs, as sites.test.ts and hub.test.ts test them without routes.
class CoreSitesTest < CoreTestCase
  Response = Runlight::Http::Response

  def refused(code, &block)
    e = assert_raises(Runlight::SettingsError, "no #{code}", &block)
    assert_equal code, e.code
    e
  end

  on_every_database("managed sites are added changed and deleted and outlive a restart") do |kind|
    store = Databases.fresh(kind)
    t = Harness.new(store, { "managedSites" => true, "site" => { "name" => "Ignored" } })
    rl = t.rl
    rl.init
    assert_equal [], rl.sites, "no sites until one is added; the site in code is ignored"

    refused("site_domain_needed") { rl.add_site({ "name" => "Blog" }) }
    refused("site_domain_invalid") { rl.add_site({ "hostnames" => "not a domain" }) }
    blog = rl.add_site({ "name" => "Blog", "hostnames" => "https://www.blog.example.com/path", "timezone" => "Europe/London" })
    assert_equal({ "id" => "blog.example.com", "name" => "Blog", "hostnames" => ["blog.example.com"], "timezone" => "Europe/London" }, blog)
    shop = rl.add_site({ "hostnames" => ["shop.example.com", "store.example.com"] })
    assert_equal "shop.example.com", shop["name"], "the name defaults to the domain"
    taken = refused("site_domain_taken") { rl.add_site({ "hostnames" => "store.example.com" }) }
    assert_match(/already belongs to shop\.example\.com/, taken.message)
    refused("unknown_timezone") { rl.add_site({ "hostnames" => "x.example.com", "timezone" => "Nowhere" }) }

    # Visits reach the right site by hostname, across origins.
    send_hit = ->(page, ip) { rl.collect(Harness.hit("https://stats.example.com/runlight/e", { "k" => "pageview", "u" => page }, { "ip" => ip })) }
    send_hit.call("https://blog.example.com/hello", "203.0.113.1")
    send_hit.call("https://store.example.com/", "203.0.113.2")
    send_hit.call("https://elsewhere.example/", "203.0.113.3")
    assert_equal 1, t.stats(t.today("blog.example.com"))["pageviews"]
    assert_equal 1, t.stats(t.today("shop.example.com"))["pageviews"]

    renamed = rl.update_site("shop.example.com", { "name" => "Shop", "hostnames" => "shop.example.com" })
    assert_equal ["shop.example.com"], renamed["hostnames"]
    refused("site_domain_taken") { rl.update_site("shop.example.com", { "hostnames" => "blog.example.com" }) }
    refused("site_name") { rl.update_site("shop.example.com", { "name" => "x" * 81 }) }

    # A restart reads the sites back from the database.
    again = Runlight::Core.new({ "store" => store, "managedSites" => true })
    again.init
    assert_equal [["blog.example.com", "Blog"], ["shop.example.com", "Shop"]], again.sites.map { |s| [s["id"], s["name"]] }

    rl.delete_site("shop.example.com")
    refused("unknown_site") { rl.delete_site("shop.example.com") }
    assert_equal ["blog.example.com"], rl.sites.map { |s| s["id"] }
    assert_equal 0, t.count("SELECT COUNT(*) AS n FROM rl_events WHERE site = ?", ["shop.example.com"]), "a deleted site's visits go with it"
  end

  def test_sites_set_in_code_cannot_be_added_or_deleted_but_can_be_renamed
    rl = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "site" => { "name" => "Code" } })
    refused("sites_in_code") { rl.add_site({ "hostnames" => "a.com" }) }
    refused("sites_in_code") { rl.delete_site("default") }
    refute rl.managed_sites
    site = rl.update_site("default", { "name" => " Renamed ", "timezone" => "Europe/Paris" })
    assert_equal({ "id" => "default", "name" => "Renamed", "hostnames" => [], "timezone" => "Europe/Paris" }, site)
    assert_equal({ "name" => "Renamed", "timezone" => "Europe/Paris" }, rl.store.site_overrides["default"])
    refused("unknown_site") { rl.update_site("nope", { "name" => "x" }) }
  end

  def test_a_second_server_process_on_the_same_database_sees_new_sites_and_connected_installs_at_its_next_check
    store = Runlight::Stores.sqlite(":memory:")
    fetcher = FakeFetcher.new { Response.json({ "sites" => [{ "id" => "default", "name" => "App", "timezone" => "UTC", "hostnames" => ["app.example.com"] }] }) }
    one = Runlight::Core.new({ "store" => store, "managedSites" => true, "secret" => "k" * 32, "fetcher" => fetcher })
    two = Runlight::Core.new({ "store" => store, "managedSites" => true, "secret" => "k" * 32, "fetcher" => fetcher })
    one.init
    two.init
    one.add_site({ "hostnames" => "new.example.com" })
    one.add_site({ "remote" => { "url" => "https://app.example.com/runlight", "token" => "rl_x" } })
    assert_equal [], two.sites.map { |s| s["id"] }, "not yet"
    two.check
    assert_equal %w[app.example.com new.example.com], two.sites.map { |s| s["id"] }.sort
    assert_equal "https://app.example.com/runlight", two.remote("app.example.com")["url"]
    stored = store.setting("remote:app.example.com").to_s
    assert stored.start_with?("v1:")
    refute_includes stored, "rl_x", "the token is sealed"
  end

  on_every_database("a sites retention setting deletes visits older than it allows") do |kind|
    t = Harness.new(kind, { "site" => { "hostnames" => ["example.com"] } })
    hit = ->(ip) { t.track({ "k" => "pageview", "u" => "https://example.com/" }, { "ip" => ip }) }
    visits = -> { t.stats(t.all)["visits"] }
    t.now = utc(2025, 10, 1)
    hit.call("203.0.113.1")
    t.now = utc(2026, 7, 1)
    hit.call("203.0.113.2")
    t.now = utc(2026, 10, 6, 12)
    hit.call("203.0.113.3")
    assert_equal 3, visits.call
    assert_nil t.rl.retention("default"), "everything is kept by default"

    refused("retention_bad") { t.rl.set_retention("default", 7) }
    refused("unknown_site") { t.rl.set_retention("elsewhere", 6) }
    t.rl.set_retention("default", 6)
    assert_equal 3, visits.call, "the deleting waits for idle(), as TS runs it after answering"
    t.rl.idle
    assert_equal 6, t.rl.retention("default")
    assert_equal 2, visits.call, "the visit from a year ago is gone"

    t.now = utc(2027, 2, 1)
    t.rl.check
    assert_equal 1, visits.call, "the scheduled check keeps trimming"
    t.rl.set_retention("default", nil)
    assert_nil t.rl.retention("default")
  end

  def test_retention_counts_back_calendar_months_as_set_utc_month_does
    t = Harness.new("sqlite")
    t.rl.init
    t.rl.set_retention("default", 6)
    t.now = utc(2026, 8, 31, 10, 30) + 123
    # February 31st runs on to March 3rd, as JavaScript's dates do.
    assert_equal utc(2026, 3, 3, 10, 30) + 123, t.rl.retention_cutoff("default")
  end

  def test_deleting_a_site_forgets_its_retention_its_plugin_key_and_its_umami_import_progress
    rl = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "managedSites" => true })
    rl.init
    site = rl.add_site({ "hostnames" => "gone.example.com" })
    rl.set_retention(site["id"], 12)
    rl.store.set_setting("observe-key:#{site["id"]}", "rlo_x")
    rl.store.set_setting("import:umami-visits:#{site["id"]}:w1", "{}")
    rl.delete_site(site["id"])
    rl.idle
    assert_nil rl.store.setting("retention:#{site["id"]}")
    assert_nil rl.store.setting("observe-key:#{site["id"]}")
    assert_nil rl.store.setting("import:umami-visits:#{site["id"]}:w1")
  end

  def test_a_connected_install_is_read_through_its_api_at_most_once_a_minute
    answers = []
    fetcher = FakeFetcher.new { answers.shift || Response.json({ "sites" => [] }) }
    t = Harness.new("sqlite", { "managedSites" => true, "secret" => "k" * 32, "fetcher" => fetcher })
    answers = [Response.json({ "sites" => [{ "id" => "default", "name" => "Shop", "timezone" => "Europe/Paris", "hostnames" => ["shop.example.com"] }] }), Response.new("", status: 404)]
    site = t.rl.add_site({ "remote" => { "url" => "https://shop.example.com/runlight/", "token" => "rl_1" } })
    assert_equal({ "id" => "shop.example.com", "name" => "Shop", "hostnames" => [], "timezone" => "Europe/Paris" }, site)
    assert_equal({ "url" => "https://shop.example.com/runlight", "token" => "rl_1", "site" => "default", "hostnames" => ["shop.example.com"], "scope" => "read" },
                 t.rl.remote(site["id"]))
    assert_equal "Bearer rl_1", fetcher.requests[0]["headers"]["authorization"]

    answers = [Response.json({ "sites" => [{ "id" => "default", "lastSeen" => 123, "retentionMonths" => 12 }] })]
    assert_equal({ "lastSeen" => 123, "retentionMonths" => 12, "connection" => "ok" }, t.rl.remote_info(site["id"]))
    asked = fetcher.requests.length
    assert_equal 123, t.rl.remote_last_seen(site["id"]), "from what it said a moment ago"
    assert_equal asked, fetcher.requests.length
    t.advance(60_000)
    answers = [Response.new('{"error":"Unauthorized"}', status: 401)]
    info = t.rl.remote_info(site["id"])
    assert_equal "refused", info["connection"]
    assert_equal 123, info["lastSeen"], "the last visit it gave before"
    assert_equal '{"lastSeen":123,"connection":"refused"}', Runlight::Json.encode(info), "retention unknown, as TS leaves it undefined"
    t.rl.forget_remote_info(site["id"])

    # Hits never land on a site counted elsewhere, even when they name it.
    t.rl.collect(Harness.hit("https://stats.example.com/runlight/e", { "k" => "pageview", "u" => "https://shop.example.com/", "s" => site["id"] }))
    assert_equal 0, t.count("SELECT COUNT(*) AS n FROM rl_events")
    refused("unknown_site") { t.rl.set_retention(site["id"], 6) }

    # Deleting it asks the install to delete the token, and keeps nothing of it here.
    answers = [Response.new("", status: 204)]
    t.rl.delete_site(site["id"])
    last = fetcher.requests[-1]
    assert_equal ["DELETE", "https://shop.example.com/runlight/api/token"], [last["method"], last["url"]]
    assert_equal [], t.store.settings_starting_with("remote:")
  end

  def test_connecting_again_with_a_manage_token_upgrades_the_same_connection_and_revokes_the_old_token
    scope = "read"
    fetcher = FakeFetcher.new do |url, init|
      if url.end_with?("/api/sites")
        Response.json({ "sites" => [{ "id" => "default", "name" => "Shop", "timezone" => "UTC", "hostnames" => ["shop.example.com"] }] })
      elsif (init["method"] || "GET") == "DELETE"
        Response.new("", status: 204)
      else
        Response.json({ "scope" => scope, "site" => "default" })
      end
    end
    hub = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "managedSites" => true, "secret" => "k" * 32, "fetcher" => fetcher,
                               "localInstalls" => true })
    first = hub.add_site({ "remote" => { "url" => "http://127.0.0.1:4100/runlight", "token" => "rl_read" } })["id"]
    assert_equal "read", hub.remote(first)["scope"]
    scope = "manage"
    second = hub.add_site({ "remote" => { "url" => "http://127.0.0.1:4100/runlight", "token" => "rl_manage" } })["id"]
    assert_equal first, second
    assert_equal "manage", hub.remote(first)["scope"]
    assert_equal "rl_manage", hub.remote(first)["token"]
    assert_equal 1, hub.sites.length
    revoked = fetcher.requests.select { |r| r["method"] == "DELETE" }
    assert_equal "Bearer rl_read", revoked[0]["headers"]["authorization"], "the old token was deleted there"
  end

  def test_a_connection_is_refused_with_a_code_the_dashboard_can_say
    answer = nil
    fetcher = FakeFetcher.new do
      raise Runlight::Http::FetchError, "Could not connect" if answer == "network"

      answer
    end
    hub = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "managedSites" => true, "fetcher" => fetcher })
    refused("connect_url") { hub.add_site({ "remote" => { "url" => "http://example.com", "token" => "x" } }) }
    refused("install_token") { hub.add_site({ "remote" => { "url" => "https://example.com", "token" => " " } }) }
    answer = "network"
    e = refused("unreachable") { hub.add_site({ "remote" => { "url" => "https://example.com:8443/runlight", "token" => "x" } }) }
    assert_equal({ "host" => "example.com:8443" }, e.params)
    answer = Response.new("", status: 401)
    refused("install_refused") { hub.add_site({ "remote" => { "url" => "https://example.com", "token" => "x" } }) }
    answer = Response.json({ "sites" => [] })
    e = refused("connect_not_runlight") { hub.add_site({ "remote" => { "url" => "https://example.com", "token" => "x" } }) }
    assert_equal({ "url" => "https://example.com" }, e.params)
  end

  def test_assistant_settings_keep_a_key_only_for_the_same_service_at_the_same_address
    rl = Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:"), "secret" => "k" * 32 })
    rl.init
    refused("assistant_provider") { rl.save_assistant_settings({ "provider" => "nope" }) }
    refused("assistant_key") { rl.save_assistant_settings({ "provider" => "anthropic" }) }
    refused("assistant_address") { rl.save_assistant_settings({ "provider" => "custom", "model" => "m" }) }
    refused("assistant_address_bad") { rl.save_assistant_settings({ "provider" => "custom", "baseUrl" => "ftp://x", "model" => "m" }) }
    refused("assistant_model") { rl.save_assistant_settings({ "provider" => "openai", "key" => "k" }) }
    rl.save_assistant_settings({ "provider" => "anthropic", "key" => "sk-1" })
    assert_equal({ "provider" => "anthropic", "model" => "", "baseUrl" => "", "key" => "sk-1" }, rl.assistant_settings)
    refute_includes rl.store.setting("assistant").to_s, "sk-1"
    rl.save_assistant_settings({ "provider" => "anthropic", "model" => "claude-x", "key" => "" })
    assert_equal "sk-1", rl.assistant_settings["key"], "same service, blank key: kept"
    refused("assistant_key") { rl.save_assistant_settings({ "provider" => "anthropic", "baseUrl" => "https://proxy.example/v1/", "key" => "" }) }
    rl.save_assistant_settings(nil)
    assert_nil rl.assistant_settings
    # An empty object is not nothing, as TS reads `!input`: it names no provider.
    refused("assistant_provider") { rl.save_assistant_settings({}) }
  end
end
