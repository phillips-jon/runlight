package sh.runlight.routes;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.routes.Make.body;
import static sh.runlight.routes.Make.owner;
import static sh.runlight.routes.Make.req;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Env;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.Version;
import sh.runlight.http.Response;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * routes.test.ts, ported, then the unit checks of the routes' own helpers: cookies, bearer tokens,
 * JSON-only writes, and the dashboard's page.
 */
class RoutesTest {
  @BeforeEach
  void setUp() {
    Make.clearEnv();
  }

  @AfterEach
  void tearDown() {
    Env.reset();
  }

  private static Routes routes(Routes.Options options) {
    return Make.runlight().routes(options);
  }

  private static Routes withToken(String token) {
    return routes(new Routes.Options().token(token));
  }

  private static boolean matches(String regex, String text) {
    return Pattern.compile(regex).matcher(text == null ? "" : text).find();
  }

  @Test
  void theTrackerIsPublicCachedAndAnswers304ToItsEtag() {
    Routes routes = withToken("secret");
    Response first = routes.handle(req("/runlight/s.js"));
    assertEquals(200, first.status());
    assertTrue(matches("javascript", first.headers().get("content-type")));
    assertTrue(matches("sendBeacon", first.text()));
    String etag = first.headers().get("etag");
    assertTrue(
        etag.startsWith("\"" + Version.build().get("trackerHash") + "-"),
        "the etag covers the script and its click rules");
    Response again = routes.handle(req("/runlight/s.js", "GET", Map.of("if-none-match", etag)));
    assertEquals(304, again.status());
  }

  @Test
  void statsNeedTheTokenAsABearerOrThroughTheCookie() {
    Routes routes = withToken("secret");
    assertEquals(401, routes.handle(req("/runlight/api/stats")).status());
    assertEquals(
        401,
        routes
            .handle(req("/runlight/api/stats", "GET", Map.of("authorization", "Bearer wrong")))
            .status());
    assertEquals(
        200,
        routes
            .handle(req("/runlight/api/stats", "GET", Map.of("authorization", "Bearer secret")))
            .status());

    Response signIn = routes.handle(req("/runlight/?token=secret"));
    assertEquals(303, signIn.status());
    assertEquals("/runlight/", signIn.headers().get("location"));
    String cookie = signIn.headers().get("set-cookie");
    assertTrue(cookie.contains("HttpOnly"));
    assertTrue(cookie.contains("Secure"));
    assertFalse(cookie.contains("secret"), "the cookie holds a digest, not the token");
    String value = cookie.split(";")[0];
    assertEquals(
        200, routes.handle(req("/runlight/api/stats", "GET", Map.of("cookie", value))).status());
    assertEquals(200, routes.handle(req("/runlight/", "GET", Map.of("cookie", value))).status());
  }

  @Test
  void withNoTokenEverythingButDevelopmentRefusesWritesIncluded() {
    for (String value : List.of("production", "", "staging")) {
      Env.override("NODE_ENV", value.isEmpty() ? null : value);
      Routes routes = routes(new Routes.Options());
      assertEquals(
          503,
          routes.handle(req("/runlight/api/stats")).status(),
          "NODE_ENV=" + (value.isEmpty() ? "(unset)" : value));
      Response minted =
          routes.handle(
              req(
                  "/runlight/api/tokens",
                  "POST",
                  Map.of("content-type", "application/json"),
                  Json.stringify(Json.object("name", "x"))));
      assertEquals(503, minted.status(), "nobody can make a token on an install with no token");
    }
    Env.override("NODE_ENV", "development");
    assertEquals(200, routes(new Routes.Options()).handle(req("/runlight/api/stats")).status());
  }

  @Test
  void authorizeReplacesTheToken() {
    Routes routes =
        routes(new Routes.Options().authorize(r -> "yes".equals(r.headers().get("x-admin"))));
    assertEquals(401, routes.handle(req("/runlight/api/sites")).status());
    assertEquals(
        200, routes.handle(req("/runlight/api/sites", "GET", Map.of("x-admin", "yes"))).status());
  }

  @Test
  void theElementPickerSendsItsChoiceOnlyToTheDashboardItsTicketNames() {
    AtomicLong now = new AtomicLong(Make.utc(2026, 10, 7, 12));
    Runlight rl =
        Make.runlight(
            new Runlight.Options()
                .sites(List.of(Make.site("blog", "blog.example.com")))
                .now(now::get));
    Routes routes = rl.routes(new Routes.Options().token("secret"));
    java.util.function.BiFunction<Object, String, Response> ask =
        (body, auth) -> routes.handle(owner("/runlight/api/pick?site=blog", "POST", body, auth));
    Function<String, String> target =
        ticket -> {
          String script =
              routes
                  .handle(
                      req(
                          "/runlight/pick.js?runlight=pick&runlight_ticket="
                              + Js.encodeURIComponent(ticket)))
                  .text();
          Matcher m = Pattern.compile("var \\w+=\"([^\"]*)\";if\\(").matcher(script);
          return m.find() ? m.group(1) : null;
        };

    assertEquals(
        401,
        ask.apply(Json.object("origin", "https://stats.example.com"), "wrong").status(),
        "only the owner gets a ticket");
    assertEquals(400, ask.apply(Json.object("origin", "javascript:alert(1)"), "secret").status());
    String ticket =
        (String)
            body(ask.apply(Json.object("origin", "https://stats.example.com"), "secret"))
                .get("ticket");
    assertEquals("https://stats.example.com", target.apply(ticket));
    // A page that opens the site some other way has no ticket, or only a changed one, and the
    // picker sends nowhere.
    assertEquals("", target.apply(""));
    String evil = HexFormat.of().formatHex("https://evil.example".getBytes(StandardCharsets.UTF_8));
    assertEquals("", target.apply(ticket.replaceFirst("\\.[a-f0-9]+\\.", "." + evil + ".")));
    assertEquals(
        "no-store", routes.handle(req("/runlight/pick.js")).headers().get("cache-control"));
    now.addAndGet(31 * 60_000L);
    assertEquals("", target.apply(ticket), "a ticket runs out after half an hour");

    // The script also learns the site the ticket is for, and does nothing on any other site's
    // pages.
    String fresh =
        (String)
            body(ask.apply(Json.object("origin", "https://stats.example.com"), "secret"))
                .get("ticket");
    String script =
        routes
            .handle(req("/runlight/pick.js?runlight_ticket=" + Js.encodeURIComponent(fresh)))
            .text();
    assertTrue(script.contains(Json.stringify(Json.stringify(List.of("blog.example.com")))));
    assertFalse(script.contains("__RUNLIGHT_PICK_HOSTS__"));

    // A hub's manage token gets one only for the hub it connected from, recorded when it did.
    Map<String, Object> made =
        body(
            routes.handle(
                owner(
                    "/runlight/api/tokens",
                    "POST",
                    Json.object("name", "Hub", "scope", "manage", "site", "blog"))));
    String manage = (String) made.get("secret");
    Response refused = ask.apply(Json.object("origin", "https://hub.example.net"), manage);
    assertEquals(403, refused.status());
    assertEquals("pick_hub", body(refused).get("code"));
    rl.store.setSetting("token-origin:" + Make.dig(made, "token.id"), "https://hub.example.net");
    assertEquals(
        403,
        ask.apply(Json.object("origin", "https://evil.example"), manage).status(),
        "never another origin");
    String hub =
        (String)
            body(ask.apply(Json.object("origin", "https://hub.example.net"), manage)).get("ticket");
    assertEquals("https://hub.example.net", target.apply(hub));
  }

  @Test
  void theCheckEndpointTakesTheCronSecret() {
    Routes routes = routes(new Routes.Options().token("secret").cronSecret("cron"));
    assertEquals(
        401,
        routes
            .handle(req("/runlight/api/check", "POST", Map.of("content-type", "application/json")))
            .status());
    assertEquals(
        200,
        routes
            .handle(req("/runlight/api/check", "POST", Map.of("authorization", "Bearer cron")))
            .status());
    assertEquals(
        200,
        routes
            .handle(req("/runlight/api/check", "POST", Map.of("authorization", "Bearer secret")))
            .status());
    routes = routes(new Routes.Options().token("secret").cronSecret("cron"));
    assertEquals(
        200,
        routes
            .handle(req("/runlight/api/check", "GET", Map.of("authorization", "Bearer cron")))
            .status(),
        "Vercel Cron sends GET");
    assertEquals(401, routes.handle(req("/runlight/api/check")).status());
  }

  @Test
  void basePathMovesEverything() {
    Routes routes = routes(new Routes.Options().token("secret").basePath("/admin/runlight/"));
    assertEquals(200, routes.handle(req("/admin/runlight/s.js")).status());
    assertEquals(404, routes.handle(req("/runlight/s.js")).status());
    Map<String, Object> info = body(routes.handle(req("/admin/runlight/api")));
    assertEquals("runlight", info.get("name"));
    assertEquals("sh.runlight:runlight", info.get("library"));
    assertEquals("java", info.get("language"));
  }

  @Test
  void badQueriesAre400sWithAReason() {
    Routes routes = withToken(null);
    for (String path :
        List.of(
            "/runlight/api/stats?period=forever",
            "/runlight/api/stats?filter=nope",
            "/runlight/api/stats?filter=page:like:x",
            "/runlight/api/breakdown?dimension=shoe_size")) {
      Response response = routes.handle(req(path));
      assertEquals(400, response.status(), path);
      assertFalse(((String) body(response).get("error")).isEmpty());
    }
  }

  @Test
  void theDashboardPageLoadsItsHashedAssetsUnderAStrictCsp() {
    Object hash = Version.build().get("dashboardHash");
    Object locales = Version.build().get("localesHash");
    Routes routes = routes(new Routes.Options().token("secret").basePath("/admin/runlight"));
    Response page = routes.handle(req("/admin/runlight/"));
    assertEquals(200, page.status(), "the shell holds no data, so it loads signed out");
    assertTrue(matches("script-src 'self'", page.headers().get("content-security-policy")));
    String html = page.text();
    assertTrue(html.contains("/admin/runlight/assets/app." + hash + ".js"));
    assertTrue(html.contains("data-base=\"/admin/runlight\""));
    Response js = routes.handle(req("/admin/runlight/assets/app." + hash + ".js"));
    assertEquals(200, js.status());
    assertTrue(matches("immutable", js.headers().get("cache-control")));
    assertEquals(200, routes.handle(req("/admin/runlight/assets/app." + hash + ".css")).status());
    assertEquals(404, routes.handle(req("/admin/runlight/assets/app.old.js")).status());
    assertTrue(
        html.contains("/admin/runlight/assets/locale.fr." + locales + ".json"),
        "the page lists its languages");
    Response french = routes.handle(req("/admin/runlight/assets/locale.fr." + locales + ".json"));
    assertEquals(200, french.status());
    assertEquals("Filtrer", body(french).get("filter.button"));
    assertEquals(
        404, routes.handle(req("/admin/runlight/assets/locale.xx." + locales + ".json")).status());
    assertEquals(
        401,
        routes.handle(req("/admin/runlight/api/stats")).status(),
        "the data stays behind the token");
  }

  @Test
  void aSitesNameAndTimezoneCanBeChangedAndSurviveARestart() {
    SqlStore store = Stores.sqlite(":memory:");
    Runlight first =
        Make.runlight(
            new Runlight.Options()
                .store(store)
                .site(Json.object("name", "From code", "timezone", "UTC")));
    Routes routes = first.routes(new Routes.Options().token(null));
    java.util.function.BiFunction<Object, String, Response> patch =
        (body, type) ->
            routes.handle(
                req(
                    "/runlight/api/sites/default",
                    "PATCH",
                    Map.of("content-type", type),
                    Json.stringify(body)));
    assertEquals(
        200,
        patch
            .apply(
                Json.object("name", "Jon's site", "timezone", "America/Toronto"),
                "application/json")
            .status());
    assertEquals(
        400, patch.apply(Json.object("timezone", "Mars/Olympus"), "application/json").status());
    assertEquals(400, patch.apply(Json.object("name", ""), "application/json").status());
    assertEquals(415, patch.apply(Json.object("name", "x"), "text/plain").status());
    assertEquals(
        404,
        routes
            .handle(
                req(
                    "/runlight/api/sites/nope",
                    "PATCH",
                    Map.of("content-type", "application/json"),
                    "{}"))
            .status());
    Map<String, Object> listed = body(routes.handle(req("/runlight/api/sites")));
    assertEquals("Jon's site", Make.dig(listed, "sites.0.name"));
    assertNull(Make.dig(listed, "sites.0.lastSeen"));

    // Code still says "From code"; the dashboard's change wins after a restart.
    Runlight again =
        Make.runlight(
            new Runlight.Options()
                .store(store)
                .site(Json.object("name", "From code", "timezone", "UTC")));
    again.init();
    assertEquals("Jon's site", again.site("default").get("name"));
    assertEquals("America/Toronto", again.site("default").get("timezone"));
  }

  @Test
  void aShareReadsOneSitesReportsAndNothingElseUntilItIsDeleted() {
    Runlight rl =
        Make.runlight(
            new Runlight.Options()
                .sites(
                    List.of(
                        Json.object(
                            "id",
                            "a",
                            "name",
                            "Site A",
                            "hostnames",
                            List.of("a.com"),
                            "timezone",
                            "UTC"),
                        Json.object(
                            "id",
                            "b",
                            "name",
                            "Site B",
                            "hostnames",
                            List.of("b.com"),
                            "timezone",
                            "UTC"))));
    Routes routes = rl.routes(new Routes.Options().token("secret"));

    assertEquals(
        401,
        routes
            .handle(
                req(
                    "/runlight/api/shares?site=a",
                    "POST",
                    Map.of("content-type", "application/json"),
                    "{}"))
            .status());
    Response made =
        routes.handle(owner("/runlight/api/shares?site=a", "POST", Json.object("name", "Client")));
    assertEquals(201, made.status());
    Map<String, Object> share = Js.map(body(made).get("share"));
    String id = (String) share.get("id");
    assertTrue(id.matches("[a-f0-9]{32}"));
    assertEquals("/runlight/share/" + id, share.get("path"));

    Response page = routes.handle(req((String) share.get("path")));
    assertEquals(200, page.status());
    assertTrue(page.text().contains("data-share=\"" + id + "\""));
    assertEquals("no-referrer", page.headers().get("referrer-policy"));

    Map<String, String> as = Map.of("x-runlight-share", id);
    assertEquals(200, routes.handle(req("/runlight/api/stats?site=b", "GET", as)).status());
    assertEquals(
        "a",
        body(routes.handle(req("/runlight/api/stats?site=b", "GET", as))).get("site"),
        "a share is pinned to its own site whatever is asked");
    Map<String, Object> sites = body(routes.handle(req("/runlight/api/sites", "GET", as)));
    List<Object> pairs = new ArrayList<>();
    for (Object s : Js.list(sites.get("sites"))) {
      pairs.add(List.of(Js.get(s, "id"), Js.get(s, "hostnames")));
    }
    assertEquals(List.of(List.of("a", List.of())), pairs);
    assertEquals(
        401,
        routes.handle(req("/runlight/api/links?site=a", "GET", as)).status(),
        "links need the token");
    assertEquals(
        401,
        routes.handle(req("/runlight/api/shares?site=a", "GET", as)).status(),
        "a share cannot list shares");
    assertEquals(
        404,
        routes
            .handle(req("/runlight/api/stats", "GET", Map.of("x-runlight-share", "0".repeat(32))))
            .status());

    Response renamed =
        routes.handle(
            owner("/runlight/api/shares/" + id + "?site=a", "PATCH", Json.object("name", "Board")));
    assertEquals("Board", Make.dig(body(renamed), "share.name"));
    assertEquals(
        404,
        routes.handle(owner("/runlight/api/shares/" + id + "?site=b", "DELETE", null)).status(),
        "only from its own site");
    assertEquals(
        200,
        routes.handle(owner("/runlight/api/shares/" + id + "?site=a", "DELETE", null)).status());
    assertEquals(404, routes.handle(req("/runlight/api/stats", "GET", as)).status());
    assertEquals(404, routes.handle(req((String) share.get("path"))).status());
  }

  @Test
  void theDashboardInsideACmsOpensOneFramedPageOnceWhoseSessionReadsOneSite() {
    Runlight rl =
        Make.runlight(
            new Runlight.Options()
                .sites(
                    List.of(
                        Json.object(
                            "id",
                            "a",
                            "name",
                            "Site A",
                            "hostnames",
                            List.of("a.com"),
                            "timezone",
                            "UTC"),
                        Json.object(
                            "id",
                            "b",
                            "name",
                            "Site B",
                            "hostnames",
                            List.of("b.com"),
                            "timezone",
                            "UTC"))));
    Routes routes = rl.routes(new Routes.Options().token("secret"));
    assertEquals(
        400,
        routes
            .handle(
                owner("/runlight/api/tokens", "POST", Json.object("name", "CMS", "scope", "embed")))
            .status(),
        "an embed key is for one site");
    Map<String, Object> made =
        body(
            routes.handle(
                owner(
                    "/runlight/api/tokens",
                    "POST",
                    Json.object("name", "CMS", "site", "a", "scope", "embed"))));
    String secret = (String) made.get("secret");
    String tokenId = (String) Make.dig(made, "token.id");
    assertEquals("embed", Make.dig(made, "token.scope"));
    Function<String, Response> mint =
        origin ->
            routes.handle(
                owner("/runlight/api/embed", "POST", Json.object("origin", origin), secret));
    assertEquals(400, mint.apply("https://b.com").status(), "only an origin on the site's domains");
    assertEquals(400, mint.apply("https://a.com/path").status(), "an origin, not a page");
    String readKey =
        (String)
            body(routes.handle(
                    owner(
                        "/runlight/api/tokens",
                        "POST",
                        Json.object("name", "Reader", "site", "a"))))
                .get("secret");
    assertEquals(
        403,
        routes
            .handle(
                owner(
                    "/runlight/api/embed", "POST", Json.object("origin", "https://a.com"), readKey))
            .status(),
        "only an embed key gets tickets");
    assertEquals(
        401,
        routes
            .handle(owner("/runlight/api/embed", "POST", Json.object("origin", "https://a.com")))
            .status(),
        "the owner's own token is no key for tickets");
    assertEquals(
        403,
        routes.handle(owner("/runlight/api/stats?site=a", "GET", null, secret)).status(),
        "an embed key reads nothing itself");
    Response minted = mint.apply("https://www.a.com");
    assertEquals(201, minted.status());
    Map<String, Object> ticketBody = body(minted);
    String ticket = (String) ticketBody.get("ticket");
    String path = (String) ticketBody.get("path");
    assertEquals("a", ticketBody.get("site"));
    assertEquals("/runlight/embed?ticket=" + ticket, path);
    assertFalse(ticket.contains(tokenId), "a ticket never names its token");

    Response page = routes.handle(req(path));
    assertEquals(200, page.status());
    assertTrue(
        page.headers()
            .get("content-security-policy")
            .endsWith("frame-ancestors https://www.a.com"));
    assertNull(page.headers().get("x-frame-options"));
    assertEquals("no-referrer", page.headers().get("referrer-policy"));
    assertEquals("no-store", page.headers().get("cache-control"));
    Matcher found = Pattern.compile("data-embed=\"([^\"]+)\"").matcher(page.text());
    assertTrue(found.find());
    String session = found.group(1);
    assertTrue(session.matches("\\d+\\.[a-f0-9]{24}\\.[a-f0-9]{64}"));
    assertTrue(page.text().contains("data-embed-origin=\"https://www.a.com\""));
    Response again = routes.handle(req(path));
    assertEquals(410, again.status(), "a ticket works once");
    assertTrue(
        again
            .headers()
            .get("content-security-policy")
            .endsWith("frame-ancestors https://www.a.com"),
        "a used ticket still says so inside its frame");
    assertTrue(again.text().contains("data-embed=\"\""));
    assertEquals(
        404,
        routes.handle(req(path.substring(0, path.length() - 1) + "0")).status(),
        "a ticket this install did not sign opens nothing");

    Map<String, String> as = Map.of("x-runlight-embed", session);
    assertEquals(
        "a",
        body(routes.handle(req("/runlight/api/stats?site=b", "GET", as))).get("site"),
        "pinned to its token's site whatever is asked");
    Map<String, String> withOwner = new LinkedHashMap<>(as);
    withOwner.put("authorization", "Bearer secret");
    assertEquals(
        403,
        routes.handle(req("/runlight/api/links?site=a", "GET", withOwner)).status(),
        "nothing a share cannot read, even beside the owner's token");
    assertEquals(
        401,
        routes
            .handle(req("/runlight/api/stats", "GET", Map.of("x-runlight-embed", session + "0")))
            .status());
    assertEquals(
        "DENY",
        routes.handle(req("/runlight/")).headers().get("x-frame-options"),
        "every other page still refuses to be framed");

    assertEquals(
        200, routes.handle(owner("/runlight/api/tokens/" + tokenId, "DELETE", null)).status());
    assertEquals(
        401,
        routes.handle(req("/runlight/api/stats", "GET", as)).status(),
        "deleting the token ends its sessions at once");
  }

  @Test
  void anEmbedTicketRunsOutAfterFiveMinutesAndItsSessionAfterAnHour() {
    AtomicLong now = new AtomicLong(Make.utc(2026, 10, 9, 12));
    Runlight rl =
        Make.runlight(
            new Runlight.Options().site(Json.object("hostnames", List.of("a.com"))).now(now::get));
    Routes routes = rl.routes(new Routes.Options().token("secret"));
    Map<String, Object> made =
        body(
            routes.handle(
                owner(
                    "/runlight/api/tokens",
                    "POST",
                    Json.object("name", "CMS", "site", "default", "scope", "embed"))));
    String secret = (String) made.get("secret");
    Function<String, String> mint =
        origin ->
            (String)
                body(routes.handle(
                        owner(
                            "/runlight/api/embed", "POST", Json.object("origin", origin), secret)))
                    .get("path");
    String late = mint.apply("https://a.com");
    now.addAndGet(Routes.EMBED_TICKET_MS + 1);
    assertEquals(410, routes.handle(req(late)).status(), "a ticket lasts five minutes");
    Response page = routes.handle(req(mint.apply("https://a.com")));
    assertEquals(200, page.status());
    Matcher found = Pattern.compile("data-embed=\"([^\"]+)\"").matcher(page.text());
    assertTrue(found.find());
    Map<String, String> as = Map.of("x-runlight-embed", found.group(1));
    assertEquals(200, routes.handle(req("/runlight/api/stats", "GET", as)).status());
    now.addAndGet(Routes.EMBED_SESSION_MS + 1);
    assertEquals(
        401,
        routes.handle(req("/runlight/api/stats", "GET", as)).status(),
        "a session lasts an hour");
  }

  @Test
  void aSettingCanBeTakenOnce() {
    Runlight rl =
        Make.runlight(new Runlight.Options().site(Json.object("hostnames", List.of("a.com"))));
    rl.init();
    rl.store.setSetting("x", "1");
    assertEquals("1", rl.store.takeSetting("x"));
    assertNull(rl.store.takeSetting("x"));
    assertNull(rl.store.setting("x"));
  }

  @Test
  void aCmsPluginReportsAiAgentFetchesWithItsOwnKeyWhichReadsNothing() {
    Runlight rl =
        Make.runlight(
            new Runlight.Options().site(Json.object("hostnames", List.of("blog.example.com"))));
    Routes routes = rl.routes(new Routes.Options().token("secret").observeKey("agents"));
    java.util.function.BiFunction<String, Object, Response> send =
        (key, body) -> routes.handle(owner("/runlight/api/observe", "POST", body, key));
    String gpt =
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot";
    assertEquals(
        401,
        send.apply("wrong", Json.object("url", "https://blog.example.com/post", "userAgent", gpt))
            .status());
    assertEquals(
        400, send.apply("agents", Json.object("url", "not a url", "userAgent", gpt)).status());
    assertEquals(
        204,
        send.apply("agents", Json.object("url", "https://blog.example.com/post", "userAgent", gpt))
            .status());
    assertEquals(
        204,
        send.apply(
                "agents",
                Json.object("url", "https://blog.example.com/style.css", "userAgent", gpt))
            .status(),
        "assets are ignored, quietly");
    assertEquals(
        204,
        send.apply("agents", Json.object("url", "https://elsewhere.example/post", "userAgent", gpt))
            .status(),
        "other sites are ignored, quietly");
    assertEquals(
        401,
        routes.handle(owner("/runlight/api/stats", "GET", null, "agents")).status(),
        "the observe key reads nothing");
    Map<String, Object> rows =
        body(routes.handle(owner("/runlight/api/breakdown?period=today&dimension=ai_page")));
    assertEquals(List.of("/post"), Make.column(rows.get("rows"), "value"));
  }

  @Test
  void anObserveKeyIsCheckedBeforeTheBodyIsRead() {
    Runlight rl =
        Make.runlight(new Runlight.Options().sites(List.of(Make.site("blog", "blog.example.com"))));
    Routes routes = rl.routes(new Routes.Options().token("secret").observeKey("agents"));
    rl.init();
    rl.store.setSetting("observe-key:blog", "rlo_blog");
    java.util.function.Function<String, Response> garbled =
        key ->
            routes.handle(
                req(
                    "/runlight/api/observe",
                    "POST",
                    Map.of("authorization", "Bearer " + key, "content-type", "application/json"),
                    "{not json"));
    rl.store.setSetting("observe-key:gone", "rlo_gone");
    assertEquals(401, garbled.apply("wrong").status(), "a wrong key hears nothing about the body");
    assertEquals(401, garbled.apply("rlo_wrong").status());
    assertEquals(401, garbled.apply("rlo_gone").status(), "a key for a site no longer here");
    assertEquals(400, garbled.apply("agents").status());
    assertEquals(400, garbled.apply("rlo_blog").status());
  }

  @Test
  void aGoneShareLinkSaysSoInTheVisitorsLanguageAndAReadTokensWriteIsRefusedWithACode() {
    Runlight rl =
        Make.runlight(new Runlight.Options().sites(List.of(Make.site("blog", "blog.example.com"))));
    Routes routes = rl.routes(new Routes.Options().token("secret"));
    Response gone =
        routes.handle(
            req(
                "/runlight/share/" + "a".repeat(32),
                "GET",
                Map.of("accept-language", "fr-CA,fr;q=0.9,en;q=0.8")));
    assertEquals(404, gone.status());
    assertTrue(gone.headers().get("content-type").startsWith("text/html"));
    String page = gone.text();
    assertTrue(page.contains("<html lang=\"fr\">"));
    assertTrue(page.contains("Ce lien de partage ne fonctionne plus"));
    assertTrue(
        routes
            .handle(req("/runlight/share/" + "a".repeat(32)))
            .text()
            .contains("This share link no longer works"));

    String read =
        (String)
            body(routes.handle(
                    owner("/runlight/api/tokens", "POST", Json.object("name", "Script"))))
                .get("secret");
    Response write =
        routes.handle(
            owner(
                "/runlight/api/goals?site=blog",
                "POST",
                Json.object("name", "X", "kind", "event", "match", "X"),
                read));
    assertEquals(403, write.status());
    assertEquals("token_read_only", body(write).get("code"));
  }

  @Test
  void goalFunnelSiteAndAssistantRefusalsCarryTheirOwnCodesAndParams() {
    Runlight rl = Make.runlight(new Runlight.Options().managedSites(true));
    Routes routes = rl.routes(new Routes.Options().token("secret"));
    java.util.function.BiFunction<String[], Object, String> send =
        (methodPath, body) -> {
          Map<String, Object> json =
              body(routes.handle(owner("/runlight" + methodPath[1], methodPath[0], body)));
          Map<String, Object> out = new LinkedHashMap<>();
          out.put("code", json.get("code"));
          out.put("params", json.get("params"));
          return Json.stringify(out);
        };
    assertEquals(
        "{\"code\":\"site_domain_invalid\",\"params\":{\"host\":\"nope\"}}",
        send.apply(
            new String[] {"POST", "/api/sites"}, Json.object("name", "Blog", "hostnames", "nope")));
    var unused =
        send.apply(
            new String[] {"POST", "/api/sites"},
            Json.object("name", "Blog", "hostnames", "blog.example.com"));
    assertEquals(
        "{\"code\":\"site_domain_taken\",\"params\":{\"host\":\"blog.example.com\",\"site\":\"Blog\"}}",
        send.apply(
            new String[] {"POST", "/api/sites"},
            Json.object("name", "Again", "hostnames", "blog.example.com")));
    unused =
        send.apply(
            new String[] {"POST", "/api/goals?site=blog.example.com"},
            Json.object("name", "Signup", "kind", "event", "match", "Signup"));
    assertEquals(
        "{\"code\":\"goal_exists\",\"params\":{\"name\":\"signup\"}}",
        send.apply(
            new String[] {"POST", "/api/goals?site=blog.example.com"},
            Json.object("name", "signup", "kind", "event", "match", "x")));
    assertEquals(
        "{\"code\":\"funnel_short\",\"params\":{}}",
        send.apply(
            new String[] {"POST", "/api/funnels?site=blog.example.com"},
            Json.object(
                "name", "F", "steps", Json.array(Json.object("kind", "page", "match", "/")))));
    assertEquals(
        "{\"code\":\"assistant_provider\",\"params\":{}}",
        send.apply(new String[] {"PUT", "/api/assistant"}, Json.object("provider", "nope")));
  }

  // The routes' own helpers.

  @Test
  void cookiesAreReadByNameWithEqualsSignsKeptInTheirValues() {
    var request = req("/", "GET", Map.of("cookie", "a=1; runlight_token=x=y=z ;  other=2"));
    assertEquals("x=y=z", Routes.readCookie(request, "runlight_token"));
    assertEquals("2", Routes.readCookie(request, "other"));
    assertEquals("", Routes.readCookie(request, "missing"));
    assertEquals("", Routes.readCookie(req("/"), "a"));
    assertEquals(Hash.sha256("runlight-cookie:secret"), Routes.cookieValue("secret"));
  }

  @Test
  void bearerTokensAreReadWhateverTheSchemesCase() {
    assertEquals("abc", Routes.bearer(req("/", "GET", Map.of("authorization", "Bearer abc"))));
    assertEquals("abc", Routes.bearer(req("/", "GET", Map.of("authorization", "bEaReR   abc  "))));
    assertEquals("", Routes.bearer(req("/", "GET", Map.of("authorization", "Basic abc"))));
    assertEquals("", Routes.bearer(req("/")));
  }

  @Test
  void onlyAJsonMediaTypeCountsAsJson() {
    Map<String, Boolean> cases = new LinkedHashMap<>();
    cases.put("application/json", true);
    cases.put("Application/JSON; charset=utf-8", true);
    cases.put(" application/json ", true);
    cases.put("text/plain; application/json", false);
    cases.put("application/json-patch+json", false);
    cases.put("text/plain;charset=UTF-8", false);
    for (Map.Entry<String, Boolean> c : cases.entrySet()) {
      assertEquals(
          c.getValue(),
          Routes.isJson(req("/", "POST", Map.of("content-type", c.getKey()), "{}")),
          c.getKey());
    }
    assertFalse(Routes.isJson(req("/", "POST", Map.of())));
  }

  @Test
  void writesMustBeJsonUnlessABearerTokenIsSent() {
    Routes routes =
        Make.runlight(new Runlight.Options().sites(List.of(Make.site("blog", "blog.example.com"))))
            .routes(new Routes.Options().token(null));
    // A form from another page cannot send JSON, so a cookie or an open install never lets it
    // write.
    for (String[] c :
        new String[][] {
          {"POST", "/runlight/api/goals?site=blog"},
          {"PUT", "/runlight/api/mail"},
          {"PATCH", "/runlight/api/sites/blog"}
        }) {
      Response answer =
          routes.handle(
              req(
                  c[1],
                  c[0],
                  Map.of("content-type", "application/x-www-form-urlencoded"),
                  "name=x"));
      assertEquals(415, answer.status(), c[0] + " " + c[1]);
      assertEquals("{\"error\":\"Send JSON\",\"code\":\"send_json\"}", answer.text());
    }
    assertEquals(
        415,
        routes.handle(req("/runlight/api/check", "POST", Map.of())).status(),
        "even a write with no body");
    assertEquals(
        200,
        routes
            .handle(req("/runlight/api/check", "POST", Map.of("authorization", "Bearer x")))
            .status(),
        "a bearer token is never sent by a browser on its own");
    assertEquals(
        404,
        routes.handle(req("/runlight/api/goals/nope?site=blog", "DELETE", Map.of())).status(),
        "a DELETE carries no body to check");
  }

  @Test
  void errorsAreJsonWithTheirCodeAndNeverSniffed() {
    Response answer = Routes.coded("Unknown site", "unknown_site", 404);
    assertEquals("{\"error\":\"Unknown site\",\"code\":\"unknown_site\"}", answer.text());
    assertEquals("nosniff", answer.headers().get("x-content-type-options"));
    assertEquals(
        "{\"error\":\"x\",\"code\":\"y\",\"params\":{}}",
        Routes.coded("x", "y", 400, Map.of()).text(),
        "empty params are an object");
    assertEquals(
        "private, max-age=3600",
        Routes.coded(
                "No icon", "icon_none", 404, null, Map.of("cache-control", "private, max-age=3600"))
            .headers()
            .get("cache-control"));
  }

  @Test
  void anErrorInsideARouteIsAnInternalErrorThatSaysNothingMore() {
    Routes routes =
        Make.runlight(new Runlight.Options().sites(List.of(Make.site("blog", "blog.example.com"))))
            .routes(new Routes.Options().token(null));
    // A broken escape in a path makes decodeURIComponent throw, as it does in TypeScript.
    Response answer =
        routes.handle(req("/runlight/api/goals/%E0%A4%A?site=blog", "DELETE", Map.of()));
    assertEquals(500, answer.status());
    assertEquals("{\"error\":\"Internal error\",\"code\":\"internal\"}", answer.text());
  }

  @Test
  void theDashboardShellEscapesWhatItIsGiven() {
    String html = Routes.dashboard("/a\"b", "share<", "/out?x=1&y=2", true, true, "/in");
    assertTrue(html.contains("data-base=\"/a&#34;b\""));
    assertTrue(html.contains("data-share=\"share&#60;\""));
    assertTrue(html.contains("data-sign-out=\"/out?x=1&#38;y=2\""));
    assertTrue(html.contains("data-sign-in=\"/in\" data-geo-credit=\"\" data-accounts=\"\""), html);
    assertFalse(Routes.dashboard("/runlight", "", "", false, false, "").contains("data-share"));
  }
}
