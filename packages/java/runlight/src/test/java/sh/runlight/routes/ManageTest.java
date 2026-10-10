package sh.runlight.routes;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.routes.Make.body;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Env;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * manage.test.ts, ported: what a hub's manage token may change, link domains kept off the
 * dashboard's own names, and a hub that never shows an install's answer as a page.
 */
class ManageTest {
  @BeforeEach
  void setUp() {
    Make.clearEnv();
  }

  @AfterEach
  void tearDown() {
    Env.reset();
  }

  /** A status and a JSON body, or null when it is not JSON. */
  private record Answer(int status, Object body) {
    Object get(String path) {
      return Make.dig(body, path);
    }
  }

  /** An app with two sites and an owner token, as a hub would connect to. */
  private static final class App {
    final Runlight rl;
    final Routes routes;

    App() {
      rl =
          Make.runlight(
              new Runlight.Options()
                  .sites(
                      List.of(
                          Make.site("blog", "blog.example.com"),
                          Make.site("shop", "shop.example.com"))));
      routes = rl.routes(new Routes.Options().token("owner").origin("https://app.example.com"));
    }

    Answer call(String method, String path, String auth) {
      return call(method, path, auth, null);
    }

    Answer call(String method, String path, String auth, Object body) {
      Headers headers = Headers.of("authorization", "Bearer " + auth);
      if (body != null) {
        headers.set("content-type", "application/json");
      }
      Response answer =
          routes.handle(
              new Request(
                  "https://app.example.com/runlight" + path,
                  method,
                  headers,
                  body == null ? "" : Json.stringify(body)));
      return new Answer(answer.status(), Json.tryParse(answer.text()).value());
    }

    String make(String scope, String site) {
      return (String)
          call(
                  "POST",
                  "/api/tokens",
                  "owner",
                  Json.object("name", "Hub", "scope", scope, "site", site))
              .get("secret");
    }
  }

  private static Map<String, Object> goal(String name, String match) {
    return Json.object("name", name, "kind", "event", "match", match);
  }

  @Test
  void aManageTokenChangesItsOwnSitesSettingsAndNothingElse() {
    App app = new App();
    assertEquals(
        400,
        app.call("POST", "/api/tokens", "owner", Json.object("name", "Hub", "scope", "manage"))
            .status(),
        "a manage token is for one site");
    String manage = app.make("manage", "blog");

    Fixtures.assertJson(
        Json.object("scope", "manage", "site", "blog"),
        app.call("GET", "/api/token", manage).body());
    assertEquals(
        201, app.call("POST", "/api/goals?site=blog", manage, goal("Signup", "Signup")).status());
    assertEquals(
        201,
        app.call("POST", "/api/goals", manage, goal("No site given", "x")).status(),
        "its site is assumed");
    assertEquals(2, Js.list(app.call("GET", "/api/goals?site=blog", "owner").get("goals")).size());
    assertEquals(
        404,
        app.call("POST", "/api/goals?site=shop", manage, goal("Elsewhere", "x")).status(),
        "never another site");
    assertEquals(0, Js.list(app.call("GET", "/api/goals?site=shop", "owner").get("goals")).size());
    assertEquals(
        404,
        app.call("PATCH", "/api/sites/shop", manage, Json.object("name", "Mine now")).status());
    assertEquals(
        403,
        app.call("PATCH", "/api/sites/blog", manage, Json.object("hostnames", "evil.example"))
            .status());

    // Everything beyond one site's settings stays the owner's.
    assertEquals(401, app.call("GET", "/api/tokens", manage).status());
    assertEquals(
        403,
        app.call("POST", "/api/tokens", manage, Json.object("name", "More", "site", "blog"))
            .status());
    assertEquals(
        403, app.call("PUT", "/api/mail", manage, Json.object("service", "webhook")).status());
    assertEquals(
        200,
        app.call("GET", "/api/mail?site=blog", manage).status(),
        "it can see which mail service sends reports");
    assertEquals(
        201,
        app.call("POST", "/api/shares?site=blog", manage, Json.object("name", "For the team"))
            .status(),
        "share links for its site are its to make");
    assertEquals(
        404, app.call("POST", "/api/shares?site=shop", manage, Json.object("name", "x")).status());
    assertEquals(403, app.call("DELETE", "/api/sites/blog", manage).status());
    assertEquals(
        403,
        app.call("POST", "/api/links/import?site=blog", manage, Json.object("rows", List.of()))
            .status());

    assertEquals(
        201,
        app.call(
                "POST",
                "/api/links?site=blog",
                manage,
                Json.object("url", "https://example.org/", "slug", "hello"))
            .status());
    assertEquals(1, Js.list(app.call("GET", "/api/links?site=blog", manage).get("links")).size());
    assertEquals(
        201,
        app.call("POST", "/api/reports?site=blog", manage, Json.object("email", "me@example.com"))
            .status());
    assertEquals(
        200,
        app.call(
                "PATCH",
                "/api/sites/blog",
                manage,
                Json.object("name", "The blog", "retentionMonths", 12L))
            .status());
  }

  @Test
  void aReadTokenStillOnlyReads() {
    App app = new App();
    String read = app.make("read", "blog");
    Fixtures.assertJson(
        Json.object("scope", "read", "site", "blog"), app.call("GET", "/api/token", read).body());
    assertEquals(
        403, app.call("POST", "/api/goals?site=blog", read, goal("Signup", "Signup")).status());
    assertEquals(200, app.call("GET", "/api/stats?site=blog&period=today", read).status());
  }

  @Test
  void aLinkDomainCanNeverBeWhereTheDashboardOrACountedSiteLives() {
    App app = new App();
    assertEquals(
        400,
        app.call(
                "POST",
                "/api/link-domains?site=blog",
                "owner",
                Json.object("domain", "app.example.com"))
            .status(),
        "the dashboard's own host");
    assertEquals(
        400,
        app.call(
                "POST",
                "/api/link-domains?site=blog",
                "owner",
                Json.object("domain", "shop.example.com"))
            .status(),
        "a site's domain");
    assertEquals(
        201,
        app.call(
                "POST",
                "/api/link-domains?site=blog",
                "owner",
                Json.object("domain", "go.example.com"))
            .status());
  }

  /** A mail webhook that keeps what it is sent, standing in for manage.test.ts's server. */
  private static final class MailCatcher implements Fetcher {
    final List<Map<String, Object>> mail = new ArrayList<>();

    @Override
    public synchronized Response fetch(String url, FetchInit init) {
      String body = init.bodyText();
      mail.add(Js.map(Json.parse(body == null ? "{}" : body)));
      return new Response("ok", 200);
    }
  }

  @Test
  void linkDomainsStayOffTheConfiguredAddressAndTheNamesPeopleSignedInFrom() {
    MailCatcher sent = new MailCatcher();
    Runlight rl =
        Make.runlight(
            new Runlight.Options()
                .sites(List.of(Make.site("blog", "blog.example.com")))
                .fetcher(sent)
                .secret("k"));
    Routes routes =
        rl.routes(
            new Routes.Options()
                .token("owner")
                .origin("https://stats.example.com")
                .ownHosts(() -> List.of("dash.example.net:443")));
    Caller call =
        (method, path, auth, body) ->
            routes.handle(
                new Request(
                    "https://decoy.example.org/runlight" + path,
                    method,
                    Headers.of(
                        "authorization", "Bearer " + auth, "content-type", "application/json"),
                    body == null ? "" : Json.stringify(body)));
    java.util.function.ToIntFunction<String> add =
        domain ->
            call.call("POST", "/api/link-domains?site=blog", "owner", Json.object("domain", domain))
                .status();
    for (String taken :
        List.of(
            "stats.example.com",
            "stats.example.com.",
            "www.stats.example.com",
            "dash.example.net",
            "decoy.example.org")) {
      assertEquals(400, add.applyAsInt(taken), taken);
    }
    // Names inside private networks, which the check would make the install fetch.
    for (String inside :
        List.of(
            "metadata.google.internal",
            "db.corp",
            "printer.local",
            "nas.home.arpa",
            "router.lan",
            "10.0.0.5.nip.io",
            "app.localhost")) {
      assertEquals(400, add.applyAsInt(inside), inside);
    }
    assertEquals(201, add.applyAsInt("go.example.org"));
    // One saved before that rule is never fetched.
    rl.store.addLinkDomain("db.internal", "blog", 0);
    Map<String, Object> check =
        new LinkedHashMap<>(
            body(call.call("GET", "/api/link-domains/db.internal/check?site=blog", "owner", null)));
    assertTrue(check.containsKey("target"), "and where a domain should point");
    check.remove("target");
    Fixtures.assertJson(
        Json.object(
            "domain",
            "db.internal",
            "working",
            false,
            "reason",
            "is not a public domain name",
            "code",
            "check_not_public"),
        check);

    // A hub's reports link to the configured address, never to the Host it names, and its
    // samples share one wait.
    rl.saveMailSettings(
        Json.object(
            "service",
            "webhook",
            "url",
            "https://hooks.example.net/mail",
            "from",
            "reports@example.com"));
    String manage =
        (String)
            body(call.call(
                    "POST",
                    "/api/tokens",
                    "owner",
                    Json.object("name", "Hub", "scope", "manage", "site", "blog")))
                .get("secret");
    Object first =
        body(call.call(
                "POST", "/api/reports?site=blog", manage, Json.object("email", "a@example.com")))
            .get("report");
    Object second =
        body(call.call(
                "POST", "/api/reports?site=blog", manage, Json.object("email", "b@example.com")))
            .get("report");
    List<Object> origins = new ArrayList<>();
    for (Map<String, Object> r : rl.store.reports("blog")) {
      origins.add(r.get("origin"));
    }
    assertEquals(
        List.of("https://stats.example.com/runlight", "https://stats.example.com/runlight"),
        origins);
    assertEquals(
        200,
        call.call("POST", "/api/reports/" + Js.get(first, "id") + "/send?site=blog", manage, null)
            .status(),
        "the first sample goes out");
    assertEquals(1, sent.mail.size());
    assertEquals("a@example.com", sent.mail.get(0).get("to"));
    assertTrue(
        ((String) sent.mail.get(0).get("text")).contains("https://stats.example.com/runlight"),
        "its links point at the configured address");
    Response waits =
        call.call("POST", "/api/reports/" + Js.get(second, "id") + "/send?site=blog", manage, null);
    assertEquals(429, waits.status(), "another report waits too");
    assertEquals("sample_soon_hub", body(waits).get("code"));
    var unused =
        call.call("DELETE", "/api/reports/" + Js.get(second, "id") + "?site=blog", manage, null);
    Object again =
        body(call.call(
                "POST", "/api/reports?site=blog", manage, Json.object("email", "b@example.com")))
            .get("report");
    assertEquals(
        429,
        call.call("POST", "/api/reports/" + Js.get(again, "id") + "/send?site=blog", manage, null)
            .status(),
        "and so does one added again");
    assertEquals(1, sent.mail.size());
  }

  private interface Caller {
    Response call(String method, String path, String auth, Object body);
  }

  @Test
  void withoutItsOwnAddressAnAppGivesAHubNoLinkDomainsOrReports() {
    // As the quickstart sets it up: one site, no origin, and the app answers on more names than
    // the site's.
    Runlight rl =
        Make.runlight(
            new Runlight.Options()
                .site(Json.object("name", "example.com", "hostnames", List.of("example.com"))));
    Routes routes = rl.routes(new Routes.Options().token("owner"));
    HostCaller call =
        (host, method, path, auth, body) -> {
          Headers headers = Headers.of("host", host, "authorization", "Bearer " + auth);
          if (body != null) {
            headers.set("content-type", "application/json");
          }
          Response answer =
              routes.handle(
                  new Request(
                      "https://" + host + "/runlight" + path,
                      method,
                      headers,
                      body == null ? "" : Json.stringify(body)));
          return new Answer(answer.status(), Json.tryParse(answer.text()).value());
        };
    String manage =
        (String)
            call.call(
                    "app.example.com",
                    "POST",
                    "/api/tokens",
                    "owner",
                    Json.object("name", "Hub", "site", "default", "scope", "manage"))
                .get("secret");
    // From the deployment's other name, where the app's own name is not the request's Host.
    Answer add =
        call.call(
            "example-app.vercel.app",
            "POST",
            "/api/link-domains",
            manage,
            Json.object("domain", "app.example.com"));
    assertEquals(400, add.status());
    assertEquals("origin_needed", add.get("code"));
    assertEquals(
        "origin_needed",
        call.call(
                "example-app.vercel.app",
                "POST",
                "/api/reports",
                manage,
                Json.object("email", "cfo@example.com"))
            .get("code"));
    assertEquals(
        201,
        call.call(
                "app.example.com",
                "POST",
                "/api/link-domains",
                "owner",
                Json.object("domain", "go.example.com"))
            .status(),
        "the owner still adds them");

    // On a link domain the dashboard's paths pass to the app, so the owner can always reach it
    // there.
    for (String path : List.of("/runlight", "/runlight/api/sites")) {
      assertNull(
          rl.linkDomainResponse(
              new Request(
                  "https://go.example.com" + path,
                  "GET",
                  Headers.of("host", "go.example.com"),
                  "")),
          path);
    }
    assertEquals(
        404,
        rl.linkDomainResponse(
                new Request(
                    "https://go.example.com/nothing",
                    "GET",
                    Headers.of("host", "go.example.com"),
                    ""))
            .status());
    // Middleware that never made the routes leaves the default path alone too.
    Runlight apart =
        Make.runlight(
            new Runlight.Options()
                .store(rl.store)
                .site(Json.object("name", "example.com", "hostnames", List.of("example.com"))));
    assertNull(
        apart.linkDomainResponse(
            new Request(
                "https://go.example.com/runlight",
                "GET",
                Headers.of("host", "go.example.com"),
                "")));
  }

  private interface HostCaller {
    Answer call(String host, String method, String path, String auth, Object body);
  }

  @Test
  void theHubNeverPassesOnAnInstallsAnswerAsAPageNorFollowsItsRedirects() {
    Fetcher evil =
        (url, init) -> {
          String path = new Url(url).pathname;
          if (path.startsWith("/runlight/api/sites")) {
            return new Response(
                Json.stringify(
                    Json.object(
                        "sites",
                        Json.array(
                            Json.object(
                                "id",
                                "x",
                                "name",
                                "X",
                                "timezone",
                                "UTC",
                                "hostnames",
                                List.of("x.example.com"))))),
                200,
                Headers.of("content-type", "application/json"));
          }
          if (path.startsWith("/runlight/api/stats")) {
            return new Response(
                "<script>alert(1)</script>", 200, Headers.of("content-type", "text/html"));
          }
          if (path.startsWith("/runlight/api/series")) {
            return new Response("", 302, Headers.of("location", "http://169.254.169.254/"));
          }
          if (path.startsWith("/runlight/api/rhythm")) {
            return new Response(
                Json.stringify(
                    Json.object(
                        "error",
                        "Your session ended. Sign in again at https://evil.example/login "
                            + "x".repeat(1000),
                        "code",
                        "link_taken",
                        "params",
                        Json.object("slug", "a", "n", 5L))),
                400,
                Headers.of("content-type", "application/json"));
          }
          return new Response("{}", 404);
        };
    Runlight hub =
        Make.runlight(
            new Runlight.Options()
                .managedSites(true)
                .secret("k".repeat(32))
                .localInstalls(true)
                .fetcher(evil));
    Routes routes = hub.routes(new Routes.Options().token("owner"));
    java.util.function.BiFunction<String, String[], Response> call =
        (path, rest) ->
            routes.handle(
                new Request(
                    "https://hub.example.com/runlight" + path,
                    rest.length > 0 ? rest[0] : "GET",
                    Headers.of("authorization", "Bearer owner", "content-type", "application/json"),
                    rest.length > 1 ? rest[1] : ""));
    Response added =
        call.apply(
            "/api/sites",
            new String[] {
              "POST",
              Json.stringify(
                  Json.object(
                      "remote", Json.object("url", "http://127.0.0.1:9/runlight", "token", "rl_x")))
            });
    String id = (String) Make.dig(body(added), "site.id");
    Response page = call.apply("/api/stats?site=" + id + "&period=today", new String[0]);
    assertTrue(page.headers().get("content-type").startsWith("application/json"));
    assertEquals("nosniff", page.headers().get("x-content-type-options"));
    assertTrue(page.headers().get("content-security-policy").contains("default-src 'none'"));
    assertEquals(
        502,
        call.apply("/api/series?site=" + id + "&period=today", new String[0]).status(),
        "a redirect is reported, not followed");
    // An install's error says where it came from, short, with only its code and string params.
    Map<String, Object> said =
        body(call.apply("/api/rhythm?site=" + id + "&period=today", new String[0]));
    String error = (String) said.get("error");
    assertTrue(error.startsWith("127.0.0.1:9: Your session ended"), error);
    assertTrue(Js.utf8(error).length < 340);
    assertEquals("link_taken", said.get("code"));
    Fixtures.assertJson(Json.object("slug", "a"), said.get("params"));
  }
}
