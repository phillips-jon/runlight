package sh.runlight.routes;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.routes.Make.body;
import static sh.runlight.routes.Make.dig;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Env;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.OAuth;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;

/** oauth.test.ts, ported: an app connecting to the MCP server through the routes. */
class OAuthTest {
  private static final Map<String, String> OWNER = Map.of("authorization", "Bearer secret");
  private static final Map<String, String> FORM =
      Map.of("content-type", "application/x-www-form-urlencoded");
  private static final Map<String, String> JSON = Map.of("content-type", "application/json");

  @BeforeEach
  void setUp() {
    Make.clearEnv();
  }

  @AfterEach
  void tearDown() {
    Env.reset();
  }

  private static String b64url(byte[] bytes) {
    return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
  }

  private static String verifier() {
    return b64url(Hash.randomBytes(32));
  }

  private static String challenge(String verifier) {
    return b64url(Hash.sha256Bytes(verifier.getBytes(StandardCharsets.UTF_8)));
  }

  @SafeVarargs
  private static Map<String, String> headers(Map<String, String>... parts) {
    Map<String, String> out = new LinkedHashMap<>();
    for (Map<String, String> part : parts) {
      out.putAll(part);
    }
    return out;
  }

  private static Request at(String url) {
    return at(url, "GET", Map.of(), null);
  }

  private static Request at(String url, String method, Map<String, String> headers, String body) {
    Map<String, String> all = new LinkedHashMap<>(headers);
    if (body != null && !all.containsKey("content-type")) {
      all.put("content-type", "text/plain;charset=UTF-8");
    }
    return new Request(url, method, Headers.of(all), body == null ? "" : body);
  }

  /** Fields in order, as a form body or query. */
  private static String form(String... pairs) {
    SearchParams params = new SearchParams();
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      params.append(pairs[i], pairs[i + 1]);
    }
    return params.toString();
  }

  private static Runlight twoSites() {
    return Make.runlight(
        new Runlight.Options()
            .sites(
                List.of(
                    Json.object("id", "a", "name", "Site A", "hostnames", List.of("a.com")),
                    Json.object("id", "b", "name", "Site B", "hostnames", List.of("b.com")))));
  }

  private static Runlight oneSite(Runlight.Options options) {
    return Make.runlight(
        options.sites(
            List.of(Json.object("id", "a", "name", "Site A", "hostnames", List.of("a.com")))));
  }

  private static String register(Routes routes, String name, String redirect) {
    return (String)
        body(routes.handle(
                at(
                    "https://x.com/runlight/oauth/register",
                    "POST",
                    JSON,
                    Json.stringify(
                        Json.object("client_name", name, "redirect_uris", List.of(redirect))))))
            .get("client_id");
  }

  private static String location(Response response) {
    String location = response.headers().get("location");
    return location == null ? "" : location;
  }

  @Test
  void anAppConnectsToTheMcpServerOverOAuth() {
    Runlight rl = twoSites();
    Routes routes = rl.routes(new Routes.Options().token("secret"));
    String origin = "https://x.com";

    // The MCP endpoint points at the metadata.
    Response refused = routes.handle(at(origin + "/runlight/mcp", "POST", JSON, "{}"));
    assertEquals(401, refused.status());
    Matcher m =
        Pattern.compile("resource_metadata=\"([^\"]+)\"")
            .matcher(refused.headers().get("www-authenticate"));
    assertTrue(m.find());
    assertEquals(origin + "/runlight/.well-known/oauth-protected-resource", m.group(1));
    Map<String, Object> resource = body(routes.handle(at(m.group(1))));
    assertEquals(List.of(origin + "/runlight"), resource.get("authorization_servers"));
    assertEquals(origin + "/runlight/mcp", resource.get("resource"));
    Map<String, Object> server =
        body(routes.handle(at(origin + "/.well-known/oauth-authorization-server/runlight")));
    assertEquals(origin + "/runlight/oauth/token", server.get("token_endpoint"));
    assertEquals(List.of("S256"), server.get("code_challenge_methods_supported"));

    // Registration.
    assertEquals(
        400,
        routes
            .handle(
                at(
                    origin + "/runlight/oauth/register",
                    "POST",
                    JSON,
                    Json.stringify(
                        Json.object("redirect_uris", List.of("http://evil.example/cb")))))
            .status());
    Response registered =
        routes.handle(
            at(
                origin + "/runlight/oauth/register",
                "POST",
                JSON,
                Json.stringify(
                    Json.object(
                        "client_name",
                        "Claude",
                        "redirect_uris",
                        List.of("https://claude.ai/api/mcp/auth_callback")))));
    assertEquals(201, registered.status());
    String clientId = (String) body(registered).get("client_id");

    // Consent: signed out it says so; signed in it asks; allowing sends a code back.
    String verifier = verifier();
    String params =
        form(
            "response_type",
            "code",
            "client_id",
            clientId,
            "redirect_uri",
            "https://claude.ai/api/mcp/auth_callback",
            "code_challenge",
            challenge(verifier),
            "code_challenge_method",
            "S256",
            "state",
            "xyz");
    assertEquals(401, routes.handle(at(origin + "/runlight/oauth/authorize?" + params)).status());
    SearchParams wrongRedirect = new SearchParams(params);
    wrongRedirect.set("redirect_uri", "https://evil.example/cb");
    assertEquals(
        400,
        routes
            .handle(at(origin + "/runlight/oauth/authorize?" + wrongRedirect, "GET", OWNER, null))
            .status(),
        "never sends a code to an address the app did not register");
    Response consent =
        routes.handle(at(origin + "/runlight/oauth/authorize?" + params, "GET", OWNER, null));
    assertEquals(200, consent.status());
    String page = consent.text();
    assertTrue(page.contains("Claude</strong> wants to read your Runlight stats"));
    assertTrue(
        page.contains("sends you back to <strong>claude.ai</strong>"),
        "the page shows where the answer goes");
    Response deny =
        routes.handle(
            at(
                origin + "/runlight/oauth/authorize",
                "POST",
                headers(OWNER, FORM),
                params + "&decision=deny"));
    assertTrue(location(deny).contains("error=access_denied&state=xyz"));
    Response forged =
        routes.handle(
            at(
                origin + "/runlight/oauth/authorize",
                "POST",
                headers(OWNER, Map.of("origin", "https://evil.example"), FORM),
                params + "&decision=allow"));
    assertEquals(403, forged.status());
    Response allow =
        routes.handle(
            at(
                origin + "/runlight/oauth/authorize",
                "POST",
                headers(OWNER, Map.of("origin", origin), FORM),
                params + "&decision=allow&site=b"));
    Url back = new Url(location(allow));
    assertEquals("https://claude.ai/api/mcp/auth_callback", back.origin() + back.pathname);
    assertEquals("xyz", back.searchParams().get("state"));
    String code = back.searchParams().get("code");

    // The token: PKCE checked, the code good once.
    java.util.function.BiFunction<String, String, Response> exchange =
        (c, used) ->
            routes.handle(
                at(
                    origin + "/runlight/oauth/token",
                    "POST",
                    FORM,
                    form(
                        "grant_type",
                        "authorization_code",
                        "code",
                        c,
                        "client_id",
                        clientId,
                        "redirect_uri",
                        "https://claude.ai/api/mcp/auth_callback",
                        "code_verifier",
                        used)));
    assertEquals("invalid_grant", body(exchange.apply(code, "wrong-verifier")).get("error"));
    assertEquals(
        "invalid_grant",
        body(exchange.apply(code, verifier)).get("error"),
        "a code that failed once is spent");

    // Again, properly this time.
    Response second =
        routes.handle(
            at(
                origin + "/runlight/oauth/authorize",
                "POST",
                headers(OWNER, Map.of("origin", origin), FORM),
                params + "&decision=allow&site=b"));
    String code2 = new Url(location(second)).searchParams().get("code");
    Map<String, Object> issued = body(exchange.apply(code2, verifier));
    assertEquals("Bearer", issued.get("token_type"));
    assertEquals("read", issued.get("scope"));
    assertEquals("b", issued.get("site"));

    Response call =
        routes.handle(
            at(
                origin + "/runlight/mcp",
                "POST",
                headers(Map.of("authorization", "Bearer " + issued.get("access_token")), JSON),
                Json.stringify(
                    Json.object(
                        "jsonrpc",
                        "2.0",
                        "id",
                        1L,
                        "method",
                        "tools/call",
                        "params",
                        Json.object("name", "list_sites", "arguments", Json.object())))));
    Object sites = dig(Json.parse((String) dig(body(call), "result.content.0.text")), "sites");
    assertEquals(
        List.of("b"), Make.column(sites, "id"), "the token reads only the site chosen at consent");
    Map<String, Object> tokens =
        body(routes.handle(at(origin + "/runlight/api/tokens", "GET", OWNER, null)));
    List<Object> pairs = new ArrayList<>();
    for (Object t : Js.list(tokens.get("tokens"))) {
      pairs.add(List.of(Js.get(t, "name"), Js.get(t, "site")));
    }
    assertEquals(List.of(List.of("Claude (OAuth)", "b")), pairs);
  }

  @Test
  void registeringStoresNothingSoAFloodOfRegistrationsNeverKeepsARealAppOut() {
    AtomicLong now = new AtomicLong(Make.utc(2026, 10, 7, 12));
    Runlight rl = oneSite(new Runlight.Options().now(now::get));
    Routes routes = rl.routes(new Routes.Options().token("secret"));
    Registrar register =
        (name, ip, redirect) ->
            routes.handle(
                at(
                    "https://x.com/runlight/oauth/register",
                    "POST",
                    JSON,
                    Json.stringify(
                        Json.object("client_name", name, "redirect_uris", List.of(redirect)))),
                Json.object("ip", ip));
    for (int i = 0; i < 500; i++) {
      assertEquals(201, register.call("flood " + i, "", "https://app.example/cb").status());
    }
    assertEquals(0, rl.store.settingsStartingWith("oauth-client:").size());
    assertEquals(0, rl.store.settingsStartingWith("oauth-used:").size());

    // A real app still registers, and its id names it and its address, signed, so nobody can
    // change them.
    Response claude = register.call("Claude", "", "https://claude.ai/cb");
    assertEquals(201, claude.status());
    String clientId = (String) body(claude).get("client_id");
    String verifier = verifier();
    String[] fields = {
      "response_type",
      "code",
      "client_id",
      clientId,
      "redirect_uri",
      "https://claude.ai/cb",
      "code_challenge",
      challenge(verifier),
      "code_challenge_method",
      "S256"
    };
    String params = form(fields);
    assertTrue(
        routes
            .handle(at("https://x.com/runlight/oauth/authorize?" + params, "GET", OWNER, null))
            .text()
            .contains("Claude</strong> wants to read"));
    String[] parts = clientId.split("\\.");
    String forged =
        b64url(
                Json.stringify(
                        Json.object(
                            "n", "Claude", "r", List.of("https://evil.example/cb"), "t", now.get()))
                    .getBytes(StandardCharsets.UTF_8))
            + "."
            + parts[1];
    assertNotEquals(parts[0], forged.split("\\.")[0]);
    SearchParams forgedParams = new SearchParams(params);
    forgedParams.set("client_id", forged);
    forgedParams.set("redirect_uri", "https://evil.example/cb");
    assertEquals(
        400,
        routes
            .handle(
                at("https://x.com/runlight/oauth/authorize?" + forgedParams, "GET", OWNER, null))
            .status());

    // Allowed and swapped for a token, the app gets its first row.
    Response allow =
        routes.handle(
            at(
                "https://x.com/runlight/oauth/authorize",
                "POST",
                headers(OWNER, Map.of("origin", "https://x.com"), FORM),
                params + "&decision=allow"));
    String code = new Url(location(allow)).searchParams().get("code");
    Response issued =
        routes.handle(
            at(
                "https://x.com/runlight/oauth/token",
                "POST",
                FORM,
                form(
                    "grant_type",
                    "authorization_code",
                    "code",
                    code,
                    "client_id",
                    clientId,
                    "redirect_uri",
                    "https://claude.ai/cb",
                    "code_verifier",
                    verifier)));
    assertEquals(200, issued.status());
    assertEquals(1, rl.store.settingsStartingWith("oauth-used:").size());

    // An app stored before ids were signed still works, and one that never connected goes after
    // a day.
    rl.store.setSetting(
        "oauth-client:" + "a".repeat(32),
        Json.stringify(
            Json.object(
                "name",
                "Old",
                "redirects",
                List.of("https://old.example/cb"),
                "createdAt",
                now.get())));
    SearchParams old = new SearchParams(params);
    old.set("client_id", "a".repeat(32));
    old.set("redirect_uri", "https://old.example/cb");
    assertEquals(
        200,
        routes
            .handle(at("https://x.com/runlight/oauth/authorize?" + old, "GET", OWNER, null))
            .status());
    now.addAndGet(86_400_000L);
    var unused = register.call("Another", "", "https://app.example/cb");
    assertEquals(0, rl.store.settingsStartingWith("oauth-client:").size());

    // One address registers at most ten a minute.
    for (int i = 0; i < 10; i++) {
      assertEquals(
          201, register.call("app " + i, "203.0.113.9", "https://app.example/cb").status());
    }
    assertEquals(429, register.call("one more", "203.0.113.9", "https://app.example/cb").status());
    assertEquals(201, register.call("one more", "203.0.113.10", "https://app.example/cb").status());
  }

  private interface Registrar {
    Response call(String name, String ip, String redirect);
  }

  @Test
  void beforeAnOwnerHasAllowedAnAppOnceARequestItGotWrongEndsOnAPage() {
    Runlight rl = oneSite(new Runlight.Options());
    Routes routes = rl.routes(new Routes.Options().signIn("/login").authorize(r -> false));
    String clientId = register(routes, "x", "https://evil.example/landing");
    for (String[] asked :
        new String[][] {
          {"response_type", "token"},
          {
            "response_type",
            "code",
            "code_challenge_method",
            "plain",
            "code_challenge",
            "a".repeat(43)
          }
        }) {
      List<String> fields =
          new ArrayList<>(
              List.of(
                  "client_id",
                  clientId,
                  "redirect_uri",
                  "https://evil.example/landing",
                  "state",
                  "x"));
      fields.addAll(List.of(asked));
      Response answer =
          routes.handle(
              at("https://x.com/runlight/oauth/authorize?" + form(fields.toArray(new String[0]))));
      assertEquals(400, answer.status());
      assertNull(answer.headers().get("location"));
    }
  }

  @Test
  void aSignedInViewerIsToldOnlyAnOwnerCanConnectNeverSentToSignInAgain() {
    Runlight rl = oneSite(new Runlight.Options());
    Routes routes =
        rl.routes(
            new Routes.Options()
                .signIn("/login")
                .authorize(r -> "viewer".equals(r.headers().get("cookie")) ? "read" : false));
    String clientId = register(routes, "Claude", "https://claude.ai/cb");
    String params =
        form(
            "response_type",
            "code",
            "client_id",
            clientId,
            "redirect_uri",
            "https://claude.ai/cb",
            "code_challenge",
            "a".repeat(43),
            "code_challenge_method",
            "S256");
    Response signedOut = routes.handle(at("https://x.com/runlight/oauth/authorize?" + params));
    assertEquals(303, signedOut.status());
    assertTrue(
        location(signedOut)
            .startsWith("/login?next=%2Frunlight%2Foauth%2Fauthorize%3Fresponse_type%3Dcode"));
    Response viewer =
        routes.handle(
            at(
                "https://x.com/runlight/oauth/authorize?" + params,
                "GET",
                Map.of("cookie", "viewer"),
                null));
    assertEquals(403, viewer.status());
    assertTrue(viewer.text().contains("only an owner of this Runlight can connect Claude"));
  }

  @Test
  void aManageGrantNamesOneSiteAndRecordsTheHubsOrigin() {
    Runlight rl = twoSites();
    Routes routes = rl.routes(new Routes.Options().token("secret"));
    String clientId = register(routes, "Hub", "https://hub.example.net/cb");
    String verifier = verifier();
    String params =
        form(
            "response_type",
            "code",
            "client_id",
            clientId,
            "redirect_uri",
            "https://hub.example.net/cb",
            "code_challenge",
            OAuth.s256(verifier),
            "code_challenge_method",
            "S256",
            "scope",
            "read manage",
            "site",
            "b");
    String page =
        routes
            .handle(at("https://x.com/runlight/oauth/authorize?" + params, "GET", OWNER, null))
            .text();
    assertTrue(
        page.contains("<option value=\"b\" selected>Site B</option>"),
        "the site asked for is offered first");
    assertFalse(page.contains("Every site"));
    Map<String, String> formHeaders = headers(OWNER, Map.of("origin", "https://x.com"), FORM);
    Response noSite =
        routes.handle(
            at(
                "https://x.com/runlight/oauth/authorize",
                "POST",
                formHeaders,
                params.replace("site=b", "site=") + "&decision=allow"));
    assertEquals(
        "https://hub.example.net/cb?error=invalid_request&error_description=Pick+the+site+to+manage",
        noSite.headers().get("location"));
    Response allow =
        routes.handle(
            at(
                "https://x.com/runlight/oauth/authorize",
                "POST",
                formHeaders,
                params.replace("site=b", "site=a") + "&decision=allow"));
    String code = new Url(location(allow)).searchParams().get("code");
    Map<String, Object> issued =
        body(
            routes.handle(
                at(
                    "https://x.com/runlight/oauth/token",
                    "POST",
                    JSON,
                    Json.stringify(
                        Json.object(
                            "grant_type",
                            "authorization_code",
                            "code",
                            code,
                            "client_id",
                            clientId,
                            "redirect_uri",
                            "https://hub.example.net/cb",
                            "code_verifier",
                            verifier)))));
    assertEquals(List.of("manage", "a"), List.of(issued.get("scope"), issued.get("site")));
    Object tokens =
        body(routes.handle(at("https://x.com/runlight/api/tokens", "GET", OWNER, null)))
            .get("tokens");
    assertEquals(
        "https://hub.example.net", rl.store.setting("token-origin:" + dig(tokens, "0.id")));
  }
}
