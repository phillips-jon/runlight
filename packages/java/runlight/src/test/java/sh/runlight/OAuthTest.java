package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * OAuth on its own, over a stand-in for the Runlight on an in-memory store: the parts of
 * oauth.test.ts that need neither the core nor the routes. The routes' own OAuth tests are the
 * lead's.
 */
final class OAuthTest {
  /** A Runlight of fixed sites over an in-memory SQLite store, with a clock the test moves. */
  private static final class FakeInstall implements OAuth.Install {
    final SqlStore store = Stores.sqlite(":memory:");
    final AtomicLong clock = new AtomicLong(1_791_374_400_000L);
    final List<Map<String, Object>> sites;

    FakeInstall(List<Map<String, Object>> sites) {
      this.sites = sites;
      store.migrate();
    }

    @Override
    public void init() {}

    @Override
    public long now() {
      return clock.get();
    }

    @Override
    public SqlStore store() {
      return store;
    }

    @Override
    public String clientIp(Request request, Map<String, Object> context) {
      return context.get("ip") instanceof String ip ? ip : "";
    }

    @Override
    public List<Map<String, Object>> sites() {
      return sites;
    }

    @Override
    public Map<String, Object> site(String id) {
      for (Map<String, Object> s : sites) {
        if (s.get("id").equals(id)) {
          return s;
        }
      }
      return null;
    }

    @Override
    public Object remote(String id) {
      return null;
    }
  }

  private static String b64url(byte[] bytes) {
    return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
  }

  private static Response handle(
      OAuth.Context ctx, String url, String method, Headers headers, String body, String ip) {
    Url parsed = new Url(url);
    String path = parsed.pathname.substring("/runlight".length());
    return OAuth.oauthResponse(
        ctx,
        new Request(url, method, headers, body),
        path,
        parsed,
        ip == null ? Map.of() : Map.of("ip", ip));
  }

  private static String form(Map<String, String> fields) {
    return new SearchParams(fields).toString();
  }

  @Test
  void s256MatchesPkce() {
    // RFC 7636, appendix B.
    assertEquals(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        OAuth.s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
    assertEquals(
        "https://x.com/runlight/.well-known/oauth-protected-resource",
        OAuth.resourceMetadataUrl("https://x.com", "/runlight"));
  }

  @Test
  void theWellKnownDocumentsNameThisServer() {
    FakeInstall rl = new FakeInstall(List.of());
    OAuth.Context ctx = new OAuth.Context(rl, "/runlight", r -> true);
    Response resource =
        handle(
            ctx,
            "https://x.com/runlight/.well-known/oauth-protected-resource",
            "GET",
            new Headers(),
            "",
            null);
    assertEquals(
        "{\"resource\":\"https://x.com/runlight/mcp\",\"authorization_servers\":[\"https://x.com/runlight\"],\"scopes_supported\":[\"read\",\"manage\"],\"bearer_methods_supported\":[\"header\"]}",
        resource.text());
    assertEquals("*", resource.headers().get("access-control-allow-origin"));
    Response options =
        handle(ctx, "https://x.com/runlight/oauth/token", "OPTIONS", new Headers(), "", null);
    assertEquals(204, options.status());
    assertNull(handle(ctx, "https://x.com/runlight/api/stats", "GET", new Headers(), "", null));
  }

  @Test
  void anAppRegistersIsAllowedAndSwapsItsCodeForAToken() {
    FakeInstall rl =
        new FakeInstall(
            List.of(
                Json.object("id", "a", "name", "Site A"),
                Json.object("id", "b", "name", "Site B")));
    OAuth.Context ctx = new OAuth.Context(rl, "/runlight", r -> true);
    Headers jsonType = Headers.of("content-type", "application/json");

    // A flood of registrations stores nothing.
    for (int i = 0; i < 50; i++) {
      Response flood =
          handle(
              ctx,
              "https://x.com/runlight/oauth/register",
              "POST",
              jsonType,
              Json.stringify(
                  Json.object(
                      "client_name",
                      "flood " + i,
                      "redirect_uris",
                      List.of("https://a.example/cb"))),
              "");
      assertEquals(201, flood.status());
    }
    assertEquals(0, rl.store.settingsStartingWith("oauth-client:").size());

    Response registered =
        handle(
            ctx,
            "https://x.com/runlight/oauth/register",
            "POST",
            jsonType,
            Json.stringify(
                Json.object(
                    "client_name",
                    "Claude",
                    "redirect_uris",
                    List.of("http://evil.example/cb", "https://claude.ai/cb"))),
            "");
    assertEquals(201, registered.status());
    Map<String, Object> client = Js.map(Json.parse(registered.text()));
    assertEquals(List.of("https://claude.ai/cb"), client.get("redirect_uris"));
    String clientId = (String) client.get("client_id");

    String verifier = b64url(Hash.randomBytes(32));
    Map<String, String> fields = new LinkedHashMap<>();
    fields.put("response_type", "code");
    fields.put("client_id", clientId);
    fields.put("redirect_uri", "https://claude.ai/cb");
    fields.put("code_challenge", OAuth.s256(verifier));
    fields.put("code_challenge_method", "S256");
    fields.put("state", "s1");
    String params = form(fields);
    Response consent =
        handle(
            ctx,
            "https://x.com/runlight/oauth/authorize?" + params,
            "GET",
            new Headers(),
            "",
            null);
    assertEquals(200, consent.status());
    assertTrue(consent.text().contains("Claude</strong> wants to read"), consent.text());
    assertTrue(consent.text().contains("Site B only"));

    // An id whose payload was changed is not this app.
    String[] parts = clientId.split("\\.", -1);
    String forged =
        b64url(
                Js.utf8(
                    Json.stringify(
                        Json.object(
                            "n", "Claude", "r", List.of("https://evil.example/cb"), "t", 1L))))
            + "."
            + parts[1];
    Map<String, String> forgedFields = new LinkedHashMap<>(fields);
    forgedFields.put("client_id", forged);
    forgedFields.put("redirect_uri", "https://evil.example/cb");
    assertEquals(
        400,
        handle(
                ctx,
                "https://x.com/runlight/oauth/authorize?" + form(forgedFields),
                "GET",
                new Headers(),
                "",
                null)
            .status());

    // A consent posted from another site is refused.
    Headers formType = Headers.of("content-type", "application/x-www-form-urlencoded");
    Headers elsewhere = new Headers(formType).set("origin", "https://evil.example");
    assertEquals(
        403,
        handle(
                ctx,
                "https://x.com/runlight/oauth/authorize",
                "POST",
                elsewhere,
                params + "&decision=allow",
                null)
            .status());

    Headers here = new Headers(formType).set("origin", "https://x.com");
    Response allow =
        handle(
            ctx,
            "https://x.com/runlight/oauth/authorize",
            "POST",
            here,
            params + "&decision=allow&site=b",
            null);
    assertEquals(303, allow.status());
    Url location = new Url(allow.headers().get("location"));
    assertEquals("https://claude.ai", location.origin());
    assertEquals("s1", location.searchParams().get("state"));
    String code = location.searchParams().get("code");

    Map<String, String> swap = new LinkedHashMap<>();
    swap.put("grant_type", "authorization_code");
    swap.put("code", code);
    swap.put("client_id", clientId);
    swap.put("redirect_uri", "https://claude.ai/cb");
    swap.put("code_verifier", "wrong");
    Response wrong =
        handle(ctx, "https://x.com/runlight/oauth/token", "POST", formType, form(swap), null);
    assertEquals(400, wrong.status());
    assertTrue(wrong.text().contains("does not match"));
    // The code went with the first try.
    swap.put("code_verifier", verifier);
    Response again =
        handle(ctx, "https://x.com/runlight/oauth/token", "POST", formType, form(swap), null);
    assertTrue(again.text().contains("already used"), again.text());

    Response allowed =
        handle(
            ctx,
            "https://x.com/runlight/oauth/authorize",
            "POST",
            here,
            params + "&decision=allow&site=b",
            null);
    swap.put("code", new Url(allowed.headers().get("location")).searchParams().get("code"));
    // As JSON, which the token endpoint also takes.
    Response issued =
        handle(
            ctx,
            "https://x.com/runlight/oauth/token",
            "POST",
            jsonType,
            Json.stringify(new LinkedHashMap<String, Object>(swap)),
            null);
    assertEquals(200, issued.status(), issued.text());
    Map<String, Object> token = Js.map(Json.parse(issued.text()));
    assertEquals("Bearer", token.get("token_type"));
    assertEquals("read", token.get("scope"));
    assertEquals("b", token.get("site"));
    assertTrue(((String) token.get("access_token")).startsWith("rl_"));
    assertEquals(1, rl.store.settingsStartingWith("oauth-used:").size());
    Map<String, Object> row = rl.store.tokens().get(0);
    assertEquals("Claude (OAuth)", row.get("name"));
    assertEquals(Hash.sha256((String) token.get("access_token")), row.get("hash"));

    // Once it has connected, a request it gets wrong goes back to it.
    Map<String, String> bad = new LinkedHashMap<>(fields);
    bad.put("response_type", "token");
    Response refused =
        handle(
            ctx,
            "https://x.com/runlight/oauth/authorize?" + form(bad),
            "GET",
            new Headers(),
            "",
            null);
    assertEquals(303, refused.status());
    assertTrue(refused.headers().get("location").contains("error=unsupported_response_type"));
  }

  @Test
  void oneAddressRegistersAtMostTenAMinute() {
    FakeInstall rl = new FakeInstall(List.of(Json.object("id", "a", "name", "Site A")));
    OAuth.Context ctx = new OAuth.Context(rl, "/runlight", r -> true);
    Headers jsonType = Headers.of("content-type", "application/json");
    String body =
        Json.stringify(
            Json.object("client_name", "x", "redirect_uris", List.of("https://a.example/cb")));
    for (int i = 0; i < 10; i++) {
      assertEquals(
          201,
          handle(
                  ctx,
                  "https://x.com/runlight/oauth/register",
                  "POST",
                  jsonType,
                  body,
                  "203.0.113.9")
              .status());
    }
    assertEquals(
        429,
        handle(ctx, "https://x.com/runlight/oauth/register", "POST", jsonType, body, "203.0.113.9")
            .status());
    assertEquals(
        201,
        handle(ctx, "https://x.com/runlight/oauth/register", "POST", jsonType, body, "203.0.113.10")
            .status());
    rl.clock.addAndGet(60_000);
    assertEquals(
        201,
        handle(ctx, "https://x.com/runlight/oauth/register", "POST", jsonType, body, "203.0.113.9")
            .status());
  }

  @Test
  void beforeAnAppHasConnectedARequestItGotWrongEndsOnAPage() {
    FakeInstall rl = new FakeInstall(List.of(Json.object("id", "a", "name", "Site A")));
    OAuth.Context ctx = new OAuth.Context(rl, "/runlight", r -> false);
    ctx.signIn = "/login";
    Response registered =
        handle(
            ctx,
            "https://x.com/runlight/oauth/register",
            "POST",
            Headers.of("content-type", "application/json"),
            "{\"client_name\":\"<App>\",\"redirect_uris\":[\"https://app.example/cb\"]}",
            null);
    String clientId = (String) Js.map(Json.parse(registered.text())).get("client_id");
    Map<String, String> fields = new LinkedHashMap<>();
    fields.put("response_type", "token");
    fields.put("client_id", clientId);
    fields.put("redirect_uri", "https://app.example/cb");
    Response page =
        handle(
            ctx,
            "https://x.com/runlight/oauth/authorize?" + form(fields),
            "GET",
            new Headers(),
            "",
            null);
    assertEquals(400, page.status());
    assertTrue(page.text().contains("&lt;App&gt; sent unsupported_response_type."), page.text());

    // Not signed in, it is sent to sign in, and comes back here.
    fields.put("response_type", "code");
    fields.put("code_challenge", OAuth.s256("v".repeat(43)));
    fields.put("code_challenge_method", "S256");
    Response signIn =
        handle(
            ctx,
            "https://x.com/runlight/oauth/authorize?" + form(fields),
            "GET",
            new Headers(),
            "",
            null);
    assertEquals(303, signIn.status());
    assertEquals(
        "/login?next=" + Js.encodeURIComponent("/runlight/oauth/authorize?" + form(fields)),
        signIn.headers().get("location"));
    assertNotEquals(null, signIn.headers().get("cache-control"));
  }
}
