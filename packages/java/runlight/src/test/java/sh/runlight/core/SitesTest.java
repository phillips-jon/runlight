package sh.runlight.core;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.core.Harness.utc;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;
import java.util.function.LongSupplier;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.CodedError.SettingsError;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.RecordingFetcher;
import sh.runlight.Runlight;
import sh.runlight.http.FetchError;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;
import sh.runlight.store.Databases;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * Sites in code and in the dashboard, retention, and connected installs, as sites.test.ts and
 * hub.test.ts test them without routes.
 */
class SitesTest {
  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void tearDown() {
    Databases.cleanup();
  }

  private static SettingsError refused(Executable fn, String code) {
    SettingsError e = assertThrows(SettingsError.class, fn, "no " + code);
    assertEquals(code, e.code(), e.getMessage());
    return e;
  }

  private static List<Object> column(List<Map<String, Object>> rows, String key) {
    List<Object> out = new ArrayList<>();
    for (Map<String, Object> r : rows) {
      out.add(r.get(key));
    }
    return out;
  }

  private static Response json(Object body) {
    return new Response(Json.stringify(body), 200, Headers.of("content-type", "application/json"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void managedSitesAreAddedChangedAndDeletedAndOutliveARestart(String kind) {
    SqlStore store = Databases.fresh(kind);
    Harness t =
        new Harness(
            store, new Runlight.Options().managedSites(true).site(Json.object("name", "Ignored")));
    Runlight rl = t.rl;
    rl.init();
    assertEquals(List.of(), rl.sites(), "no sites until one is added; the site in code is ignored");

    refused(() -> rl.addSite(Json.object("name", "Blog")), "site_domain_needed");
    refused(() -> rl.addSite(Json.object("hostnames", "not a domain")), "site_domain_invalid");
    Map<String, Object> blog =
        rl.addSite(
            Json.object(
                "name",
                "Blog",
                "hostnames",
                "https://www.blog.example.com/path",
                "timezone",
                "Europe/London"));
    Fixtures.assertJson(
        Json.object(
            "id",
            "blog.example.com",
            "name",
            "Blog",
            "hostnames",
            List.of("blog.example.com"),
            "timezone",
            "Europe/London"),
        blog);
    Map<String, Object> shop =
        rl.addSite(Json.object("hostnames", List.of("shop.example.com", "store.example.com")));
    assertEquals("shop.example.com", shop.get("name"), "the name defaults to the domain");
    SettingsError taken =
        refused(
            () -> rl.addSite(Json.object("hostnames", "store.example.com")), "site_domain_taken");
    assertTrue(taken.getMessage().contains("already belongs to shop.example.com"));
    refused(
        () -> rl.addSite(Json.object("hostnames", "x.example.com", "timezone", "Nowhere")),
        "unknown_timezone");

    // Visits reach the right site by hostname, across origins.
    for (String[] hit :
        new String[][] {
          {"https://blog.example.com/hello", "203.0.113.1"},
          {"https://store.example.com/", "203.0.113.2"},
          {"https://elsewhere.example/", "203.0.113.3"}
        }) {
      rl.collect(
          Harness.hit(
              "https://stats.example.com/runlight/e",
              Json.object("k", "pageview", "u", hit[0]),
              Json.object("ip", hit[1])));
    }
    assertEquals(1L, t.stats(t.today("blog.example.com")).get("pageviews"));
    assertEquals(1L, t.stats(t.today("shop.example.com")).get("pageviews"));

    Map<String, Object> renamed =
        rl.updateSite(
            "shop.example.com", Json.object("name", "Shop", "hostnames", "shop.example.com"));
    assertEquals(List.of("shop.example.com"), renamed.get("hostnames"));
    refused(
        () -> rl.updateSite("shop.example.com", Json.object("hostnames", "blog.example.com")),
        "site_domain_taken");
    refused(
        () -> rl.updateSite("shop.example.com", Json.object("name", "x".repeat(81))), "site_name");

    // A restart reads the sites back from the database.
    Runlight again = new Runlight(new Runlight.Options().store(store).managedSites(true));
    again.init();
    List<Object> pairs = new ArrayList<>();
    for (Map<String, Object> s : again.sites()) {
      pairs.add(List.of(s.get("id"), s.get("name")));
    }
    assertEquals(
        List.of(List.of("blog.example.com", "Blog"), List.of("shop.example.com", "Shop")), pairs);

    rl.deleteSite("shop.example.com");
    refused(() -> rl.deleteSite("shop.example.com"), "unknown_site");
    assertEquals(List.of("blog.example.com"), column(rl.sites(), "id"));
    assertEquals(
        0,
        t.count("SELECT COUNT(*) AS n FROM rl_events WHERE site = ?", "shop.example.com"),
        "a deleted site's visits go with it");
  }

  @Test
  void sitesSetInCodeCannotBeAddedOrDeletedButCanBeRenamed() {
    Runlight rl =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .site(Json.object("name", "Code")));
    refused(() -> rl.addSite(Json.object("hostnames", "a.com")), "sites_in_code");
    refused(() -> rl.deleteSite("default"), "sites_in_code");
    assertFalse(rl.managedSites);
    Map<String, Object> site =
        rl.updateSite("default", Json.object("name", " Renamed ", "timezone", "Europe/Paris"));
    Fixtures.assertJson(
        Json.object(
            "id", "default", "name", "Renamed", "hostnames", List.of(), "timezone", "Europe/Paris"),
        site);
    Fixtures.assertJson(
        Json.object("name", "Renamed", "timezone", "Europe/Paris"),
        rl.store.siteOverrides().get("default"));
    refused(() -> rl.updateSite("nope", Json.object("name", "x")), "unknown_site");
  }

  @Test
  void aSecondServerProcessOnTheSameDatabaseSeesNewSitesAndConnectedInstallsAtItsNextCheck() {
    SqlStore store = Stores.sqlite(":memory:");
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) ->
                json(
                    Json.object(
                        "sites",
                        Json.array(
                            Json.object(
                                "id",
                                "default",
                                "name",
                                "App",
                                "timezone",
                                "UTC",
                                "hostnames",
                                List.of("app.example.com"))))));
    Runlight.Options options =
        new Runlight.Options()
            .store(store)
            .managedSites(true)
            .secret("k".repeat(32))
            .fetcher(fetcher);
    Runlight one = new Runlight(options);
    Runlight two = new Runlight(options);
    one.init();
    two.init();
    one.addSite(Json.object("hostnames", "new.example.com"));
    one.addSite(
        Json.object(
            "remote", Json.object("url", "https://app.example.com/runlight", "token", "rl_x")));
    assertEquals(List.of(), column(two.sites(), "id"), "not yet");
    two.check();
    List<Object> ids = new ArrayList<>(column(two.sites(), "id"));
    ids.sort(null);
    assertEquals(List.of("app.example.com", "new.example.com"), ids);
    assertEquals("https://app.example.com/runlight", two.remote("app.example.com").get("url"));
    String stored = store.setting("remote:app.example.com");
    assertTrue(stored.startsWith("v1:"));
    assertFalse(stored.contains("rl_x"), "the token is sealed");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aSitesRetentionSettingDeletesVisitsOlderThanItAllows(String kind) {
    Harness t =
        new Harness(
            kind, new Runlight.Options().site(Json.object("hostnames", List.of("example.com"))));
    Consumer<String> hit =
        ip -> t.sendFrom(Json.object("k", "pageview", "u", "https://example.com/"), ip);
    LongSupplier visits = () -> Js.asLong(t.stats(t.all()).get("visits"));
    t.now = utc(2025, 10, 1);
    hit.accept("203.0.113.1");
    t.now = utc(2026, 7, 1);
    hit.accept("203.0.113.2");
    t.now = utc(2026, 10, 6, 12);
    hit.accept("203.0.113.3");
    assertEquals(3, visits.getAsLong());
    assertNull(t.rl.retention("default"), "everything is kept by default");

    refused(() -> t.rl.setRetention("default", 7L), "retention_bad");
    refused(() -> t.rl.setRetention("elsewhere", 6L), "unknown_site");
    t.rl.setRetention("default", 6L);
    assertEquals(
        3, visits.getAsLong(), "the deleting waits for idle(), as TS runs it after answering");
    t.rl.idle();
    assertEquals(6L, t.rl.retention("default"));
    assertEquals(2, visits.getAsLong(), "the visit from a year ago is gone");

    t.now = utc(2027, 2, 1);
    t.rl.check();
    assertEquals(1, visits.getAsLong(), "the scheduled check keeps trimming");
    t.rl.setRetention("default", null);
    assertNull(t.rl.retention("default"));
  }

  @Test
  void retentionCountsBackCalendarMonthsAsSetUtcMonthDoes() {
    Harness t = new Harness("sqlite");
    t.rl.init();
    t.rl.setRetention("default", 6L);
    t.now = utc(2026, 8, 31, 10, 30, 0) + 123;
    // February 31st runs on to March 3rd, as JavaScript's dates do.
    assertEquals(utc(2026, 3, 3, 10, 30, 0) + 123, t.rl.retentionCutoff("default"));
  }

  @Test
  void deletingASiteForgetsItsRetentionItsPluginKeyAndItsUmamiImportProgress() {
    Runlight rl =
        new Runlight(new Runlight.Options().store(Stores.sqlite(":memory:")).managedSites(true));
    rl.init();
    String id = (String) rl.addSite(Json.object("hostnames", "gone.example.com")).get("id");
    rl.setRetention(id, 12L);
    rl.store.setSetting("observe-key:" + id, "rlo_x");
    rl.store.setSetting("import:umami-visits:" + id + ":w1", "{}");
    rl.deleteSite(id);
    rl.idle();
    assertNull(rl.store.setting("retention:" + id));
    assertNull(rl.store.setting("observe-key:" + id));
    assertNull(rl.store.setting("import:umami-visits:" + id + ":w1"));
  }

  @Test
  void aConnectedInstallIsReadThroughItsApiAtMostOnceAMinute() {
    Deque<Response> answers = new ArrayDeque<>();
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) -> {
              Response next = answers.poll();
              return next != null ? next : json(Json.object("sites", List.of()));
            });
    Harness t =
        new Harness(
            "sqlite",
            new Runlight.Options().managedSites(true).secret("k".repeat(32)).fetcher(fetcher));
    answers.add(
        json(
            Json.object(
                "sites",
                Json.array(
                    Json.object(
                        "id",
                        "default",
                        "name",
                        "Shop",
                        "timezone",
                        "Europe/Paris",
                        "hostnames",
                        List.of("shop.example.com"))))));
    answers.add(new Response("", 404));
    Map<String, Object> site =
        t.rl.addSite(
            Json.object(
                "remote",
                Json.object("url", "https://shop.example.com/runlight/", "token", "rl_1")));
    String id = (String) site.get("id");
    Fixtures.assertJson(
        Json.object(
            "id",
            "shop.example.com",
            "name",
            "Shop",
            "hostnames",
            List.of(),
            "timezone",
            "Europe/Paris"),
        site);
    Fixtures.assertJson(
        Json.object(
            "url",
            "https://shop.example.com/runlight",
            "token",
            "rl_1",
            "site",
            "default",
            "hostnames",
            List.of("shop.example.com"),
            "scope",
            "read"),
        t.rl.remote(id));
    assertEquals("Bearer rl_1", Js.get(fetcher.requests.get(0).get("headers"), "authorization"));

    answers.clear();
    answers.add(
        json(
            Json.object(
                "sites",
                Json.array(
                    Json.object("id", "default", "lastSeen", 123L, "retentionMonths", 12L)))));
    Fixtures.assertJson(
        Json.object("lastSeen", 123L, "retentionMonths", 12L, "connection", "ok"),
        t.rl.remoteInfo(id));
    int asked = fetcher.requests.size();
    assertEquals(123L, Js.asLong(t.rl.remoteLastSeen(id)), "from what it said a moment ago");
    assertEquals(asked, fetcher.requests.size());
    t.advance(60_000);
    answers.clear();
    answers.add(new Response("{\"error\":\"Unauthorized\"}", 401));
    Map<String, Object> info = t.rl.remoteInfo(id);
    assertEquals("refused", info.get("connection"));
    assertEquals(123L, Js.asLong(info.get("lastSeen")), "the last visit it gave before");
    assertEquals(
        "{\"lastSeen\":123,\"connection\":\"refused\"}",
        Json.stringify(info),
        "retention unknown, as TS leaves it undefined");
    t.rl.forgetRemoteInfo(id);

    // Hits never land on a site counted elsewhere, even when they name it.
    t.rl.collect(
        Harness.hit(
            "https://stats.example.com/runlight/e",
            Json.object("k", "pageview", "u", "https://shop.example.com/", "s", id),
            Map.of()));
    assertEquals(0, t.count("SELECT COUNT(*) AS n FROM rl_events"));
    refused(() -> t.rl.setRetention(id, 6L), "unknown_site");

    // Deleting it asks the install to delete the token, and keeps nothing of it here.
    answers.clear();
    answers.add(new Response("", 204));
    t.rl.deleteSite(id);
    Map<String, Object> last = fetcher.requests.get(fetcher.requests.size() - 1);
    assertEquals(
        List.of("DELETE", "https://shop.example.com/runlight/api/token"),
        List.of(last.get("method"), last.get("url")));
    assertEquals(List.of(), t.store().settingsStartingWith("remote:"));
  }

  @Test
  void connectingAgainWithAManageTokenUpgradesTheSameConnectionAndRevokesTheOldToken() {
    AtomicReference<String> scope = new AtomicReference<>("read");
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) -> {
              if (url.endsWith("/api/sites")) {
                return json(
                    Json.object(
                        "sites",
                        Json.array(
                            Json.object(
                                "id",
                                "default",
                                "name",
                                "Shop",
                                "timezone",
                                "UTC",
                                "hostnames",
                                List.of("shop.example.com")))));
              }
              if ("DELETE".equals(init.method)) {
                return new Response("", 204);
              }
              return json(Json.object("scope", scope.get(), "site", "default"));
            });
    Runlight hub =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .managedSites(true)
                .secret("k".repeat(32))
                .localInstalls(true)
                .fetcher(fetcher));
    String first =
        (String)
            hub.addSite(
                    Json.object(
                        "remote",
                        Json.object("url", "http://127.0.0.1:4100/runlight", "token", "rl_read")))
                .get("id");
    assertEquals("read", hub.remote(first).get("scope"));
    scope.set("manage");
    String second =
        (String)
            hub.addSite(
                    Json.object(
                        "remote",
                        Json.object("url", "http://127.0.0.1:4100/runlight", "token", "rl_manage")))
                .get("id");
    assertEquals(first, second);
    assertEquals("manage", hub.remote(first).get("scope"));
    assertEquals("rl_manage", hub.remote(first).get("token"));
    assertEquals(1, hub.sites().size());
    Map<String, Object> revoked = null;
    for (Map<String, Object> r : fetcher.requests) {
      if ("DELETE".equals(r.get("method"))) {
        revoked = r;
        break;
      }
    }
    assertEquals(
        "Bearer rl_read",
        Js.get(revoked.get("headers"), "authorization"),
        "the old token was deleted there");
  }

  @Test
  void aConnectionIsRefusedWithACodeTheDashboardCanSay() {
    AtomicReference<Object> answer = new AtomicReference<>();
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) -> {
              if ("network".equals(answer.get())) {
                throw new FetchError("Could not connect");
              }
              return (Response) answer.get();
            });
    Runlight hub =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .managedSites(true)
                .fetcher(fetcher));
    refused(() -> hub.addSite(remote("http://example.com", "x")), "connect_url");
    refused(() -> hub.addSite(remote("https://example.com", " ")), "install_token");
    answer.set("network");
    SettingsError e =
        refused(() -> hub.addSite(remote("https://example.com:8443/runlight", "x")), "unreachable");
    Fixtures.assertJson(Json.object("host", "example.com:8443"), e.params());
    answer.set(new Response("", 401));
    refused(() -> hub.addSite(remote("https://example.com", "x")), "install_refused");
    answer.set(json(Json.object("sites", List.of())));
    e = refused(() -> hub.addSite(remote("https://example.com", "x")), "connect_not_runlight");
    Fixtures.assertJson(Json.object("url", "https://example.com"), e.params());
  }

  @Test
  void anInstallOnAPrivateAddressIsNeverAskedAndARedirectIsNotFollowed() {
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) -> Response.redirect("http://169.254.169.254/latest/meta-data", 302));
    Runlight hub =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .managedSites(true)
                .fetcher(fetcher));
    refused(() -> hub.addSite(remote("https://127.0.0.1", "x")), "unreachable");
    refused(() -> hub.addSite(remote("https://[::ffff:10.0.0.1]", "x")), "unreachable");
    fetcher.dns = name -> List.of("192.168.1.10");
    refused(() -> hub.addSite(remote("https://hub.internal", "x")), "unreachable");
    assertEquals(0, fetcher.requests.size(), "nothing was sent");
    fetcher.dns = name -> List.of("93.184.215.14");
    refused(() -> hub.addSite(remote("https://hub.example", "x")), "connect_not_runlight");
    assertEquals(List.of("https://hub.example/api/sites"), fetcher.urls(), "the redirect stopped");
    // An install on this machine, for trying things out, only when code allows it.
    refused(() -> hub.addSite(remote("http://127.0.0.1:4100", "x")), "connect_url");
    Runlight local =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .managedSites(true)
                .localInstalls(true)
                .fetcher(fetcher));
    refused(() -> local.addSite(remote("http://127.0.0.1:4100", "x")), "connect_not_runlight");
    assertEquals("http://127.0.0.1:4100/api/sites", fetcher.urls().get(1));
    refused(() -> local.addSite(remote("http://10.0.0.1", "x")), "connect_url");
  }

  private static Map<String, Object> remote(String url, String token) {
    return Json.object("remote", Json.object("url", url, "token", token));
  }

  @Test
  void assistantSettingsKeepAKeyOnlyForTheSameServiceAtTheSameAddress() {
    Runlight rl =
        new Runlight(
            new Runlight.Options().store(Stores.sqlite(":memory:")).secret("k".repeat(32)));
    rl.init();
    refused(() -> rl.saveAssistantSettings(Json.object("provider", "nope")), "assistant_provider");
    refused(() -> rl.saveAssistantSettings(Json.object("provider", "anthropic")), "assistant_key");
    refused(
        () -> rl.saveAssistantSettings(Json.object("provider", "custom", "model", "m")),
        "assistant_address");
    refused(
        () ->
            rl.saveAssistantSettings(
                Json.object("provider", "custom", "baseUrl", "ftp://x", "model", "m")),
        "assistant_address_bad");
    refused(
        () -> rl.saveAssistantSettings(Json.object("provider", "openai", "key", "k")),
        "assistant_model");
    rl.saveAssistantSettings(Json.object("provider", "anthropic", "key", "sk-1"));
    Fixtures.assertJson(
        Json.object("provider", "anthropic", "model", "", "baseUrl", "", "key", "sk-1"),
        rl.assistantSettings());
    assertFalse(rl.store.setting("assistant").contains("sk-1"));
    rl.saveAssistantSettings(Json.object("provider", "anthropic", "model", "claude-x", "key", ""));
    assertEquals("sk-1", rl.assistantSettings().get("key"), "same service, blank key: kept");
    refused(
        () ->
            rl.saveAssistantSettings(
                Json.object(
                    "provider", "anthropic", "baseUrl", "https://proxy.example/v1/", "key", "")),
        "assistant_key");
    rl.saveAssistantSettings(null);
    assertNull(rl.assistantSettings());
  }
}
