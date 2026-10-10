package sh.runlight.server;

import com.sun.net.httpserver.Filter;
import com.sun.net.httpserver.HttpContext;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsExchange;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * Runlight on the JDK's own HTTP server ({@code com.sun.net.httpserver}), the counterpart of the
 * SDK's node.ts for a program with no framework:
 *
 * <pre>{@code
 * Runlight rl = new Runlight(new Runlight.Options().store(Stores.sqlite("runlight.db")));
 * HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
 * server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
 * Routes routes = rl.routes(new Routes.Options().basePath("/runlight"));
 * HttpContext app = JdkServer.mount(server, rl, routes, myHandler); // link domains answered too
 * app.getFilters().add(JdkServer.observer(rl)); // AI agent fetches of the app's pages
 * server.start();
 * }</pre>
 *
 * <p>Each request is answered as PHP's FrontController answers it: a link domain added in Settings
 * first (it leaves the dashboard's own paths alone), then {@code {linkPath}/{slug}} on the app's
 * own domain, then the routes. Once the answer is sent, the work TS does after answering (a
 * retention change's deletions) runs in {@link Runlight#idle()}.
 *
 * <p>The routes read the database, so give the server an executor of virtual threads or a pool (the
 * JDK's default runs every exchange on its one dispatcher thread). Bodies are capped as node.ts
 * caps them: 16 KB for the collect endpoint and 10 MB for everything else, answered with 413 past
 * that. Streamed answers (exports, pass-throughs) are sent as they are written.
 */
public final class JdkServer {
  private JdkServer() {}

  /** The collect endpoint's limit; its payloads are under 8 KB. */
  public static final int MAX_COLLECT_BODY = 16 * 1024;

  /** Everything else, such as a link import of 5,000 rows. */
  public static final int MAX_BODY = 10 * 1024 * 1024;

  /**
   * How much of a body past its limit is read and thrown away, so the client finishes sending and
   * reads the 413 rather than a reset connection. Past this the connection is cut.
   */
  public static final long MAX_DRAIN = 64L * 1024 * 1024;

  private static final Pattern COLLECT = Pattern.compile("/e\\z");

  /** A body past the limit, answered with 413 rather than passed on empty. */
  public static final class BodyTooLarge extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public BodyTooLarge(String message) {
      super(message);
    }
  }

  /** Answers one request, given the context the adapter knows: ip, the connection's address. */
  @FunctionalInterface
  public interface Handler {
    Response handle(Request request, Map<String, Object> context);
  }

  /**
   * Mounts Runlight on the app's server: a context at the routes' base path ("/" when it is ""),
   * and one at the link path when that is not under it, both answered by {@link #handler(Runlight,
   * Routes)}. Returns the base path's context, for filters of the app's own.
   */
  public static HttpContext mount(HttpServer server, Runlight runlight, Routes routes) {
    HttpHandler handler = handler(runlight, routes);
    String base = routes.basePath();
    HttpContext context = server.createContext(base.isEmpty() ? "/" : base, handler);
    String links = runlight.linkPath;
    if (!base.isEmpty()
        && !links.isEmpty()
        && !links.equals(base)
        && !links.startsWith(base + "/")) {
      server.createContext(links, handler);
    }
    return context;
  }

  /**
   * Mounts Runlight as {@link #mount(HttpServer, Runlight, Routes)} does and serves the app's own
   * handler at "/" behind the {@link #linkDomains(Runlight)} filter, so a request on a link domain
   * added in Settings is answered with its short link and every other request reaches the app
   * untouched. Returns the app's context, for filters of its own. The routes need a base path,
   * since "/" is the app's.
   */
  public static HttpContext mount(
      HttpServer server, Runlight runlight, Routes routes, HttpHandler app) {
    if (routes.basePath().isEmpty()) {
      throw new IllegalArgumentException(
          "Give the routes a base path, such as /runlight, since the app answers at /");
    }
    mount(server, runlight, routes);
    HttpContext context = server.createContext("/", app);
    context.getFilters().add(linkDomains(runlight));
    return context;
  }

  /**
   * Runlight as an {@link HttpHandler}: link domains, {@code {linkPath}/{slug}}, then the routes,
   * with {@link Runlight#idle()} after each answer is sent.
   */
  public static HttpHandler handler(Runlight runlight, Routes routes) {
    return handler((request, context) -> answer(runlight, routes, request), runlight::idle);
  }

  /**
   * Any handler as an {@link HttpHandler}, with {@code after} run once each answer is sent (null
   * for nothing). A handler that throws is answered with a bare 500.
   */
  public static HttpHandler handler(Handler handler, Runnable after) {
    return exchange -> serve(exchange, handler, after);
  }

  /**
   * The answer to one request, as {@link #handler(Runlight, Routes)} sends it: a link domain added
   * in Settings first, then {@code {linkPath}/{slug}} on the app's own domain, then the routes.
   */
  public static Response answer(Runlight runlight, Routes routes, Request request) {
    Map<String, Object> context = Json.object("ip", request.remoteAddress());
    try {
      Response linked = runlight.linkDomainResponse(request, context);
      if (linked != null) {
        return linked;
      }
      String path = new Url(request.url()).pathname;
      if (request.method().equals("GET")
          && Pattern.compile("^" + Pattern.quote(runlight.linkPath) + "/[^/]+/?\\z")
              .matcher(path)
              .find()) {
        return runlight.linkHandler().apply(request);
      }
      return routes.handle(request, context);
    } catch (RuntimeException error) {
      System.err.println("Runlight: " + error.getMessage());
      return Routes.coded("Internal error", "internal", 500);
    }
  }

  /**
   * A filter for the app's own contexts that answers short links when a request arrives on a link
   * domain added in Settings (such as t.example.com), and passes every other request on. The body
   * is left for the app.
   */
  public static Filter linkDomains(Runlight runlight) {
    return new Filter() {
      @Override
      public void doFilter(HttpExchange exchange, Chain chain) throws IOException {
        Request request = head(exchange);
        Response linked =
            runlight.linkDomainResponse(request, Json.object("ip", request.remoteAddress()));
        if (linked == null) {
          chain.doFilter(exchange);
          return;
        }
        writeResponse(exchange, linked);
        exchange.close();
        idle(runlight::idle);
      }

      @Override
      public String description() {
        return "Runlight link domains";
      }
    };
  }

  /**
   * A filter that records AI agent fetches of the app's pages and always passes the request on. The
   * fetch is recorded once the app has answered, so nobody waits for it.
   */
  public static Filter observer(Runlight runlight) {
    return new Filter() {
      @Override
      public void doFilter(HttpExchange exchange, Chain chain) throws IOException {
        Request request =
            exchange.getRequestMethod().equalsIgnoreCase("GET") ? head(exchange) : null;
        try {
          chain.doFilter(exchange);
        } finally {
          if (request != null) {
            try {
              runlight.observe(request);
            } catch (RuntimeException error) {
              System.err.println("Runlight: could not record an AI agent fetch " + error);
            }
          }
        }
      }

      @Override
      public String description() {
        return "Runlight AI agent observer";
      }
    };
  }

  private static void serve(HttpExchange exchange, Handler handler, Runnable after)
      throws IOException {
    Response response;
    try {
      Request request = toRequest(exchange);
      response = handler.handle(request, Json.object("ip", request.remoteAddress()));
    } catch (BodyTooLarge error) {
      // An upload cut off part way leaves the connection unfit for another request.
      response =
          new Response(
              Json.stringify(Json.object("error", "That request is too large")),
              413,
              Headers.of("content-type", "application/json; charset=utf-8", "connection", "close"));
    } catch (RuntimeException error) {
      System.err.println("Runlight: " + error);
      response = new Response(new byte[0], 500, new Headers());
    }
    // Not closed when the answer is cut part way: the exception drops the connection instead.
    writeResponse(exchange, response);
    exchange.close();
    if (after != null) {
      idle(after);
    }
  }

  private static void idle(Runnable after) {
    try {
      after.run();
    } catch (RuntimeException error) {
      System.err.println("Runlight: " + error);
    }
  }

  /** The request without its body, for filters that leave the body to the app. */
  private static Request head(HttpExchange exchange) {
    return new Request(
        urlOf(exchange),
        exchange.getRequestMethod(),
        headersOf(exchange),
        new byte[0],
        addressOf(exchange));
  }

  /**
   * The exchange as a Request: an absolute URL from the Host header and the scheme
   * (X-Forwarded-Proto first, as node.ts reads it), the method, every header, the body (capped),
   * and the connection's address.
   *
   * @throws BodyTooLarge when the body is past its limit
   */
  public static Request toRequest(HttpExchange exchange) throws IOException {
    String method = exchange.getRequestMethod().toUpperCase(Locale.ROOT);
    byte[] body = new byte[0];
    if (!method.equals("GET") && !method.equals("HEAD")) {
      String path = exchange.getRequestURI().getRawPath();
      boolean collect = path != null && COLLECT.matcher(path).find();
      body = readBody(exchange.getRequestBody(), collect ? MAX_COLLECT_BODY : MAX_BODY);
    }
    return new Request(urlOf(exchange), method, headersOf(exchange), body, addressOf(exchange));
  }

  private static byte[] readBody(InputStream in, int limit) throws IOException {
    ByteArrayOutputStream kept = new ByteArrayOutputStream();
    byte[] chunk = new byte[16 * 1024];
    long size = 0;
    for (int n; (n = in.read(chunk)) >= 0; ) {
      long before = size;
      size += n;
      if (size > limit + MAX_DRAIN) {
        break;
      }
      if (before < limit) {
        kept.write(chunk, 0, (int) Math.min(n, limit - before));
      }
    }
    if (size > limit) {
      throw new BodyTooLarge("Request body over " + limit + " bytes");
    }
    return kept.toByteArray();
  }

  private static Headers headersOf(HttpExchange exchange) {
    Headers headers = new Headers();
    for (Map.Entry<String, List<String>> entry : exchange.getRequestHeaders().entrySet()) {
      if (entry.getKey() == null || entry.getKey().startsWith(":")) {
        continue;
      }
      for (String value : entry.getValue()) {
        headers.append(entry.getKey(), value);
      }
    }
    return headers;
  }

  private static String urlOf(HttpExchange exchange) {
    String forwarded = exchange.getRequestHeaders().getFirst("x-forwarded-proto");
    String proto = Js.lower(forwarded == null ? "" : Js.trim(forwarded.split(",", -1)[0]));
    if (proto.isEmpty()) {
      proto = exchange instanceof HttpsExchange ? "https" : "http";
    }
    String host = exchange.getRequestHeaders().getFirst("host");
    String target = exchange.getRequestURI().toString();
    try {
      return new Url(
              target.startsWith("/") ? target : "/" + target,
              (proto.equals("https") ? "https" : "http")
                  + "://"
                  + (host == null ? "localhost" : host))
          .href();
    } catch (IllegalArgumentException error) {
      return "http://localhost/";
    }
  }

  /** The connection's address, an IPv6 one written short as Node writes it. */
  private static String addressOf(HttpExchange exchange) {
    InetSocketAddress remote = exchange.getRemoteAddress();
    InetAddress address = remote == null ? null : remote.getAddress();
    if (address == null) {
      return "";
    }
    return address instanceof Inet6Address six ? ipv6(six.getAddress()) : address.getHostAddress();
  }

  /** An IPv6 address as RFC 5952 writes it: the longest run of two or more zero groups as "::". */
  static String ipv6(byte[] bytes) {
    int[] groups = new int[8];
    for (int i = 0; i < 8; i++) {
      groups[i] = ((bytes[2 * i] & 0xFF) << 8) | (bytes[2 * i + 1] & 0xFF);
    }
    int bestStart = -1;
    int bestLength = 1;
    for (int i = 0; i < 8; ) {
      if (groups[i] != 0) {
        i++;
        continue;
      }
      int start = i;
      while (i < 8 && groups[i] == 0) {
        i++;
      }
      if (i - start > bestLength) {
        bestStart = start;
        bestLength = i - start;
      }
    }
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < 8; i++) {
      if (i == bestStart) {
        out.append("::");
        i += bestLength - 1;
        continue;
      }
      if (out.length() > 0 && out.charAt(out.length() - 1) != ':') {
        out.append(':');
      }
      out.append(Integer.toHexString(groups[i]));
    }
    return out.toString();
  }

  /**
   * Sends a Response: its status and every header, each Set-Cookie on a line of its own, and its
   * body. A streamed body goes out as it is written; one that fails before its first byte is a
   * plain 500, and one that fails part way cuts the connection, rather than a short answer that
   * looks whole. Does not close the exchange.
   */
  public static void writeResponse(HttpExchange exchange, Response response) throws IOException {
    com.sun.net.httpserver.Headers out = exchange.getResponseHeaders();
    for (Map.Entry<String, List<String>> entry : response.headers().all().entrySet()) {
      String name = entry.getKey();
      if (name.equals("content-length") || name.equals("transfer-encoding")) {
        continue;
      }
      if (name.equals("set-cookie")) {
        for (String value : entry.getValue()) {
          out.add(name, value);
        }
      } else {
        out.set(name, String.join(", ", entry.getValue()));
      }
    }
    int status = response.status();
    boolean bodiless =
        exchange.getRequestMethod().equalsIgnoreCase("HEAD")
            || status == 204
            || status == 304
            || status < 200;
    if (!response.streamed()) {
      byte[] body = response.bytes();
      try {
        exchange.sendResponseHeaders(status, bodiless || body.length == 0 ? -1 : body.length);
        if (!bodiless && body.length > 0) {
          OutputStream stream = exchange.getResponseBody();
          stream.write(body);
          stream.flush();
        }
      } catch (IOException gone) {
        // The client went away before its answer was written: nothing to report.
      }
      return;
    }
    if (bodiless) {
      exchange.sendResponseHeaders(status, -1);
      return;
    }
    Streamed stream = new Streamed(exchange, status);
    try {
      response.writeTo(stream);
      stream.flush();
    } catch (IOException | RuntimeException error) {
      if (!stream.started) {
        out.clear();
        exchange.sendResponseHeaders(500, -1);
        return;
      }
      // Thrown out of the handler, which makes the JDK's server drop the connection before the
      // last chunk, so the client sees a cut answer.
      throw error instanceof IOException e ? new UncheckedIOException(e) : (RuntimeException) error;
    }
  }

  /** Sends the headers at the first byte, so a body that fails before it can still be a 500. */
  private static final class Streamed extends OutputStream {
    private final HttpExchange exchange;
    private final int status;
    private OutputStream body;
    boolean started;

    Streamed(HttpExchange exchange, int status) {
      this.exchange = exchange;
      this.status = status;
    }

    private OutputStream body() throws IOException {
      if (body == null) {
        started = true;
        exchange.sendResponseHeaders(status, 0);
        body = exchange.getResponseBody();
      }
      return body;
    }

    @Override
    public void write(int b) throws IOException {
      body().write(b);
    }

    @Override
    public void write(byte[] bytes, int offset, int length) throws IOException {
      if (length > 0) {
        body().write(bytes, offset, length);
      }
    }

    @Override
    public void flush() throws IOException {
      body().flush();
    }
  }
}
