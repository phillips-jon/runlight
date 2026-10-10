package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.SocketTimeoutException;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import sh.runlight.http.FetchError;
import sh.runlight.http.Response;

/**
 * Ports safefetch.test.ts, replays the address checks in outbound.json, and covers each hop's
 * checks.
 */
class SafefetchTest {
  /** A DNS stand-in. */
  private static Function<String, List<String>> dns(Map<String, List<String>> names) {
    return name -> names.getOrDefault(name, List.of());
  }

  private static Map<String, Object> init(Object... more) {
    Map<String, Object> init = Json.object("timeoutMs", 2000L);
    init.putAll(Json.object(more));
    return init;
  }

  @Test
  void onlyAddressesOnThePublicInternetCountAsPublic() {
    for (String ip :
        List.of("93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e")) {
      assertTrue(Safefetch.publicAddress(ip), ip);
    }
    for (String ip :
        List.of(
            "127.0.0.1",
            "10.0.0.1",
            "172.16.5.4",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "224.0.0.1",
            "255.255.255.255",
            "::1",
            "::",
            "fe80::1",
            "fd00::1",
            "ff02::1",
            "::ffff:127.0.0.1",
            "::ffff:7f00:1",
            "::ffff:169.254.169.254",
            "64:ff9b::a00:1",
            "2002:a00:1::",
            "2001:db8::1",
            "2001:0:4136:e378::1",
            "[::1]",
            "not an address",
            "1.2.3",
            "1.2.3.256")) {
      assertFalse(Safefetch.publicAddress(ip), ip);
    }
  }

  @Test
  void addressChecksMatchTypeScript() {
    List<Map<String, Object>> cases = Fixtures.cases(Fixtures.load("outbound"), "ips");
    assertTrue(cases.size() > 50);
    for (Map<String, Object> c : cases) {
      assertEquals(
          c.get("public"), Safefetch.publicAddress((String) c.get("ip")), (String) c.get("ip"));
    }
  }

  @Test
  void aPublicFetchNeverReachesTheInstallsOwnNetworkHoweverTheAddressIsWritten()
      throws IOException {
    // Something listening locally, which none of these may reach.
    try (ServerSocket inside = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      int port = inside.getLocalPort();
      for (String url :
          List.of(
              "http://127.0.0.1:" + port + "/",
              "https://127.0.0.1:" + port + "/",
              "https://[::1]:" + port + "/",
              "https://[::ffff:127.0.0.1]:" + port + "/",
              "https://localhost:" + port + "/",
              "https://LOCALHOST.:" + port + "/",
              "https://app.localhost:" + port + "/")) {
        assertThrows(
            PrivateAddressError.class,
            () -> Safefetch.publicFetch(url, init(), null),
            url + " should be refused");
      }
      inside.setSoTimeout(1);
      assertThrows(SocketTimeoutException.class, inside::accept, "nothing connected");
    }
    assertTrue(Safefetch.resolvesPrivately("localhost"));
    assertFalse(Safefetch.resolvesPrivately("name.that.does.not.resolve.invalid"));
    assertEquals(List.of(), Safefetch.publicAddresses("name.that.does.not.resolve.invalid"));
    assertEquals(List.of("8.8.8.8"), Safefetch.publicAddresses("8.8.8.8"));
    assertEquals(List.of(), Safefetch.publicAddresses("localhost"));
  }

  @Test
  void theCheckedAddressesArePinned() {
    RecordingFetcher fetcher = new RecordingFetcher((url, init) -> new Response("ok", 200));
    Response answer =
        Safefetch.publicFetch(
            "https://Example.com/icon",
            init(
                "headers",
                Map.of("user-agent", "Runlight"),
                "maxBytes",
                10L,
                "lookup",
                dns(Map.of("example.com", List.of("93.184.215.14", "2606:4700::1111")))),
            fetcher);
    assertEquals("ok", answer.text());
    assertEquals(
        List.of("example.com:443:93.184.215.14,[2606:4700::1111]"), fetcher.inits.get(0).resolve);
    assertEquals("manual", fetcher.inits.get(0).redirect);
    assertEquals(10L, fetcher.inits.get(0).maxBytes);
    assertFalse(fetcher.inits.get(0).truncate);
    assertTrue(fetcher.inits.get(0).timeoutMs <= 2000);
    Fixtures.assertJson(
        Json.object(
            "method",
            "GET",
            "url",
            "https://example.com/icon",
            "headers",
            Json.object("user-agent", "Runlight"),
            "body",
            ""),
        fetcher.requests.get(0));

    RecordingFetcher literal = new RecordingFetcher((url, init) -> new Response("ok", 200));
    Safefetch.publicFetch("https://93.184.215.14:8443/", init("lookup", dns(Map.of())), literal);
    assertEquals(List.of(), literal.inits.get(0).resolve, "an address needs no pin");
    assertNull(literal.inits.get(0).maxBytes);
  }

  @Test
  void aNameWithAnyPrivateAddressIsRefused() {
    RecordingFetcher fetcher = new RecordingFetcher((url, init) -> new Response("ok", 200));
    Map<String, List<String>> names =
        Map.of(
            "inside.example", List.of("10.0.0.5"),
            "mixed.example", List.of("93.184.215.14", "169.254.169.254"),
            "mapped.example", List.of("::ffff:127.0.0.1"));
    for (Map.Entry<String, List<String>> entry : names.entrySet()) {
      String name = entry.getKey();
      PrivateAddressError error =
          assertThrows(
              PrivateAddressError.class,
              () ->
                  Safefetch.publicFetch(
                      "https://" + name + "/",
                      init("lookup", dns(Map.of(name, entry.getValue()))),
                      fetcher));
      assertEquals(name + " is not a public address", error.getMessage());
    }
    assertEquals(List.of(), fetcher.requests);
    assertThrows(
        FetchError.class,
        () ->
            Safefetch.publicFetch(
                "https://nowhere.example/", init("lookup", dns(Map.of())), fetcher));
  }

  @Test
  void anInstallIsFetchedOnlyOnThePublicInternetOrAsHttpOnThisMachineWhenAllowed() {
    RecordingFetcher fetcher = new RecordingFetcher((url, init) -> new Response("ok", 200));
    Map<String, Object> post =
        init("method", "POST", "body", "{}", "headers", Map.of("content-type", "application/json"));
    assertEquals(
        "ok", Safefetch.installFetch("https://hub.example/x", post, false, fetcher).text());
    assertEquals("POST", fetcher.inits.get(0).method);
    assertEquals("{}", fetcher.inits.get(0).bodyText());
    assertEquals(List.of("hub.example:443:93.184.215.14"), fetcher.inits.get(0).resolve);
    // Trying things out on one machine: plain http to localhost and 127.0.0.1, only when allowed.
    for (String local : List.of("http://localhost:4100/runlight", "http://127.0.0.1/api")) {
      assertTrue(Safefetch.installAddress(local, true), local);
      assertFalse(Safefetch.installAddress(local, false), local);
      assertEquals("ok", Safefetch.installFetch(local, init(), true, fetcher).text(), local);
      assertThrows(
          PrivateAddressError.class,
          () -> Safefetch.installFetch(local, init(), false, fetcher),
          local);
    }
    assertEquals(List.of(), fetcher.inits.get(2).resolve, "a local address is not pinned");
    for (String refused :
        List.of(
            "http://hub.example/",
            "https://localhost/",
            "https://127.0.0.1/",
            "http://169.254.169.254/latest/meta-data",
            "http://10.0.0.1/",
            "http://localhost.evil.example/")) {
      assertThrows(
          PrivateAddressError.class,
          () -> Safefetch.installFetch(refused, init(), true, fetcher),
          refused);
    }
    fetcher.dns = name -> List.of("10.0.0.5");
    assertThrows(
        PrivateAddressError.class,
        () -> Safefetch.installFetch("https://inside.example/", init(), false, fetcher),
        "a name for a private address");
    assertEquals(3, fetcher.requests.size(), "nothing refused was sent");

    RecordingFetcher redirected =
        hops(Response.redirect("http://169.254.169.254/latest/meta-data", 302));
    assertEquals(
        302,
        Safefetch.installFetch("https://hub.example/", init("redirects", 5L), false, redirected)
            .status(),
        "a redirect comes back as it is, never followed");
    assertEquals(1, redirected.requests.size());
    RecordingFetcher posted = hops(Response.redirect("/elsewhere", 307));
    assertEquals(
        307,
        Safefetch.publicFetch(
                "https://hub.example/", init("method", "POST", "redirects", 3L), posted)
            .status(),
        "only a GET follows redirects");
  }

  /** A fetcher answering with these, in turn, then "end". */
  private static RecordingFetcher hops(Response... answers) {
    java.util.Deque<Response> left = new java.util.ArrayDeque<>(List.of(answers));
    return new RecordingFetcher(
        (url, init) -> left.isEmpty() ? new Response("end", 200) : left.poll());
  }

  @Test
  void redirectsAreFollowedByHandUnderTheSameRules() {
    Function<String, List<String>> lookup =
        dns(
            Map.of(
                "a.example", List.of("93.184.215.14"),
                "b.example", List.of("1.1.1.1"),
                "inside.example", List.of("192.168.0.2")));
    RecordingFetcher fetcher =
        hops(
            Response.redirect("/next", 301),
            Response.redirect("https://b.example/last", 302),
            new Response("done", 200));
    Response answer =
        Safefetch.publicFetch(
            "https://a.example/", init("redirects", 3L, "lookup", lookup), fetcher);
    assertEquals("done", answer.text());
    assertEquals(
        List.of("https://a.example/", "https://a.example/next", "https://b.example/last"),
        fetcher.urls());
    assertEquals(List.of("b.example:443:1.1.1.1"), fetcher.inits.get(2).resolve);

    RecordingFetcher once = hops(Response.redirect("https://b.example/", 302));
    assertEquals(
        302,
        Safefetch.publicFetch("https://a.example/", init("lookup", lookup), once).status(),
        "a redirect past the last comes back as it is");

    Map<String, String> refused =
        Map.of(
            "https://10.0.0.1/", "10.0.0.1",
            "https://inside.example/", "inside.example",
            "http://b.example/", "http://b.example/",
            "https://[fe80::1]/", "fe80::1");
    for (Map.Entry<String, String> entry : refused.entrySet()) {
      PrivateAddressError error =
          assertThrows(
              PrivateAddressError.class,
              () ->
                  Safefetch.publicFetch(
                      "https://a.example/",
                      init("redirects", 3L, "lookup", lookup),
                      hops(Response.redirect(entry.getKey(), 302))));
      assertEquals(entry.getValue() + " is not a public address", error.getMessage());
    }
  }

  @Test
  void runningOutOfTimeSaysSo() {
    Function<String, List<String>> lookup = dns(Map.of("a.example", List.of("1.1.1.1")));
    FetchError error =
        assertThrows(
            FetchError.class,
            () ->
                Safefetch.publicFetch(
                    "https://a.example/", init("lookup", lookup), new RecordingFetcher("timeout")));
    assertTrue(error.timedOut());
    assertEquals("The operation was aborted due to timeout", error.getMessage());
    FetchError refused =
        assertThrows(
            FetchError.class,
            () ->
                Safefetch.publicFetch(
                    "https://a.example/", init("lookup", lookup), new RecordingFetcher("network")));
    assertEquals("Could not connect", refused.getMessage());
    assertFalse(refused.timedOut());
  }
}
