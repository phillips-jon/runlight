package sh.runlight.http;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsExchange;
import com.sun.net.httpserver.HttpsServer;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.GZIPOutputStream;
import javax.net.ssl.ExtendedSSLSession;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SNIServerName;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * The default Fetcher against real servers on 127.0.0.1: methods, headers, and bodies; chunked,
 * sized, and compressed answers; maxBytes and truncate; redirects followed and handed back; the
 * timeout; and pins, over plain HTTP and over TLS with the certificate checked against the name.
 */
class JdkFetcherTest {
  private static HttpServer server;
  private static int port;

  @BeforeAll
  static void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    port = server.getAddress().getPort();
    server.createContext("/", JdkFetcherTest::route);
    server.setExecutor(java.util.concurrent.Executors.newCachedThreadPool());
    server.start();
  }

  @AfterAll
  static void stop() {
    server.stop(0);
  }

  private static void answer(
      HttpExchange exchange, int status, String type, byte[] body, long length) throws IOException {
    if (type != null) {
      exchange.getResponseHeaders().set("content-type", type);
    }
    exchange.sendResponseHeaders(status, length);
    try (OutputStream out = exchange.getResponseBody()) {
      out.write(body);
    }
  }

  private static void route(HttpExchange exchange) throws IOException {
    String path = exchange.getRequestURI().getPath();
    String query = exchange.getRequestURI().getRawQuery();
    switch (path) {
      case "/bytes" -> {
        // n bytes of "a", chunked, in parts of 8192.
        int n = Integer.parseInt(query.substring(2));
        exchange.getResponseHeaders().set("content-type", "text/html");
        exchange.sendResponseHeaders(200, 0);
        try (OutputStream out = exchange.getResponseBody()) {
          while (n > 0) {
            int part = Math.min(n, 8192);
            out.write("a".repeat(part).getBytes(StandardCharsets.US_ASCII));
            out.flush();
            n -= part;
          }
        }
      }
      case "/sized" -> {
        byte[] body = "a".repeat(5000).getBytes(StandardCharsets.US_ASCII);
        answer(exchange, 200, "text/plain", body, body.length);
      }
      case "/gzip" -> {
        ByteArrayOutputStream zipped = new ByteArrayOutputStream();
        try (GZIPOutputStream gzip = new GZIPOutputStream(zipped)) {
          gzip.write("squeezed ".repeat(100).getBytes(StandardCharsets.US_ASCII));
        }
        exchange.getResponseHeaders().set("content-encoding", "gzip");
        answer(exchange, 200, "text/plain", zipped.toByteArray(), zipped.size());
      }
      case "/echo" -> {
        byte[] got = exchange.getRequestBody().readAllBytes();
        String text =
            exchange.getRequestMethod()
                + " "
                + exchange.getRequestURI()
                + " type="
                + exchange.getRequestHeaders().getFirst("content-type")
                + " auth="
                + exchange.getRequestHeaders().getFirst("authorization")
                + " x-one="
                + exchange.getRequestHeaders().getFirst("x-one")
                + " body="
                + new String(got, StandardCharsets.UTF_8);
        byte[] body = text.getBytes(StandardCharsets.UTF_8);
        answer(exchange, 200, "text/plain", body, body.length);
      }
      case "/redirect" -> {
        // /redirect?303, ?301, ?307, and so on, each to /echo; ?far to another origin.
        String to =
            "far".equals(query) ? "http://localhost:" + port + "/echo?far" : "/echo?from=" + query;
        exchange.getResponseHeaders().set("location", to);
        int status = "far".equals(query) ? 302 : Integer.parseInt(query);
        answer(exchange, status, null, "moved".getBytes(StandardCharsets.US_ASCII), 5);
      }
      case "/loop" -> {
        exchange.getResponseHeaders().set("location", "/loop");
        answer(exchange, 302, null, new byte[0], -1);
      }
      case "/slow" -> {
        try {
          Thread.sleep(3000);
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
        }
        answer(exchange, 200, "text/plain", new byte[] {'x'}, 1);
      }
      case "/empty" -> answer(exchange, 204, null, new byte[0], -1);
      default -> {
        byte[] body =
            ("host " + exchange.getRequestHeaders().getFirst("host"))
                .getBytes(StandardCharsets.UTF_8);
        answer(exchange, 200, "text/plain", body, body.length);
      }
    }
  }

  private static String base() {
    return "http://127.0.0.1:" + port;
  }

  @Test
  void theFetcherStopsReadingPastMaxBytes() {
    JdkFetcher fetcher = new JdkFetcher();
    String url = base() + "/bytes?n=300000";
    assertEquals(300_000, fetcher.fetch(url, new FetchInit().maxBytes(300_000)).bytes().length);
    BodyTooLong error =
        assertThrows(
            BodyTooLong.class, () -> fetcher.fetch(url, new FetchInit().maxBytes(100_000)));
    assertEquals("Body over 100000 bytes", error.getMessage());
    Response start = fetcher.fetch(url, new FetchInit().maxBytes(100_000).truncate(true));
    assertEquals(200, start.status());
    assertEquals("a".repeat(100_000), start.text(), "with truncate, the start comes back");
    assertEquals("text/html", start.headers().get("content-type"));

    // The same with a Content-Length.
    assertEquals(5000, fetcher.fetch(base() + "/sized").bytes().length);
    assertThrows(
        BodyTooLong.class, () -> fetcher.fetch(base() + "/sized", new FetchInit().maxBytes(4999)));
    assertEquals(
        "a".repeat(10),
        fetcher.fetch(base() + "/sized", new FetchInit().maxBytes(10).truncate(true)).text());
  }

  @Test
  void bodiesComeBackDecodedAndEmptyWhereTheyHaveNone() {
    JdkFetcher fetcher = new JdkFetcher();
    assertEquals("squeezed ".repeat(100), fetcher.fetch(base() + "/gzip").text());
    Response empty = fetcher.fetch(base() + "/empty");
    assertEquals(204, empty.status());
    assertEquals(0, empty.bytes().length);
    Response head = fetcher.fetch(base() + "/sized", new FetchInit().method("HEAD"));
    assertEquals(200, head.status());
    assertEquals(0, head.bytes().length);
  }

  @Test
  void methodsHeadersAndBodiesAreSent() {
    Response answer =
        new JdkFetcher()
            .fetch(
                base() + "/echo?q=1",
                new FetchInit()
                    .method("post")
                    .header("content-type", "application/json")
                    .header("x-one", "1")
                    .body("{\"café\":1}"));
    assertEquals(
        "POST /echo?q=1 type=application/json auth=null x-one=1 body={\"café\":1}", answer.text());
  }

  @Test
  void redirectsAreFollowedAsFetchFollowsThem() {
    JdkFetcher fetcher = new JdkFetcher();
    FetchInit post =
        new FetchInit()
            .method("POST")
            .header("content-type", "text/plain")
            .header("authorization", "Bearer x")
            .body("hi");
    assertEquals(
        "GET /echo?from=303 type=null auth=Bearer x x-one=null body=",
        fetcher.fetch(base() + "/redirect?303", post).text(),
        "a 303 becomes a GET without the body");
    assertEquals(
        "GET /echo?from=302 type=null auth=Bearer x x-one=null body=",
        fetcher.fetch(base() + "/redirect?302", post).text());
    assertEquals(
        "POST /echo?from=307 type=text/plain auth=Bearer x x-one=null body=hi",
        fetcher.fetch(base() + "/redirect?307", post).text(),
        "a 307 keeps the method and body");
    assertEquals(
        "POST /echo?from=308 type=text/plain auth=Bearer x x-one=null body=hi",
        fetcher.fetch(base() + "/redirect?308", post).text());
    assertEquals(
        "GET /echo?far type=null auth=null x-one=null body=",
        fetcher.fetch(base() + "/redirect?far", post).text(),
        "credentials stay behind on another origin");

    Response manual = fetcher.fetch(base() + "/redirect?301", new FetchInit().redirect("manual"));
    assertEquals(301, manual.status());
    assertEquals("/echo?from=301", manual.headers().get("location"));
    assertEquals("moved", manual.text());

    FetchError loop = assertThrows(FetchError.class, () -> fetcher.fetch(base() + "/loop"));
    assertFalse(loop.timedOut());
  }

  @Test
  void theWholeRequestIsHeldToItsTimeout() {
    long started = System.nanoTime();
    FetchError error =
        assertThrows(
            FetchError.class,
            () -> new JdkFetcher().fetch(base() + "/slow", new FetchInit().timeoutMs(300)));
    assertTrue(error.timedOut());
    assertTrue((System.nanoTime() - started) / 1_000_000 < 2000, "it gives up at its timeout");
  }

  @Test
  void noAnswerIsAFetchError() throws IOException {
    int free;
    try (ServerSocket probe = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      free = probe.getLocalPort();
    }
    FetchError refused =
        assertThrows(
            FetchError.class, () -> new JdkFetcher().fetch("http://127.0.0.1:" + free + "/"));
    assertFalse(refused.timedOut());
    assertThrows(FetchError.class, () -> new JdkFetcher().fetch("ftp://127.0.0.1/"));

    // A server that hangs up without a word.
    try (ServerSocket mute = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      Thread closer =
          new Thread(
              () -> {
                try (Socket s = mute.accept()) {
                  s.getInputStream().read();
                } catch (IOException e) {
                  // The test is over.
                }
              });
      closer.start();
      assertThrows(
          FetchError.class,
          () -> new JdkFetcher().fetch("http://127.0.0.1:" + mute.getLocalPort() + "/"));
    }
  }

  @Test
  void theFetcherConnectsToThePinnedAddress() {
    Response answer =
        new JdkFetcher()
            .fetch(
                "http://pinned.invalid:" + port + "/",
                new FetchInit().resolve("pinned.invalid:" + port + ":127.0.0.1"));
    assertEquals("host pinned.invalid:" + port, answer.text());
    // The first address that answers is used, a bracketed v6 one among them.
    Response second =
        new JdkFetcher()
            .fetch(
                "http://pinned.invalid:" + port + "/",
                new FetchInit().resolve("pinned.invalid:" + port + ":[::1],127.0.0.1"));
    assertEquals(200, second.status());
    // A pin for another name or port is not used.
    assertThrows(
        FetchError.class,
        () ->
            new JdkFetcher()
                .fetch(
                    "http://pinned.invalid:" + port + "/",
                    new FetchInit().resolve("other.invalid:" + port + ":127.0.0.1")));
  }

  /** A self-signed certificate for pinned.test, made with the JDK's keytool. */
  private static KeyStore keyStore(Path dir) throws Exception {
    Path file = dir.resolve("test.p12");
    Process keytool =
        new ProcessBuilder(
                Path.of(System.getProperty("java.home"), "bin", "keytool").toString(),
                "-genkeypair",
                "-alias",
                "test",
                "-keyalg",
                "EC",
                "-groupname",
                "secp256r1",
                "-dname",
                "CN=pinned.test",
                "-ext",
                "SAN=dns:pinned.test",
                "-validity",
                "2",
                "-storetype",
                "PKCS12",
                "-keystore",
                file.toString(),
                "-storepass",
                "changeit",
                "-keypass",
                "changeit")
            .redirectErrorStream(true)
            .start();
    String output = new String(keytool.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    assertEquals(0, keytool.waitFor(), output);
    KeyStore store = KeyStore.getInstance("PKCS12");
    try (InputStream in = Files.newInputStream(file)) {
      store.load(in, "changeit".toCharArray());
    }
    return store;
  }

  @Test
  void tlsIsCheckedAgainstTheNameAndSendsItAsSniWhenPinned(@TempDir Path dir) throws Exception {
    KeyStore store = keyStore(dir);
    KeyManagerFactory keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
    keys.init(store, "changeit".toCharArray());
    SSLContext serverContext = SSLContext.getInstance("TLS");
    serverContext.init(keys.getKeyManagers(), null, null);
    TrustManagerFactory trust =
        TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
    trust.init(store);
    SSLContext clientContext = SSLContext.getInstance("TLS");
    clientContext.init(null, trust.getTrustManagers(), null);

    HttpsServer https =
        HttpsServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    https.setHttpsConfigurator(new HttpsConfigurator(serverContext));
    List<String> names = new ArrayList<>();
    https.createContext(
        "/",
        exchange -> {
          ExtendedSSLSession session =
              (ExtendedSSLSession) ((HttpsExchange) exchange).getSSLSession();
          for (SNIServerName name : session.getRequestedServerNames()) {
            names.add(((SNIHostName) name).getAsciiName());
          }
          answer(exchange, 200, "text/plain", "secure".getBytes(StandardCharsets.UTF_8), 6);
        });
    https.start();
    int tlsPort = https.getAddress().getPort();
    try {
      JdkFetcher fetcher = new JdkFetcher(clientContext.getSocketFactory());
      Response answer =
          fetcher.fetch(
              "https://pinned.test:" + tlsPort + "/",
              new FetchInit().resolve("pinned.test:" + tlsPort + ":127.0.0.1"));
      assertEquals("secure", answer.text());
      assertEquals(List.of("pinned.test"), names);

      // The same address under a name the certificate does not carry is refused.
      FetchError wrongName =
          assertThrows(
              FetchError.class,
              () ->
                  fetcher.fetch(
                      "https://wrong.test:" + tlsPort + "/",
                      new FetchInit().resolve("wrong.test:" + tlsPort + ":127.0.0.1")));
      assertFalse(wrongName.timedOut());
      // And a certificate nobody vouches for is refused too.
      assertThrows(
          FetchError.class,
          () ->
              new JdkFetcher()
                  .fetch(
                      "https://pinned.test:" + tlsPort + "/",
                      new FetchInit().resolve("pinned.test:" + tlsPort + ":127.0.0.1")));
    } finally {
      https.stop(0);
    }
  }
}
