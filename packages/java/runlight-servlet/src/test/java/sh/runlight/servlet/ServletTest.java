package sh.runlight.servlet;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import jakarta.servlet.DispatcherType;
import jakarta.servlet.Filter;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;
import org.eclipse.jetty.ee10.servlet.FilterHolder;
import org.eclipse.jetty.ee10.servlet.ServletContextHandler;
import org.eclipse.jetty.ee10.servlet.ServletHolder;
import org.eclipse.jetty.server.Server;
import org.eclipse.jetty.server.ServerConnector;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.store.Stores;

/**
 * Runlight behind a servlet container: the servlet and the filter in an embedded Jetty 12, over
 * real HTTP on 127.0.0.1. The PHP port's HttpFoundationTest, and what a servlet adds: the base path
 * from the mapping and the context, the body cap, a form a filter ahead already read, several
 * Set-Cookie headers, streamed answers, link domains, and AI agent fetches.
 */
class ServletTest {
  private static final long NOW = 1_791_374_400_000L;
  private static final String CHROME = "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36";
  private static final String GPTBOT =
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2;"
          + " +https://openai.com/gptbot)";

  private Server server;

  @AfterEach
  void stop() throws Exception {
    if (server != null) {
      server.stop();
    }
  }

  private static Runlight runlight() {
    return new Runlight(
        new Runlight.Options()
            .store(Stores.sqlite(":memory:"))
            .site(Json.object("name", "example.com", "hostnames", Json.array("example.com")))
            .now(() -> NOW));
  }

  /** The app's own pages: a servlet that answers "app" for anything Runlight leaves alone. */
  static final class App extends HttpServlet {
    private static final long serialVersionUID = 1L;

    @Override
    protected void service(HttpServletRequest req, HttpServletResponse res) throws IOException {
      res.setContentType("text/plain");
      res.getWriter().write("app " + req.getRequestURI());
    }
  }

  /** Starts Jetty with a context, its servlets by mapping, and filters ahead of them on /*. */
  private int start(String context, Map<String, HttpServlet> servlets, Filter... filters)
      throws Exception {
    server = new Server();
    ServerConnector connector = new ServerConnector(server);
    connector.setHost("127.0.0.1");
    connector.setPort(0);
    server.addConnector(connector);
    ServletContextHandler handler = new ServletContextHandler();
    handler.setContextPath(context);
    for (Filter filter : filters) {
      handler.addFilter(new FilterHolder(filter), "/*", EnumSet.of(DispatcherType.REQUEST));
    }
    int i = 0;
    for (Map.Entry<String, HttpServlet> entry : servlets.entrySet()) {
      ServletHolder holder = new ServletHolder("s" + i++, entry.getValue());
      holder.setInitOrder(1);
      handler.addServlet(holder, entry.getKey());
    }
    handler.addServlet(new ServletHolder("app", new App()), "/");
    server.setHandler(handler);
    server.start();
    return connector.getLocalPort();
  }

  private int start(Runlight rl, Routes.Options options) throws Exception {
    return start(
        "/", Map.of("/runlight/*", new RunlightServlet(rl, options)), new RunlightFilter(rl));
  }

  private static byte[] utf8(String text) {
    return text.getBytes(StandardCharsets.UTF_8);
  }

  /** Echoes the request as the bridge reads it. */
  static final class Echo extends HttpServlet {
    private static final long serialVersionUID = 1L;

    @Override
    protected void service(HttpServletRequest req, HttpServletResponse res) throws IOException {
      Request ours = ServletBridge.requestWithBody(req);
      ServletBridge.write(
          res,
          Response.json(
              Json.object(
                  "url",
                  ours.url(),
                  "method",
                  ours.method(),
                  "address",
                  ours.remoteAddress(),
                  "forwardedFor",
                  ours.headers().get("x-forwarded-for"),
                  "ip",
                  ServletBridge.context(req).get("ip"),
                  "body",
                  ours.text())));
    }
  }

  @Test
  void theRequestKeepsItsQueryStringAndTheConnectionsAddress() throws Exception {
    int port = start("/", Map.of("/echo/*", new Echo()));
    RawHttp.Answer answer =
        RawHttp.send(
            port,
            "POST",
            "/echo/api/stats?site=a&period=7d&b=%2F",
            utf8("{\"k\":\"pageview\"}"),
            "X-Forwarded-For",
            "203.0.113.9",
            "X-Forwarded-Proto",
            "https");
    Map<String, Object> read = Js.map(Json.parse(answer.text()));
    assertEquals("https://example.com/echo/api/stats?site=a&period=7d&b=%2F", read.get("url"));
    assertEquals("POST", read.get("method"));
    assertEquals("127.0.0.1", read.get("address"), "the connection's, not the header's");
    assertEquals("127.0.0.1", read.get("ip"));
    assertEquals("203.0.113.9", read.get("forwardedFor"));
    assertEquals("{\"k\":\"pageview\"}", read.get("body"));

    Map<String, Object> plain =
        Js.map(Json.parse(RawHttp.get(port, "/echo/x", "Host", "example.com:8080").text()));
    assertEquals("http://example.com:8080/echo/x", plain.get("url"));
    assertEquals("", plain.get("body"));
  }

  @Test
  void aTrackerHitAndTheDashboardTokenCookieGoThrough() throws Exception {
    Runlight rl = runlight();
    int port = start(rl, new Routes.Options().token("app-token"));
    RawHttp.Answer hit =
        RawHttp.send(
            port,
            "POST",
            "/runlight/e",
            utf8("{\"k\":\"pageview\",\"u\":\"https://example.com/post\"}"),
            "User-Agent",
            CHROME);
    assertEquals(202, hit.status());

    RawHttp.Answer signIn = RawHttp.get(port, "/runlight/?token=app-token");
    assertEquals(303, signIn.status());
    List<String> cookies = signIn.all("set-cookie");
    assertEquals(1, cookies.size(), cookies.toString());
    assertTrue(cookies.get(0).startsWith("runlight_token="), cookies.get(0));
    assertTrue(cookies.get(0).toLowerCase(java.util.Locale.ROOT).contains("httponly"));

    String cookie = cookies.get(0).split(";", 2)[0];
    RawHttp.Answer stats = RawHttp.get(port, "/runlight/api/stats?period=today", "Cookie", cookie);
    assertEquals(200, stats.status(), stats.text());
    Map<String, Object> body = Js.map(Json.parse(stats.text()));
    assertEquals(1L, Js.map(body.get("stats")).get("pageviews"));

    assertEquals("app /elsewhere", RawHttp.get(port, "/elsewhere").text(), "left to the app");
  }

  @Test
  void aShortLinkAnswersAtGo() throws Exception {
    Runlight rl = runlight();
    int port = start(rl, new Routes.Options().token("app-token"));
    RawHttp.Answer made =
        RawHttp.send(
            port,
            "POST",
            "/runlight/api/links",
            utf8("{\"url\":\"https://example.org/sale\",\"slug\":\"sale\"}"),
            "Authorization",
            "Bearer app-token",
            "Content-Type",
            "application/json");
    assertEquals(201, made.status(), made.text());
    RawHttp.Answer go = RawHttp.get(port, "/go/sale", "User-Agent", CHROME);
    assertEquals(302, go.status());
    assertEquals("https://example.org/sale", go.header("location"));
    assertEquals(404, RawHttp.get(port, "/go/nothing").status());
    assertEquals("app /go", RawHttp.get(port, "/go").text(), "not a link");
    assertEquals(
        "app /go/sale",
        RawHttp.send(port, "POST", "/go/sale", new byte[0]).text(),
        "only a GET is a link");
  }

  @Test
  void theBaseAndTheLinkPathAreWithinTheContext() throws Exception {
    Runlight rl = runlight();
    RunlightServlet servlet = new RunlightServlet(rl, new Routes.Options().token(null));
    int port = start("/app", Map.of("/stats/*", servlet), new RunlightFilter(rl));
    RawHttp.Answer page = RawHttp.get(port, "/app/stats/");
    assertEquals(200, page.status(), page.text());
    assertTrue(page.text().contains("/app/stats/"), "the dashboard's links carry its base");
    assertEquals(200, RawHttp.get(port, "/app/stats/api/sites").status());
    assertEquals(List.of("/app/stats"), rl.routeBases);

    rl.links.create("default", Json.object("url", "https://example.org/a", "slug", "a"));
    RawHttp.Answer go = RawHttp.get(port, "/app/go/a", "User-Agent", CHROME);
    assertEquals(302, go.status(), go.text());
    assertEquals("https://example.org/a", go.header("location"));
  }

  @Test
  void aLinkDomainIsAnsweredAndLeavesTheDashboardAlone() throws Exception {
    Runlight rl = runlight();
    int port = start(rl, new Routes.Options().token(null));
    rl.init();
    rl.store.addLinkDomain("t.example.com", "default", NOW);
    rl.forgetLinkDomains();
    RawHttp.Answer check = RawHttp.get(port, Runlight.LINK_DOMAIN_CHECK, "Host", "t.example.com");
    assertEquals(200, check.status());
    assertEquals("{\"runlight\":true,\"domain\":\"t.example.com\"}", check.text());
    assertEquals(404, RawHttp.get(port, "/nothing", "Host", "t.example.com").status());
    RawHttp.Answer made =
        RawHttp.send(
            port,
            "POST",
            "/runlight/api/links",
            utf8(
                "{\"url\":\"https://example.org/launch\",\"slug\":\"launch\",\"domain\":\"t.example.com\"}"),
            "Content-Type",
            "application/json");
    assertEquals(201, made.status(), made.text());
    RawHttp.Answer linked =
        RawHttp.get(port, "/launch", "Host", "t.example.com", "User-Agent", CHROME);
    assertEquals(302, linked.status());
    assertEquals("https://example.org/launch", linked.header("location"));
    assertEquals("app /launch", RawHttp.get(port, "/launch").text(), "the app keeps its own");
    assertEquals(
        200,
        RawHttp.get(port, "/runlight/api/sites", "Host", "t.example.com").status(),
        "the dashboard stays reachable");
    assertEquals("app /nothing", RawHttp.get(port, "/nothing").text(), "the app's own domain");
  }

  @Test
  void anAiAgentFetchIsObservedAndAPersonsIsNot() throws Exception {
    Runlight rl = runlight();
    int port = start(rl, new Routes.Options().token(null));
    assertEquals("app /about", RawHttp.get(port, "/about", "User-Agent", GPTBOT).text());
    RawHttp.get(port, "/contact", "User-Agent", CHROME);
    RawHttp.get(port, "/style.css", "User-Agent", GPTBOT);
    List<Map<String, Object>> fetches =
        rl.store.db().all("SELECT path, name FROM rl_events WHERE kind = 'fetch'");
    assertEquals(1, fetches.size(), fetches.toString());
    assertEquals("/about", fetches.get(0).get("path"));
  }

  @Test
  void aBodyPastTheLimitIs413() throws Exception {
    Runlight rl = runlight();
    int port = start(rl, new Routes.Options().token("app-token"));
    RawHttp.Answer big =
        RawHttp.send(
            port,
            "POST",
            "/runlight/e",
            new byte[ServletBridge.MAX_COLLECT_BODY + 1],
            "User-Agent",
            CHROME);
    assertEquals(413, big.status());
    assertEquals("{\"error\":\"That request is too large\"}", big.text());
    assertEquals("close", big.header("connection"));
    RawHttp.Answer atTheCap =
        RawHttp.send(
            port,
            "POST",
            "/runlight/e",
            new byte[ServletBridge.MAX_COLLECT_BODY],
            "User-Agent",
            CHROME);
    assertTrue(atTheCap.status() != 413, "a body at the limit is read");
  }

  /** A filter ahead that reads a form's fields, as Spring Security's CSRF check does. */
  static final class ReadsTheForm implements Filter {
    @Override
    public void doFilter(
        jakarta.servlet.ServletRequest request,
        jakarta.servlet.ServletResponse response,
        jakarta.servlet.FilterChain chain)
        throws IOException, jakarta.servlet.ServletException {
      request.getParameter("a");
      chain.doFilter(request, response);
    }
  }

  @Test
  void aFormAFilterAheadAlreadyReadIsTakenFromTheParameters() throws Exception {
    int port = start("/", Map.of("/echo/*", new Echo()), new ReadsTheForm());
    RawHttp.Answer answer =
        RawHttp.send(
            port,
            "POST",
            "/echo/x?q=1&a=0",
            utf8("a=1&b=two+words&c=%26"),
            "Content-Type",
            "application/x-www-form-urlencoded");
    assertEquals("a=1&b=two+words&c=%26", Js.map(Json.parse(answer.text())).get("body"));
  }

  /** Answers with what the test sets, through the bridge. */
  static final class Answers extends HttpServlet {
    private static final long serialVersionUID = 1L;
    private final transient Response answer;

    Answers(Response answer) {
      this.answer = answer;
    }

    @Override
    protected void service(HttpServletRequest req, HttpServletResponse res) throws IOException {
      ServletBridge.write(res, answer);
    }
  }

  @Test
  void severalSetCookieHeadersStayApart() throws Exception {
    Headers headers =
        Headers.of("content-type", "text/plain", "set-cookie", "a=1; Path=/; HttpOnly")
            .append("set-cookie", "b=2, with a comma; Path=/");
    int port = start("/", Map.of("/c", new Answers(new Response("ok", 200, headers))));
    RawHttp.Answer answer = RawHttp.get(port, "/c");
    assertEquals(
        List.of("a=1; Path=/; HttpOnly", "b=2, with a comma; Path=/"), answer.all("set-cookie"));
    assertEquals("ok", answer.text());
    assertEquals("2", answer.header("content-length"));
  }

  @Test
  void aStreamedAnswerIsStreamed() throws Exception {
    Response streamed =
        new Response(
            out -> {
              out.write(utf8("a,b\n"));
              out.flush();
              for (int row = 0; row < 20_000; row++) {
                out.write(utf8("1,2\n"));
              }
            },
            200,
            Headers.of("content-type", "text/csv"));
    Response broken =
        new Response(
            out -> {
              throw new IllegalStateException("the export failed");
            },
            200,
            Headers.of("content-type", "text/csv"));
    int port = start("/", Map.of("/s", new Answers(streamed), "/b", new Answers(broken)));
    RawHttp.Answer answer = RawHttp.get(port, "/s");
    assertEquals(200, answer.status());
    assertEquals("a,b\n" + "1,2\n".repeat(20_000), answer.text());
    assertNull(
        answer.header("content-length"), "sent as it is written, with no length known ahead");
    assertEquals(500, RawHttp.get(port, "/b").status(), "failed before its first byte");
  }

  @Test
  void theServletsBaseComesFromItsMapping() throws Exception {
    Runlight rl = runlight();
    RunlightServlet servlet = new RunlightServlet(rl, new Routes.Options().token(null));
    int port = start("/", Map.of("/analytics/*", servlet));
    assertNotNull(servlet.routes(), "made when the servlet started");
    assertEquals(200, RawHttp.get(port, "/analytics/api/sites").status());
    assertEquals(List.of("/analytics"), rl.routeBases);
  }
}
