package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;
import sh.runlight.http.FetchError;
import sh.runlight.http.Fetcher;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.importers.FakeService;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * Connecting an install through its consent page, as hub.test.ts tests it, with the install played
 * by a FakeService. What the hub does with the site it is given (addSite, remote(), site()) is the
 * Runlight core's, so here addSite only records what it was asked to add.
 */
class ConnectTest {
  private static final String APP = "http://127.0.0.1:4100/runlight";

  private long now = 1_791_288_000_000L;

  /** An install that speaks OAuth, as an app's Runlight does. */
  private static FakeService install(Map<String, Object> meta, Object registered, int status) {
    Map<String, Object> answer =
        meta != null
            ? meta
            : Json.object(
                "authorization_endpoint", "http://127.0.0.1:4100/runlight/oauth/authorize",
                "token_endpoint", "http://127.0.0.1:4100/runlight/oauth/token",
                "registration_endpoint", "http://127.0.0.1:4100/runlight/oauth/register",
                "scopes_supported", Json.array("read", "manage"));
    return new FakeService()
        .route("/\\.well-known/oauth-authorization-server$", answer)
        .route("/oauth/register$", new FakeService.Status(status, registered))
        .route("/oauth/token$", Json.object("access_token", "rl_manage", "site", "blog"));
  }

  private static FakeService install() {
    return install(null, Json.object("client_id", "c1"), 201);
  }

  /** A hub: a store, the install's fetcher, and the test's clock. */
  private final class Hub {
    final SqlStore store = Stores.sqlite(":memory:");
    final Fetcher fetcher;
    final List<Map<String, Object>> added = new ArrayList<>();

    Hub(Fetcher fetcher) {
      this.fetcher = fetcher;
      store.migrate();
    }

    String start(Object input, String back, String site) {
      return Connect.startConnect(store, fetcher, () -> now, input, back, site);
    }

    String start(Object input, String back) {
      return Connect.startConnect(store, fetcher, () -> now, input, back);
    }

    String finish(SearchParams params) {
      Function<Map<String, Object>, Map<String, Object>> addSite =
          options -> {
            added.add(options);
            return Json.object("id", "blog.example.com");
          };
      return Connect.finishConnect(store, fetcher, () -> now, addSite, params);
    }
  }

  private static ConnectError refused(Executable fn, String code) {
    ConnectError e = assertThrows(ConnectError.class, fn, "no " + code);
    assertEquals(code, e.code());
    return e;
  }

  private static SearchParams params(String... pairs) {
    SearchParams p = new SearchParams();
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      p.append(pairs[i], pairs[i + 1]);
    }
    return p;
  }

  @Test
  void aHubConnectsAnAppThroughItsConsentPageForTheOneSiteTheOwnerPicked() {
    FakeService router = install();
    Hub hub = new Hub(router);
    String back = "http://localhost:4900/runlight/api/sites/connect/done";
    Url consent = new Url(hub.start(APP + "/", back));
    assertEquals(
        "http://127.0.0.1:4100/runlight/oauth/authorize", consent.origin() + consent.pathname);
    SearchParams q = consent.searchParams();
    assertEquals(
        List.of("code", "c1", back, "S256", "manage"),
        List.of(
            q.get("response_type"),
            q.get("client_id"),
            q.get("redirect_uri"),
            q.get("code_challenge_method"),
            q.get("scope")));
    String state = q.get("state");
    assertTrue(state.matches("[a-f0-9]{32}"));
    assertNull(q.get("site"));
    assertEquals(
        Json.stringify(
            Json.object(
                "client_name", "Runlight at localhost:4900", "redirect_uris", Json.array(back))),
        router.requests.get(1).init().bodyText());

    Map<String, Object> pending = Js.map(Json.parse(hub.store.setting("connect:" + state)));
    assertEquals(
        Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(Hash.sha256Bytes(Js.utf8((String) pending.get("verifier")))),
        q.get("code_challenge"),
        "the challenge is the verifier hashed");
    assertEquals(now + 15 * 60_000, Js.asLong(pending.get("expires")));

    String id = hub.finish(params("state", state, "code", "the-code"));
    assertEquals("blog.example.com", id);
    assertEquals(
        Json.stringify(
            Json.array(
                Json.object(
                    "remote", Json.object("url", APP, "token", "rl_manage", "site", "blog")))),
        Json.stringify(hub.added));
    FakeService.Sent exchange = null;
    for (FakeService.Sent r : router.requests) {
      if (r.url().endsWith("/oauth/token")) {
        exchange = r;
      }
    }
    SearchParams form = new SearchParams(exchange.init().bodyText());
    assertEquals(
        List.of("authorization_code", "the-code", "c1", back, pending.get("verifier")),
        List.of(
            form.get("grant_type"),
            form.get("code"),
            form.get("client_id"),
            form.get("redirect_uri"),
            form.get("code_verifier")));

    // A code works once.
    refused(() -> hub.finish(params("state", state, "code", "the-code")), "expired");
  }

  @Test
  void whatWentWrongComesBackAsACode() {
    Hub hub = new Hub(install());
    Function<String, SearchParams> start =
        site -> new Url(hub.start(APP, "https://hub.example/done", site)).searchParams();
    assertEquals("blog", start.apply("blog").get("site"), "which of its sites to offer first");
    SearchParams denied = start.apply("");
    refused(
        () -> hub.finish(params("state", denied.get("state"), "error", "access_denied")), "denied");
    SearchParams other = start.apply("");
    ConnectError e =
        refused(
            () ->
                hub.finish(
                    params(
                        "state",
                        other.get("state"),
                        "error",
                        "server_error",
                        "error_description",
                        "Sign in again")),
            "refused");
    assertEquals("Sign in again", e.getMessage());
    refused(() -> hub.finish(params("state", "not-a-state")), "expired");
    // An attempt nobody came back from in time.
    SearchParams late = start.apply("");
    now += 16 * 60_000;
    refused(() -> hub.finish(params("state", late.get("state"))), "expired");
    // Starting again clears the ones that ran out.
    var unused = start.apply("");
    assertEquals(1, hub.store.settingsStartingWith("connect:").size());
  }

  @Test
  void aHubOnlyFollowsAnInstallsOwnEndpointsWhenConnecting() {
    FakeService hostile =
        install(
            Json.object(
                "authorization_endpoint", "http://127.0.0.1:1/authorize",
                "token_endpoint", "http://169.254.169.254/token",
                "registration_endpoint", "http://169.254.169.254/register",
                "scopes_supported", Json.array("read", "manage")),
            Json.object("client_id", "c1"),
            201);
    Hub hub = new Hub(hostile);
    ConnectError e =
        refused(() -> hub.start("http://127.0.0.1:4100", "https://hub.example/done"), "endpoints");
    assertTrue(e.getMessage().contains("named endpoints on another address"));
    assertEquals(1, hostile.requests.size(), "nothing else was asked");
  }

  @Test
  void anInstallWhoseScopesSupportedIsNotAListCountsAsAnOlderRunlight() {
    for (Object scopes : List.of("unmanaged", "manage", 7L)) {
      FakeService odd =
          install(
              Json.object(
                  "authorization_endpoint", APP + "/oauth/authorize",
                  "token_endpoint", APP + "/oauth/token",
                  "registration_endpoint", APP + "/oauth/register",
                  "scopes_supported", scopes),
              Json.object("client_id", "c1"),
              201);
      ConnectError e = refused(() -> new Hub(odd).start(APP, "https://hub.example/done"), "old");
      assertTrue(e.getMessage().contains("older Runlight"), Json.stringify(scopes));
    }
  }

  @Test
  void anInstallThatCannotConnectSaysWhy() {
    refused(() -> new Hub(install()).start("ftp://x", "https://hub.example/done"), "url");
    refused(
        () -> new Hub(new FakeService()).start(APP, "https://hub.example/done"), "not_runlight");
    FakeService old =
        install(
            Json.object(
                "authorization_endpoint", APP + "/oauth/authorize",
                "token_endpoint", APP + "/oauth/token",
                "registration_endpoint", APP + "/oauth/register",
                "scopes_supported", Json.array("read")),
            Json.object("client_id", "c1"),
            201);
    refused(() -> new Hub(old).start(APP, "https://hub.example/done"), "old");
    ConnectError e =
        refused(
            () ->
                new Hub(
                        install(
                            null,
                            Json.object("error_description", "redirect_uris must use https"),
                            400))
                    .start(APP, "http://hub.example/done"),
            "register");
    assertEquals(
        Json.stringify(Json.object("url", APP, "reason", "redirect_uris must use https.")),
        Json.stringify(e.params()));
    e =
        refused(
            () ->
                new Hub(install(null, Json.object("nope", true), 400))
                    .start(APP, "http://hub.example/done"),
            "register");
    assertEquals("This server's address must use https.", e.params().get("reason"));
    Fetcher down =
        (url, init) -> {
          throw new FetchError("refused");
        };
    e = refused(() -> new Hub(down).start(APP, "https://hub.example/done"), "unreachable");
    assertEquals(Map.of("host", "127.0.0.1:4100"), e.params());
  }

  @Test
  void anAddressTheUrlParserRefusesIsTheAddressError() {
    for (String url : List.of("https://[", "https://[::1", "https://a b")) {
      refused(() -> Connect.installUrl(url), "url");
    }
    assertEquals(
        "https://example.com/runlight", Connect.installUrl("https://example.com/runlight/"));
  }

  @Test
  void anAttemptSavedWithoutAnExpiryHasExpired() {
    FakeService router = install();
    Hub hub = new Hub(router);
    String state = "a".repeat(32);
    for (Object stored :
        Json.array(
            Json.object(
                "url",
                APP,
                "client",
                "c",
                "verifier",
                "v",
                "redirect",
                "https://hub.example/done",
                "token",
                APP + "/oauth/token"),
            null,
            5L,
            Json.object("expires", "9999999999999"))) {
      hub.store.setSetting("connect:" + state, Json.stringify(stored));
      refused(() -> hub.finish(params("state", state, "code", "c")), "expired");
    }
    assertEquals(List.of(), router.requests, "nothing was fetched");
    // Starting clears every attempt that cannot be read or has no expiry.
    Hub fresh = new Hub(install());
    Map<String, String> saved =
        Map.of("b", "null", "c", "5", "d", "not json", "e", "{\"url\":\"x\"}");
    saved.forEach((letter, value) -> fresh.store.setSetting("connect:" + letter.repeat(32), value));
    var unused = fresh.start(APP, "https://hub.example/done");
    assertEquals(1, fresh.store.settingsStartingWith("connect:").size());
  }
}
