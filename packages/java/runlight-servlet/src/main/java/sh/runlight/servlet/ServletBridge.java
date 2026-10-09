package sh.runlight.servlet;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * A servlet request as Runlight reads it, and Runlight's answer written back: what the SDK's Node
 * adapter (node.ts) does for Node's http module, and the PHP port's Bridge\HttpFoundation for
 * Symfony's request and response.
 *
 * <p>The URL is the one the browser asked for: the scheme from {@code X-Forwarded-Proto}, else the
 * connection's, the {@code Host} header, and {@code getRequestURI()} (which the container leaves
 * undecoded) with the query string as sent. The address is the connection's, since Runlight reads
 * proxy headers itself, only when {@code trustProxy} allows. A body is read only for a method that
 * has one, capped at 16 KiB for the tracker's {@code /e} and 10 MiB for everything else.
 */
public final class ServletBridge {
  private ServletBridge() {}

  /** The collect endpoint's limit; its payloads are under 8 KB. */
  public static final int MAX_COLLECT_BODY = 16 * 1024;

  /** Everything else, such as a link import of 5,000 rows. */
  public static final int MAX_BODY = 10 * 1024 * 1024;

  /**
   * How much of a body past its limit is read and thrown away, so the client finishes sending and
   * reads the 413 rather than a reset connection. Past this the connection is cut.
   */
  public static final long MAX_DRAIN = 64L * 1024 * 1024;

  /** The request without its body, for the link filter, which leaves the body to the app. */
  public static Request request(HttpServletRequest req) {
    return new Request(url(req), req.getMethod(), headers(req), new byte[0], address(req));
  }

  /**
   * The request with its body, read for any method but GET and HEAD.
   *
   * @throws BodyTooLarge past the limit for its path, after reading up to {@link #MAX_DRAIN} more
   */
  public static Request requestWithBody(HttpServletRequest req) throws IOException {
    String method = req.getMethod().toUpperCase(Locale.ROOT);
    byte[] body = new byte[0];
    if (!method.equals("GET") && !method.equals("HEAD")) {
      String path = req.getRequestURI() == null ? "" : req.getRequestURI();
      body = body(req, path.endsWith("/e") ? MAX_COLLECT_BODY : MAX_BODY);
    }
    return new Request(url(req), method, headers(req), body, address(req));
  }

  /** What the routes and link handlers take beside the request: ip, the connection's address. */
  public static Map<String, Object> context(HttpServletRequest req) {
    return Map.of("ip", address(req));
  }

  /** The absolute URL the browser asked for, or {@code http://localhost/} when it makes none. */
  public static String url(HttpServletRequest req) {
    String forwarded = req.getHeader("x-forwarded-proto");
    String proto = "";
    if (forwarded != null) {
      proto = Js.lower(Js.trim(forwarded.split(",", -1)[0]));
    }
    if (proto.isEmpty()) {
      proto = req.isSecure() ? "https" : "http";
    }
    String host = req.getHeader("host");
    if (host == null) {
      host = "localhost";
    }
    String target = req.getRequestURI() == null ? "/" : req.getRequestURI();
    if (req.getQueryString() != null) {
      target += "?" + req.getQueryString();
    }
    try {
      return new Url(
              target.startsWith("/") ? target : "/" + target,
              (proto.equals("https") ? "https" : "http") + "://" + host)
          .href();
    } catch (IllegalArgumentException e) {
      return "http://localhost/";
    }
  }

  private static String address(HttpServletRequest req) {
    String address = req.getRemoteAddr();
    return address == null ? "" : address;
  }

  private static Headers headers(HttpServletRequest req) {
    Headers headers = new Headers();
    Enumeration<String> names = req.getHeaderNames();
    while (names != null && names.hasMoreElements()) {
      String name = names.nextElement();
      if (name.startsWith(":")) {
        continue;
      }
      Enumeration<String> values = req.getHeaders(name);
      while (values != null && values.hasMoreElements()) {
        headers.append(name, values.nextElement());
      }
    }
    return headers;
  }

  /**
   * The body up to {@code limit}. A form body a filter ahead already read (Spring Security's CSRF
   * check, anything that called {@code getParameter}) leaves nothing to read; the container's
   * parsed parameters are then taken, less those of the query, which the servlet specification puts
   * first.
   */
  private static byte[] body(HttpServletRequest req, int limit) throws IOException {
    ByteArrayOutputStream kept = new ByteArrayOutputStream();
    long size = 0;
    try {
      InputStream in = req.getInputStream();
      byte[] chunk = new byte[16 * 1024];
      int n;
      while ((n = in.read(chunk)) != -1) {
        size += n;
        if (size > limit + MAX_DRAIN) {
          break;
        }
        if (size <= limit) {
          kept.write(chunk, 0, n);
        }
      }
    } catch (IllegalStateException e) {
      // A filter ahead called getReader(), after which the specification refuses the stream: the
      // body was read already.
      return new byte[0];
    }
    if (size > limit) {
      throw new BodyTooLarge(limit);
    }
    if (size > 0) {
      return kept.toByteArray();
    }
    String type = req.getContentType();
    if (type == null || !Js.lower(type).contains("application/x-www-form-urlencoded")) {
      return new byte[0];
    }
    return formBody(req);
  }

  private static byte[] formBody(HttpServletRequest req) {
    Charset charset = StandardCharsets.UTF_8;
    // The query's values come first in each parameter's list; they are not the body's.
    Map<String, Integer> fromQuery = new HashMap<>();
    String query = req.getQueryString();
    if (query != null && !query.isEmpty()) {
      for (String pair : query.split("&", -1)) {
        if (pair.isEmpty()) {
          continue;
        }
        int eq = pair.indexOf('=');
        String name = eq < 0 ? pair : pair.substring(0, eq);
        try {
          name = URLDecoder.decode(name, charset);
        } catch (IllegalArgumentException e) {
          // Kept as sent, as the container may have.
        }
        fromQuery.merge(name, 1, Integer::sum);
      }
    }
    StringBuilder out = new StringBuilder();
    for (Map.Entry<String, String[]> entry : req.getParameterMap().entrySet()) {
      String[] values = entry.getValue();
      int skip = fromQuery.getOrDefault(entry.getKey(), 0);
      for (int i = skip; i < values.length; i++) {
        if (out.length() > 0) {
          out.append('&');
        }
        out.append(URLEncoder.encode(entry.getKey(), charset))
            .append('=')
            .append(URLEncoder.encode(values[i], charset));
      }
    }
    return out.toString().getBytes(StandardCharsets.UTF_8);
  }

  /**
   * Writes an answer: its status, its headers (each Set-Cookie on a line of its own), and its body,
   * streamed as it is written when Runlight streams it (exports, a pass-through to a connected
   * install). A streamed body that fails before anything was sent is a plain 500; one that fails
   * after is thrown, so the container cuts the connection rather than send a short answer that
   * looks whole.
   *
   * @throws IOException when the client went away
   */
  public static void write(HttpServletResponse res, Response answer) throws IOException {
    res.setStatus(answer.status());
    boolean streamed = answer.streamed();
    for (Map.Entry<String, List<String>> header : answer.headers().all().entrySet()) {
      String name = header.getKey();
      if (name.equals("set-cookie")) {
        for (String cookie : header.getValue()) {
          res.addHeader(name, cookie);
        }
      } else if (!name.equals("content-length") || streamed) {
        res.setHeader(name, String.join(", ", header.getValue()));
      }
    }
    if (!streamed) {
      byte[] body = answer.bytes();
      res.setContentLengthLong(body.length);
      if (body.length > 0) {
        OutputStream out = res.getOutputStream();
        out.write(body);
        out.flush();
      }
      return;
    }
    OutputStream out = res.getOutputStream();
    try {
      answer.writeTo(out);
    } catch (RuntimeException e) {
      if (res.isCommitted()) {
        throw e;
      }
      res.reset();
      res.setStatus(500);
      return;
    }
    out.flush();
  }

  /**
   * Sends an answer and then runs the work Runlight leaves for after answering (a retention
   * change's deletions) with {@link Runlight#idle()}, as the SDK runs it once the visitor has the
   * answer. A client that went away is not reported.
   */
  public static void send(HttpServletResponse res, Response answer, Runlight runlight) {
    try {
      write(res, answer);
      res.flushBuffer();
    } catch (IOException e) {
      // The client went away: nothing to report.
    }
    try {
      runlight.idle();
    } catch (RuntimeException e) {
      log(e);
    }
  }

  /** The 413 for a body past its limit; an upload cut off part way leaves the connection unfit. */
  public static void tooLarge(HttpServletResponse res) {
    try {
      res.setStatus(413);
      res.setHeader("connection", "close");
      res.setHeader("content-type", "application/json; charset=utf-8");
      byte[] body = Js.utf8(Json.stringify(Json.object("error", "That request is too large")));
      res.setContentLength(body.length);
      res.getOutputStream().write(body);
      res.flushBuffer();
    } catch (IOException e) {
      // The client went away.
    }
  }

  /** The 500 the PHP port's front controller answers when a link or link domain lookup throws. */
  static Response internalError() {
    return new Response(
        Json.stringify(Json.object("error", "Internal error", "code", "internal")),
        500,
        Headers.of(
            "content-type",
            "application/json; charset=utf-8",
            "cache-control",
            "no-store",
            "x-content-type-options",
            "nosniff"));
  }

  /** console.error, as the core logs. */
  static void log(Throwable error) {
    System.err.println("Runlight: " + error);
  }
}
