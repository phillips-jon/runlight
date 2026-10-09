package sh.runlight.server;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpContext;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;
import sh.runlight.store.Stores;

/** Runlight on the JDK's own HTTP server, end to end over real HTTP on 127.0.0.1. */
class JdkServerTest {
  private static final String CHROME =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
  private static final String GPTBOT =
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)";
  private static final long NOW = 1_791_374_400_000L; // 2026-10-07 12:00 UTC

  private HttpServer server;
  private Runlight rl;
  private String base;
  private final HttpClient client = HttpClient.newHttpClient();
  private final AtomicInteger idled = new AtomicInteger();

  @BeforeEach
  void start() throws IOException {
    rl =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .site(Json.object("hostnames", Json.array("example.com")))
                .now(() -> NOW));
    Routes routes = rl.routes(new Routes.Options().basePath("/runlight").token("owner"));
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
    JdkServer.mount(server, rl, routes);
    HttpContext app =
        server.createContext(
            "/",
            exchange -> {
              byte[] body = "the app".getBytes(StandardCharsets.UTF_8);
              exchange.sendResponseHeaders(200, body.length);
              exchange.getResponseBody().write(body);
              exchange.close();
            });
    app.getFilters().add(JdkServer.linkDomains(rl));
    app.getFilters().add(JdkServer.observer(rl));
    server.createContext(
        "/cookies",
        JdkServer.handler(
            (request, context) ->
                new Response(
                    "ip " + context.get("ip") + " " + request.url(),
                    200,
                    Headers.of("set-cookie", "a=1; Path=/", "set-cookie", "b=2, c; Path=/")),
            idled::incrementAndGet));
    server.createContext(
        "/stream",
        JdkServer.handler(
            (request, context) ->
                new Response(
                    out -> {
                      for (int i = 0; i < 3; i++) {
                        out.write(("part " + i + "\n").getBytes(StandardCharsets.UTF_8));
                        out.flush();
                      }
                      if (request.url().endsWith("?fail")) {
                        throw new IOException("the source broke");
                      }
                    },
                    200,
                    Headers.of("content-type", "text/plain")),
            null));
    server.createContext(
        "/early",
        JdkServer.handler(
            (request, context) ->
                new Response(
                    out -> {
                      throw new IOException("nothing to send");
                    },
                    200,
                    Headers.of("content-type", "text/plain", "x-kept", "no")),
            null));
    server.start();
    base = "http://127.0.0.1:" + server.getAddress().getPort();
  }

  @AfterEach
  void stop() {
    server.stop(0);
  }

  private HttpResponse<String> send(String method, String path, String body, String... headers)
      throws IOException, InterruptedException {
    HttpRequest.Builder request =
        HttpRequest.newBuilder(URI.create(base + path))
            .method(
                method,
                body == null
                    ? HttpRequest.BodyPublishers.noBody()
                    : HttpRequest.BodyPublishers.ofString(body));
    if (headers.length > 0) {
      request.headers(headers);
    }
    return client.send(request.build(), HttpResponse.BodyHandlers.ofString());
  }

  private HttpResponse<String> get(String path, String... headers)
      throws IOException, InterruptedException {
    return send("GET", path, null, headers);
  }

  @Test
  void aPageviewThroughTheCollectEndpointIsReadBackThroughTheApiWithTheToken() throws Exception {
    assertEquals(200, get("/runlight/s.js").statusCode());
    HttpResponse<String> hit =
        send(
            "POST",
            "/runlight/e",
            Json.stringify(Json.object("k", "pageview", "u", "https://example.com/post")),
            "user-agent",
            CHROME,
            "content-type",
            "text/plain");
    assertEquals(202, hit.statusCode());
    assertEquals(401, get("/runlight/api/stats?period=today").statusCode());
    HttpResponse<String> stats =
        get("/runlight/api/stats?period=today", "authorization", "Bearer owner");
    assertEquals(200, stats.statusCode());
    Map<String, Object> read = Js.map(Json.parse(stats.body()));
    assertEquals(1L, Js.map(read.get("stats")).get("pageviews"));
  }

  @Test
  void theDashboardPageAndItsTokenCookie() throws Exception {
    HttpResponse<String> page = get("/runlight/?token=owner");
    List<String> cookies = page.headers().allValues("set-cookie");
    assertTrue(
        cookies.stream().anyMatch(c -> c.startsWith(Routes.COOKIE + "=")), cookies.toString());
    String cookie = cookies.get(0).split(";", -1)[0];
    HttpResponse<String> dashboard = get("/runlight/", "cookie", cookie);
    assertEquals(200, dashboard.statusCode());
    assertTrue(dashboard.headers().firstValue("content-type").orElse("").startsWith("text/html"));
    assertTrue(dashboard.body().contains("<html"), dashboard.body());
    HttpResponse<String> head = send("HEAD", "/cookies/", null);
    assertEquals(200, head.statusCode());
    assertEquals("", head.body());
  }

  @Test
  void shortLinksAnswerAtTheLinkPathAndOnALinkDomainWhileTheAppKeepsTheRest() throws Exception {
    String[] auth = {"authorization", "Bearer owner", "content-type", "application/json"};
    assertEquals(
        201,
        send(
                "POST",
                "/runlight/api/link-domains",
                Json.stringify(Json.object("domain", "go.example.com")),
                auth)
            .statusCode());
    HttpResponse<String> made =
        send(
            "POST",
            "/runlight/api/links",
            Json.stringify(
                Json.object(
                    "url",
                    "https://example.com/launch",
                    "slug",
                    "launch",
                    "domain",
                    "go.example.com")),
            auth);
    assertEquals(201, made.statusCode(), made.body());
    send(
        "POST",
        "/runlight/api/links",
        Json.stringify(Json.object("url", "https://example.com/sale", "slug", "sale")),
        auth);

    HttpResponse<String> own = get("/go/sale", "user-agent", CHROME);
    assertEquals(302, own.statusCode());
    assertEquals("https://example.com/sale", own.headers().firstValue("location").orElse(null));

    HttpResponse<String> linked = get("/launch", "x-forwarded-host", "go.example.com");
    assertEquals(302, linked.statusCode());
    assertEquals(
        "https://example.com/launch", linked.headers().firstValue("location").orElse(null));
    HttpResponse<String> check =
        get(Runlight.LINK_DOMAIN_CHECK, "x-forwarded-host", "go.example.com");
    assertEquals("{\"runlight\":true,\"domain\":\"go.example.com\"}", check.body());
    assertEquals(404, get("/nope", "x-forwarded-host", "go.example.com").statusCode());

    HttpResponse<String> app = get("/launch");
    assertEquals(200, app.statusCode());
    assertEquals("the app", app.body(), "any other host is the app's");
  }

  @Test
  void anAiAgentFetchOfTheAppsPagesIsRecorded() throws Exception {
    assertEquals(
        "the app", get("/docs/", "user-agent", GPTBOT, "x-forwarded-host", "example.com").body());
    get("/about", "user-agent", CHROME, "x-forwarded-host", "example.com");
    List<Map<String, Object>> fetches =
        rl.store.db().all("SELECT path FROM rl_events WHERE kind = 'fetch'", List.of());
    assertEquals(1, fetches.size(), fetches.toString());
    assertEquals("/docs/", fetches.get(0).get("path"));
  }

  @Test
  void everySetCookieGoesOutOnALineOfItsOwnAndIdleRunsAfter() throws Exception {
    HttpResponse<String> answer = get("/cookies/x?y=1");
    assertEquals(
        List.of("a=1; Path=/", "b=2, c; Path=/"), answer.headers().allValues("set-cookie"));
    assertEquals("ip 127.0.0.1 " + base + "/cookies/x?y=1", answer.body());
    assertEquals(
        "ip 127.0.0.1 https://127.0.0.1:" + server.getAddress().getPort() + "/cookies/x?y=1",
        get("/cookies/x?y=1", "x-forwarded-proto", "HTTPS, http").body(),
        "the scheme a proxy names");
    assertEquals(2, idled.get());
  }

  @Test
  void streamedBodiesGoOutAsWrittenAndOneThatBreaksIsCutOrA500() throws Exception {
    HttpResponse<String> whole = get("/stream");
    assertEquals(200, whole.statusCode());
    assertEquals("part 0\npart 1\npart 2\n", whole.body());
    assertThrows(IOException.class, () -> get("/stream?fail"), "a cut answer never looks whole");
    HttpResponse<String> early = get("/early");
    assertEquals(500, early.statusCode());
    assertEquals("", early.body());
    assertTrue(early.headers().firstValue("x-kept").isEmpty());
  }

  @Test
  void aBodyPastItsLimitIsA413() throws Exception {
    HttpResponse<String> big =
        send(
            "POST",
            "/runlight/e",
            "x".repeat(JdkServer.MAX_COLLECT_BODY + 1),
            "user-agent",
            CHROME);
    assertEquals(413, big.statusCode());
    assertEquals("{\"error\":\"That request is too large\"}", big.body());
  }

  @Test
  void ipv6AddressesAreWrittenShort() {
    byte[] loopback = new byte[16];
    loopback[15] = 1;
    assertEquals("::1", JdkServer.ipv6(loopback));
    byte[] doc = {0x20, 0x01, 0x0d, (byte) 0xb8, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1};
    assertEquals("2001:db8::1:0:0:1", JdkServer.ipv6(doc));
    assertEquals("::", JdkServer.ipv6(new byte[16]));
  }
}
