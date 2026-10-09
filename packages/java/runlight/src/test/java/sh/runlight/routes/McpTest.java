package sh.runlight.routes;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.routes.Make.body;
import static sh.runlight.routes.Make.column;
import static sh.runlight.routes.Make.dig;
import static sh.runlight.routes.Make.owner;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Env;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Mcp;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.store.Databases;

/** mcp.test.ts, ported: API tokens and the MCP server through the routes, on every store. */
class McpTest {
  private static final String CHROME_MAC =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

  private long now;

  static List<String> kinds() {
    return Databases.kinds();
  }

  @BeforeEach
  void setUp() {
    Make.clearEnv();
    now = Make.utc(2026, 10, 6, 12);
  }

  @AfterEach
  void tearDown() {
    Env.reset();
    Databases.cleanup();
  }

  private Routes make(String kind) {
    Runlight rl =
        Make.runlight(
            new Runlight.Options()
                .store(Databases.fresh(kind))
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
                            "UTC")))
                .now(() -> now));
    return rl.routes(new Routes.Options().token("secret"));
  }

  /** A tracker hit through the routes. */
  private static void send(Routes routes, Map<String, Object> body, String ip) {
    Response answer =
        routes.handle(
            new Request(
                "https://example.com/runlight/e",
                "POST",
                Headers.of(
                    "user-agent",
                    CHROME_MAC,
                    "x-forwarded-for",
                    ip,
                    "content-type",
                    "text/plain;charset=UTF-8"),
                Json.stringify(body)));
    if (answer.status() != 202) {
      throw new IllegalStateException("collect answered " + answer.status());
    }
  }

  private record Made(int status, Map<String, Object> body) {}

  private static Made token(Routes routes, Object body) {
    Response answer = routes.handle(owner("/runlight/api/tokens", "POST", body));
    return new Made(answer.status(), body(answer));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void apiTokensReadCannotWriteCanBeLimitedToASiteAndStopAtRevocation(String kind) {
    Routes routes = make(kind);
    assertEquals(400, token(routes, Json.object("name", "")).status());
    assertEquals(404, token(routes, Json.object("name", "X", "site", "nope")).status());
    Made all = token(routes, Json.object("name", "Claude"));
    assertEquals(201, all.status());
    String secret = (String) all.body().get("secret");
    assertTrue(secret.matches("rl_[a-f0-9]{40}"));
    assertEquals(secret.substring(secret.length() - 4), dig(all.body(), "token.hint"));
    String one =
        (String) token(routes, Json.object("name", "Client B", "site", "b")).body().get("secret");

    Response listedAnswer = routes.handle(owner("/runlight/api/tokens"));
    Map<String, Object> listed = body(listedAnswer);
    List<Object> names = new ArrayList<>(column(listed.get("tokens"), "name"));
    names.sort(null);
    assertEquals(List.of("Claude", "Client B"), names);
    assertFalse(listedAnswer.text().contains(secret), "a token is shown once, never listed");
    assertFalse(Js.map(Js.list(listed.get("tokens")).get(0)).containsKey("hash"), "nor its hash");

    send(routes, Json.object("k", "pageview", "u", "https://a.com/", "i", "p1"), "203.0.113.1");
    send(routes, Json.object("k", "pageview", "u", "https://b.com/", "i", "p2"), "203.0.113.2");

    Response stats =
        routes.handle(owner("/runlight/api/stats?site=a&period=today", "GET", null, secret));
    assertEquals(200, stats.status());
    assertEquals(1L, dig(body(stats), "stats.visitors"));
    assertEquals(
        200,
        routes.handle(owner("/runlight/api/links?site=a", "GET", null, secret)).status(),
        "links can be read");

    // Nothing that writes, and nothing that manages access.
    assertEquals(
        403,
        routes
            .handle(
                owner(
                    "/runlight/api/goals?site=a",
                    "POST",
                    Json.object("name", "G", "kind", "page", "match", "/"),
                    secret))
            .status());
    assertEquals(
        403,
        routes
            .handle(
                owner(
                    "/runlight/api/links?site=a",
                    "POST",
                    Json.object("url", "https://x.com"),
                    secret))
            .status());
    assertEquals(
        401,
        routes.handle(owner("/runlight/api/tokens", "GET", null, secret)).status(),
        "a token cannot list tokens");
    assertEquals(
        401, routes.handle(owner("/runlight/api/shares?site=a", "GET", null, secret)).status());
    assertEquals(401, routes.handle(owner("/runlight/api/mail", "GET", null, secret)).status());

    // A site's token sees only that site.
    assertEquals(
        List.of("b"),
        column(
            body(routes.handle(owner("/runlight/api/sites", "GET", null, one))).get("sites"),
            "id"));
    assertEquals(
        "b",
        body(routes.handle(owner("/runlight/api/stats?period=today", "GET", null, one)))
            .get("site"),
        "and defaults to it");
    assertEquals(
        404, routes.handle(owner("/runlight/api/stats?site=a", "GET", null, one)).status());
    assertEquals(
        404, routes.handle(owner("/runlight/api/links?site=a", "GET", null, one)).status());

    for (Object t : Js.list(body(routes.handle(owner("/runlight/api/tokens"))).get("tokens"))) {
      if ("Claude".equals(Js.get(t, "name"))) {
        assertEquals(now, Js.asLong(Js.get(t, "lastUsedAt")));
      }
    }

    String id = (String) dig(all.body(), "token.id");
    assertEquals(
        403,
        routes.handle(owner("/runlight/api/tokens/" + id, "DELETE", null, secret)).status(),
        "a token cannot revoke");
    assertEquals(200, routes.handle(owner("/runlight/api/tokens/" + id, "DELETE", null)).status());
    assertEquals(404, routes.handle(owner("/runlight/api/tokens/" + id, "DELETE", null)).status());
    assertEquals(
        401,
        routes.handle(owner("/runlight/api/stats?site=a", "GET", null, secret)).status(),
        "revoked at once");
  }

  private record Rpc(int status, Headers headers, Map<String, Object> body) {}

  @ParameterizedTest
  @MethodSource("kinds")
  void theMcpServerAnswersInitializeListsItsToolsAndCallsThemWithTheTokensReach(String kind) {
    Routes routes = make(kind);
    String secret =
        (String) token(routes, Json.object("name", "B only", "site", "b")).body().get("secret");
    send(
        routes,
        Json.object(
            "k",
            "pageview",
            "u",
            "https://b.com/pricing",
            "r",
            "https://news.ycombinator.com/",
            "i",
            "p1"),
        "203.0.113.1");
    send(routes, Json.object("k", "pageview", "u", "https://a.com/", "i", "p2"), "203.0.113.1");

    AtomicLong ids = new AtomicLong();
    RpcCall rpc =
        (method, params, auth) -> {
          Map<String, Object> message =
              Json.object("jsonrpc", "2.0", "id", ids.incrementAndGet(), "method", method);
          if (params != null) {
            message.put("params", params);
          }
          Response answer =
              routes.handle(
                  new Request(
                      "https://example.com/runlight/mcp",
                      "POST",
                      Headers.of(
                          "authorization",
                          "Bearer " + (auth != null ? auth : secret),
                          "content-type",
                          "application/json",
                          "accept",
                          "application/json, text/event-stream"),
                      Json.stringify(message)));
          return new Rpc(
              answer.status(), answer.headers(), answer.status() == 202 ? null : body(answer));
        };

    Rpc refused = rpc.call("initialize", Json.object(), "rl_" + "0".repeat(40));
    assertEquals(401, refused.status());
    assertTrue(refused.headers().get("www-authenticate").startsWith("Bearer"));
    assertEquals(405, routes.handle(owner("/runlight/mcp")).status(), "no event stream");

    Rpc init =
        rpc.call(
            "initialize",
            Json.object(
                "protocolVersion",
                "2025-06-18",
                "capabilities",
                Json.object(),
                "clientInfo",
                Json.object("name", "test", "version", "1")),
            null);
    assertEquals("2025-06-18", dig(init.body(), "result.protocolVersion"));
    assertEquals("runlight", dig(init.body(), "result.serverInfo.name"));
    assertTrue(Js.map(dig(init.body(), "result.capabilities")).containsKey("tools"));
    assertEquals(
        "2025-11-25",
        dig(
            rpc.call("initialize", Json.object("protocolVersion", "1999-01-01"), null).body(),
            "result.protocolVersion"),
        "an unknown version gets the newest");

    Response note =
        routes.handle(
            new Request(
                "https://example.com/runlight/mcp",
                "POST",
                Headers.of("authorization", "Bearer " + secret, "content-type", "application/json"),
                Json.stringify(
                    Json.object("jsonrpc", "2.0", "method", "notifications/initialized"))));
    assertEquals(202, note.status());

    Rpc listed = rpc.call("tools/list", null, null);
    List<Object> names = new ArrayList<>();
    for (Mcp.Tool tool : Mcp.TOOLS) {
      names.add(tool.name());
    }
    assertEquals(names, column(dig(listed.body(), "result.tools"), "name"));
    for (Object tool : Js.list(dig(listed.body(), "result.tools"))) {
      assertEquals(true, dig(tool, "annotations.readOnlyHint"));
    }

    ToolCall call =
        (name, args) -> {
          Map<String, Object> result =
              Js.map(
                  dig(
                      rpc.call(
                              "tools/call",
                              Json.object(
                                  "name", name, "arguments", args != null ? args : Json.object()),
                              null)
                          .body(),
                      "result"));
          Map<String, Object> out = new java.util.LinkedHashMap<>(result);
          out.put(
              "data",
              Js.truthy(result.get("isError"))
                  ? null
                  : Json.parse((String) dig(result, "content.0.text")));
          return out;
        };
    assertEquals(List.of("b"), column(dig(call.call("list_sites", null), "data.sites"), "id"));
    Map<String, Object> stats = call.call("get_stats", Json.object("period", "today"));
    assertEquals("b", dig(stats, "data.site"));
    assertEquals(1L, dig(stats, "data.stats.pageviews"));
    assertEquals(
        true,
        call.call("get_stats", Json.object("site", "a")).get("isError"),
        "another site is out of reach");
    Map<String, Object> sources =
        call.call(
            "get_breakdown", Json.object("period", "today", "dimension", "source", "limit", 500L));
    assertEquals("Hacker News", dig(sources, "data.rows.0.value"));
    assertEquals(
        0L,
        dig(
            call.call(
                "get_stats",
                Json.object("period", "today", "filters", List.of("page:is:/nowhere"))),
            "data.stats.pageviews"));
    Map<String, Object> bad = call.call("get_stats", Json.object("filters", List.of("nonsense")));
    assertEquals(true, bad.get("isError"));
    assertTrue(((String) dig(bad, "content.0.text")).contains("Bad filter"));
    Map<String, Object> times = call.call("get_visit_times", Json.object("period", "today"));
    assertEquals(7, Js.list(dig(times, "data.grid")).size());
    assertFalse(
        Js.map(times.get("data")).containsKey("cells"), "trimmed to what an assistant needs");
    assertEquals(
        0,
        Js.list(dig(call.call("list_goals", Json.object("period", "today")), "data.goals")).size());
    assertEquals(
        true, call.call("get_goal", Json.object("goal_id", "f".repeat(24))).get("isError"));
    assertFalse(call.call("list_links", null).containsKey("isError"));
    assertFalse(call.call("get_realtime", null).containsKey("isError"));

    assertEquals(
        -32602L,
        dig(rpc.call("tools/call", Json.object("name", "drop_tables"), null).body(), "error.code"));
    assertEquals(-32601L, dig(rpc.call("resources/list", null, null).body(), "error.code"));
    assertEquals("{}", Json.stringify(dig(rpc.call("ping", null, null).body(), "result")));

    // The owner's own token works too, across every site.
    Rpc everySite =
        rpc.call(
            "tools/call", Json.object("name", "list_sites", "arguments", Json.object()), "secret");
    assertEquals(
        List.of("a", "b"),
        column(
            dig(Json.parse((String) dig(everySite.body(), "result.content.0.text")), "sites"),
            "id"));
  }

  private interface RpcCall {
    Rpc call(String method, Object params, String auth);
  }

  private interface ToolCall {
    Map<String, Object> call(String name, Object args);
  }
}
