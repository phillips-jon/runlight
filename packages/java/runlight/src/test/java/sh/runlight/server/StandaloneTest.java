package sh.runlight.server;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.store.Stores;

/**
 * The standalone server's own behaviour, as packages/server/test/server.test.ts checks the Node
 * one's.
 */
class StandaloneTest {
  private static final String ORIGIN = "https://stats.example.com";
  private static final String CODE = "one-time-code";
  private static final String SECRET = "s".repeat(64);
  private static final long NOW = 1_791_374_400_000L; // 2026-10-07 12:00 UTC

  private static Standalone make(Consumer<Standalone.Options> more) {
    Standalone.Options options =
        new Standalone.Options()
            .store(Stores.sqlite(":memory:"))
            .secret(SECRET)
            .now(() -> NOW)
            .setupCode(CODE);
    more.accept(options);
    return new Standalone(options);
  }

  private static Standalone make() {
    return make(options -> {});
  }

  private static Request req(String path) {
    return req(path, "GET", Map.of(), "", null);
  }

  private static Request req(String path, String method, Map<String, String> headers) {
    return req(path, method, headers, "", null);
  }

  private static Request req(
      String path, String method, Map<String, String> headers, String body, String host) {
    return new Request(
        (host != null ? "https://" + host : ORIGIN) + path, method, Headers.of(headers), body);
  }

  private static Request form(String path, Map<String, String> fields) {
    return req(
        path,
        "POST",
        Map.of("content-type", "application/x-www-form-urlencoded"),
        new SearchParams(new LinkedHashMap<>(fields)).toString(),
        null);
  }

  private static Map<String, String> fields(String... pairs) {
    Map<String, String> out = new LinkedHashMap<>();
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      out.put(pairs[i], pairs[i + 1]);
    }
    return out;
  }

  private static String cookieOf(Response response) {
    String cookie = response.headers().get("set-cookie");
    return (cookie == null ? "" : cookie).split(";", -1)[0];
  }

  private static String json(Object body) {
    return Json.stringify(body);
  }

  @Test
  void aNewServerIsLockedUntilTheSetupCodeMakesTheFirstAccount() {
    Standalone server = make(options -> options.setupWhere("in setup.txt"));
    assertEquals(403, server.handle(req("/")).status(), "the dashboard waits for setup");
    assertTrue(server.handle(req("/")).text().contains("Open the setup link in setup.txt"));
    assertEquals(403, server.handle(req("/setup?code=wrong")).status());
    assertEquals(
        403,
        server
            .handle(
                form(
                    "/setup",
                    fields("code", "wrong", "email", "a@b.co", "password", "long enough pw")))
            .status());
    assertEquals(200, server.handle(req("/setup?code=" + CODE)).status());
    Response mismatch =
        server.handle(
            form(
                "/setup",
                fields(
                    "code",
                    CODE,
                    "email",
                    "a@b.co",
                    "password",
                    "a long password",
                    "again",
                    "a long pasword")));
    assertEquals(400, mismatch.status(), "the password is asked twice");
    Response made =
        server.handle(
            form(
                "/setup",
                fields(
                    "code",
                    CODE,
                    "email",
                    "Jon@Example.com",
                    "password",
                    "a long password",
                    "again",
                    "a long password")));
    assertEquals(303, made.status());
    assertEquals("/", made.headers().get("location"));
    assertEquals(
        200,
        server.handle(req("/", "GET", Map.of("cookie", cookieOf(made)))).status(),
        "signed straight in");
    assertEquals(
        "/login",
        server.handle(req("/setup?code=" + CODE)).headers().get("location"),
        "setup closes once an account exists");
  }

  @Test
  void withNoCodeTheFirstAccountIsMadeWithTheToken() {
    Standalone server = make(options -> options.setupCode(null).token("script-token"));
    assertEquals("/setup", server.handle(req("/")).headers().get("location"));
    assertEquals(
        403,
        server
            .handle(
                form(
                    "/setup",
                    fields(
                        "code",
                        "wrong",
                        "email",
                        "a@b.co",
                        "password",
                        "a long password",
                        "again",
                        "a long password")))
            .status());
    Response made =
        server.handle(
            form(
                "/setup",
                fields(
                    "code",
                    "script-token",
                    "email",
                    "a@b.co",
                    "password",
                    "a long password",
                    "again",
                    "a long password")));
    assertEquals(303, made.status());
  }

  @Test
  void signInSignOutAndSessionsThatEndWithAPasswordChange() {
    Standalone server = make();
    server.accounts.setPassword("jon@example.com", "a long password", NOW);
    Response away = server.handle(req("/?period=7d"));
    assertEquals(303, away.status());
    assertEquals(
        "/login?next=" + Js.encodeURIComponent("/?period=7d"), away.headers().get("location"));
    assertEquals(401, server.handle(req("/api/sites")).status());
    assertEquals(
        401,
        server
            .handle(
                form("/login", fields("email", "jon@example.com", "password", "nope nope nope")))
            .status());

    Response ok =
        server.handle(
            form(
                "/login",
                fields(
                    "email",
                    "JON@example.com",
                    "password",
                    "a long password",
                    "next",
                    "//evil.example")));
    assertEquals(303, ok.status());
    assertEquals("/", ok.headers().get("location"), "a next address off this server is ignored");
    String cookie = cookieOf(ok);
    assertEquals(200, server.handle(req("/api/sites", "GET", Map.of("cookie", cookie))).status());
    assertTrue(
        server
            .handle(req("/", "GET", Map.of("cookie", cookie)))
            .text()
            .contains("data-sign-out=\"/logout\""));
    String out = server.handle(req("/logout")).headers().get("set-cookie");
    assertTrue(out != null && out.contains("Max-Age=0"), out);

    server.accounts.setPassword("jon@example.com", "another long password", NOW);
    assertEquals(
        401,
        server.handle(req("/api/sites", "GET", Map.of("cookie", cookie))).status(),
        "a new password signs out every browser");
  }

  @Test
  void sitesAreAddedCountedAndShortLinksAnswerOnTheirOwnDomains() {
    Standalone server = make(options -> options.token("script-token"));
    server.accounts.setPassword("jon@example.com", "a long password", NOW);
    Map<String, String> auth =
        Map.of("authorization", "Bearer script-token", "content-type", "application/json");

    assertEquals(
        201,
        server
            .handle(
                req(
                    "/api/sites",
                    "POST",
                    auth,
                    json(Json.object("name", "Blog", "hostnames", "blog.example.com")),
                    null))
            .status());
    assertEquals(200, server.handle(req("/s.js")).status());
    Response hit =
        server.handle(
            req(
                "/e",
                "POST",
                Map.of(
                    "user-agent",
                    "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36",
                    "x-forwarded-for",
                    "203.0.113.9"),
                json(
                    Json.object(
                        "k",
                        "pageview",
                        "u",
                        "https://blog.example.com/post",
                        "s",
                        "blog.example.com")),
                null));
    assertEquals(202, hit.status());
    Map<String, Object> stats =
        Js.map(
            Json.parse(
                server
                    .handle(req("/api/stats?site=blog.example.com&period=today", "GET", auth))
                    .text()));
    assertEquals(1L, Js.map(stats.get("stats")).get("pageviews"));

    assertEquals(
        201,
        server
            .handle(
                req(
                    "/api/link-domains?site=blog.example.com",
                    "POST",
                    auth,
                    json(Json.object("domain", "go.example.com")),
                    null))
            .status());
    Map<String, Object> made =
        Js.map(
            Json.parse(
                server
                    .handle(
                        req(
                            "/api/links?site=blog.example.com",
                            "POST",
                            auth,
                            json(
                                Json.object(
                                    "url",
                                    "https://blog.example.com/launch",
                                    "slug",
                                    "launch",
                                    "domain",
                                    "go.example.com")),
                            null))
                    .text()));
    assertEquals("launch", Js.map(made.get("link")).get("slug"));
    Response shortLink = server.handle(req("/launch", "GET", Map.of(), "", "go.example.com"));
    assertEquals(302, shortLink.status());
    assertEquals("https://blog.example.com/launch", shortLink.headers().get("location"));
    assertEquals(
        302,
        server.handle(req("/go/launch")).status(),
        "every link also answers at /go/:slug on the server itself");

    Response health = server.handle(req("/healthz"));
    assertEquals(List.of(200, "ok"), List.of(health.status(), health.text()));
    assertEquals(
        401,
        server.handle(req("/api/sites", "GET", Map.of("authorization", "Bearer wrong"))).status());
  }

  @Test
  void aLinkDomainNeverTakesOverTheDashboardsOwnNameSignInOrApi() {
    Standalone server = make(options -> options.token("script-token"));
    server.accounts.setPassword("jon@example.com", "a long password", NOW);
    Map<String, String> auth =
        Map.of("authorization", "Bearer script-token", "content-type", "application/json");
    server.handle(
        req(
            "/api/sites",
            "POST",
            auth,
            json(Json.object("name", "Blog", "hostnames", "blog.example.com")),
            null));
    Function<String[], Response> addDomain =
        given ->
            server.handle(
                req(
                    "/api/link-domains?site=blog.example.com",
                    "POST",
                    auth,
                    json(Json.object("domain", given[0])),
                    given[1]));

    // Someone signs in at stats.example.com, so a caller naming another Host cannot add it
    // afterwards.
    String cookie =
        cookieOf(
            server.handle(
                form("/login", fields("email", "jon@example.com", "password", "a long password"))));
    assertEquals(200, server.handle(req("/api/sites", "GET", Map.of("cookie", cookie))).status());
    for (String host : List.of("decoy.example.org", "203.0.113.5", "stats.example.com.")) {
      assertEquals(400, addDomain.apply(new String[] {"stats.example.com", host}).status(), host);
    }

    // Added anyway: its short links answer, and the server's own pages stay the server's.
    server.runlight.store.addLinkDomain("stats.example.com", "blog.example.com", NOW);
    server.runlight.forgetLinkDomains();
    server.handle(
        req(
            "/api/links?site=blog.example.com",
            "POST",
            auth,
            json(
                Json.object(
                    "url",
                    "https://blog.example.com/a",
                    "slug",
                    "login",
                    "domain",
                    "stats.example.com")),
            null));
    server.handle(
        req(
            "/api/links?site=blog.example.com",
            "POST",
            auth,
            json(
                Json.object(
                    "url",
                    "https://blog.example.com/b",
                    "slug",
                    "sale",
                    "domain",
                    "stats.example.com")),
            null));
    assertEquals(302, server.handle(req("/sale")).status());
    assertEquals(200, server.handle(req("/login")).status(), "sign-in is still the sign-in page");
    assertEquals(
        200,
        server.handle(req("/", "GET", Map.of("cookie", cookie))).status(),
        "the dashboard opens for someone signed in");
    assertEquals(404, server.handle(req("/")).status());
    assertEquals(
        200,
        server
            .handle(
                req(
                    "/api/link-domains/stats.example.com?site=blog.example.com",
                    "DELETE",
                    Map.of("cookie", cookie)))
            .status(),
        "so it can be removed");
    assertEquals(404, server.handle(req("/sale")).status());

    // With the public address set, short links never answer there, and nobody can add it under
    // any Host.
    Standalone named = make(options -> options.token("script-token").url(ORIGIN));
    named.handle(
        req(
            "/api/sites",
            "POST",
            auth,
            json(Json.object("name", "Blog", "hostnames", "blog.example.com")),
            null));
    assertEquals(
        400,
        named
            .handle(
                req(
                    "/api/link-domains?site=blog.example.com",
                    "POST",
                    auth,
                    json(Json.object("domain", "stats.example.com")),
                    "decoy.example.org"))
            .status());
    named.runlight.store.addLinkDomain("stats.example.com", "blog.example.com", NOW);
    named.runlight.forgetLinkDomains();
    named.handle(
        req(
            "/api/links?site=blog.example.com",
            "POST",
            auth,
            json(
                Json.object(
                    "url",
                    "https://blog.example.com/b",
                    "slug",
                    "sale",
                    "domain",
                    "stats.example.com")),
            null));
    assertEquals(404, named.handle(req("/sale")).status());
    assertEquals(403, named.handle(req("/")).status(), "the dashboard, waiting for setup");
  }

  @Test
  void onlyTheOwnerAndAdminsTeachTheServerItsNames() {
    Standalone server = make();
    Map<String, Object> owner =
        server.accounts.setPassword("jon@example.com", "a long password", NOW);
    Map<String, Object> viewer =
        server.accounts.setPassword("viewer@example.com", "another long one", NOW, "viewer");
    Function<Map<String, Object>, String> as =
        user -> "runlight_session=" + Js.encodeURIComponent(server.accounts.sessionFor(user, NOW));
    java.util.function.Supplier<Object> names =
        () -> {
          String saved = server.runlight.store.setting("server-hosts");
          return Json.parse(saved == null ? "[]" : saved);
        };
    for (int i = 0; i < 25; i++) {
      server.handle(
          req(
              "/api/sites",
              "GET",
              Map.of("cookie", as.apply(viewer), "x-forwarded-host", "junk" + i + ".example.org")));
    }
    assertEquals(List.of(), names.get(), "a viewer's made-up forwarded names fill nothing");
    server.handle(
        req(
            "/api/sites",
            "GET",
            Map.of("cookie", as.apply(owner), "x-forwarded-host", "203.0.113.7:8080")));
    server.handle(req("/api/sites", "GET", Map.of("cookie", as.apply(owner))));
    assertEquals(
        List.of("stats.example.com"),
        names.get(),
        "an owner's are learned, if they are domain names");

    // Another server on the same database reads them back from it.
    Standalone again =
        new Standalone(
            new Standalone.Options().store(server.runlight.store).secret(SECRET).now(() -> NOW));
    Map<String, String> json =
        Map.of("cookie", as.apply(owner), "content-type", "application/json");
    again.handle(
        req(
            "/api/sites",
            "POST",
            json,
            json(Json.object("name", "Blog", "hostnames", "blog.example.com")),
            null));
    assertEquals(
        400,
        again
            .handle(
                req(
                    "/api/link-domains?site=blog.example.com",
                    "POST",
                    json,
                    json(Json.object("domain", "stats.example.com")),
                    "decoy.example.org"))
            .status());
  }

  @Test
  void checkRunsTheScheduledWork() {
    assertEquals(
        "{\"ok\":true,\"reports\":{\"sent\":0,\"failed\":0}}", Json.stringify(make().check()));
  }
}
