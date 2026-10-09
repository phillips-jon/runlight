package sh.runlight.core;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.Connect;
import sh.runlight.ConnectError;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.importers.FakeService;
import sh.runlight.store.Stores;

/**
 * Connecting an install through its consent page with the real core as the hub, as hub.test.ts
 * tests it: the site and connection the hub keeps. The codes for what went wrong are in
 * sh.runlight.ConnectTest.
 */
class ConnectTest {
  private static final String APP = "http://127.0.0.1:4100/runlight";

  private final long now = 1_791_288_000_000L;

  private static FakeService install() {
    return new FakeService()
        .route(
            "/\\.well-known/oauth-authorization-server$",
            Json.object(
                "authorization_endpoint", "http://127.0.0.1:4100/runlight/oauth/authorize",
                "token_endpoint", "http://127.0.0.1:4100/runlight/oauth/token",
                "registration_endpoint", "http://127.0.0.1:4100/runlight/oauth/register",
                "scopes_supported", List.of("read", "manage")))
        .route("/oauth/register$", new FakeService.Status(201, Json.object("client_id", "c1")))
        .route("/oauth/token$", Json.object("access_token", "rl_manage", "site", "blog"))
        .route(
            "/api/sites$",
            Json.object(
                "sites",
                Json.array(
                    Json.object(
                        "id",
                        "shop",
                        "name",
                        "Shop",
                        "timezone",
                        "UTC",
                        "hostnames",
                        List.of("shop.example.com")),
                    Json.object(
                        "id",
                        "blog",
                        "name",
                        "Blog",
                        "timezone",
                        "Asia/Tokyo",
                        "hostnames",
                        List.of("blog.example.com")))))
        .route("/api/token$", Json.object("scope", "manage", "site", "blog"));
  }

  @Test
  void aHubConnectsAnAppThroughItsConsentPageForTheOneSiteTheOwnerPicked()
      throws NoSuchAlgorithmException {
    FakeService router = install();
    Runlight hub =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .managedSites(true)
                .secret("k".repeat(32))
                .fetcher(router)
                .now(() -> now));
    hub.init();
    String back = "http://localhost:4900/runlight/api/sites/connect/done";
    Url consent = new Url(Connect.startConnect(hub.store, hub.fetcher, hub::now, APP + "/", back));
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
    assertTrue(q.get("state").matches("[a-f0-9]{32}"));
    assertNull(q.get("site"));
    Fixtures.assertJson(
        Json.object("client_name", "Runlight at localhost:4900", "redirect_uris", List.of(back)),
        Json.parse(router.requests.get(1).init().bodyText()));

    Map<String, Object> pending =
        Js.map(Json.parse(hub.store.setting("connect:" + q.get("state"))));
    String verifier = (String) pending.get("verifier");
    String challenge =
        Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(
                MessageDigest.getInstance("SHA-256")
                    .digest(verifier.getBytes(StandardCharsets.UTF_8)));
    assertEquals(challenge, q.get("code_challenge"), "the challenge is the verifier hashed");
    assertEquals(now + 15 * 60_000L, Js.asLong(pending.get("expires")));

    String id =
        Connect.finishConnect(
            hub.store,
            hub.fetcher,
            hub::now,
            hub::addSite,
            new SearchParams(Map.of("state", q.get("state"), "code", "the-code")));
    assertEquals("blog.example.com", id);
    Fixtures.assertJson(
        Json.object(
            "url",
            APP,
            "token",
            "rl_manage",
            "site",
            "blog",
            "hostnames",
            List.of("blog.example.com"),
            "scope",
            "manage"),
        hub.remote(id));
    Fixtures.assertJson(
        Json.object(
            "id",
            "blog.example.com",
            "name",
            "Blog",
            "hostnames",
            List.of(),
            "timezone",
            "Asia/Tokyo"),
        hub.site(id));
    FakeService.Sent exchange = null;
    for (FakeService.Sent sent : router.requests) {
      if (sent.url().endsWith("/oauth/token")) {
        exchange = sent;
        break;
      }
    }
    SearchParams form = new SearchParams(exchange.init().bodyText());
    assertEquals(
        List.of("authorization_code", "the-code", "c1", back, verifier),
        List.of(
            form.get("grant_type"),
            form.get("code"),
            form.get("client_id"),
            form.get("redirect_uri"),
            form.get("code_verifier")));

    // A code works once.
    ConnectError e =
        assertThrows(
            ConnectError.class,
            () ->
                Connect.finishConnect(
                    hub.store,
                    hub.fetcher,
                    hub::now,
                    hub::addSite,
                    new SearchParams(Map.of("state", q.get("state"), "code", "the-code"))));
    assertEquals("expired", e.code());
  }
}
