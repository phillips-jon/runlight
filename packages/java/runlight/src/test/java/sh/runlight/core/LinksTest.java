package sh.runlight.core;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.core.CheckTest.loose;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.store.Databases;

/**
 * Short links followed through linkHandler() and linkDomainResponse(), as links.test.ts tests them.
 * Making, changing, and importing them through Links alone is in sh.runlight.LinksTest.
 */
class LinksTest {
  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void tearDown() {
    Databases.cleanup();
  }

  /** A link domain added as the routes add one. */
  private static void addDomain(Harness t, String domain) {
    t.store().addLinkDomain(domain, "default", t.now);
    t.rl.forgetLinkDomains();
  }

  private static void removeDomain(Harness t, String domain) {
    t.store().removeLinkDomain(domain);
    t.rl.forgetLinkDomains();
  }

  private static Request get(String url, String... headers) {
    return new Request(url, "GET", Headers.of(headers), "");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void createFollowAndCountAShortLink(String kind) {
    Harness t = new Harness(kind);
    Map<String, Object> link =
        t.rl.links.create(
            "default", Json.object("url", "https://thedailypreset.com/presets/golden?ref=x"));
    String slug = (String) link.get("slug");
    assertTrue(slug.matches("[a-z2-9]{6}"));
    assertEquals("thedailypreset.com/presets/golden", link.get("name"));

    BiFunction<String, String[], Response> go =
        (path, extra) -> {
          Headers headers =
              Headers.of("user-agent", Harness.CHROME_MAC, "x-forwarded-for", "203.0.113.9");
          for (int i = 0; i + 1 < extra.length; i += 2) {
            headers.set(extra[i], extra[i + 1]);
          }
          return t.rl
              .linkHandler()
              .apply(new Request("https://example.com" + path, "GET", headers, ""));
        };
    Response response =
        go.apply(
            "/go/" + slug + "?utm_source=newsletter&utm_medium=email",
            new String[] {"referer", "https://mail.google.com/"});
    assertEquals(302, response.status());
    assertEquals(
        "https://thedailypreset.com/presets/golden?ref=x", response.headers().get("location"));
    assertEquals("no-store", response.headers().get("cache-control"));
    assertEquals("no-referrer-when-downgrade", response.headers().get("referrer-policy"));
    Response missing = go.apply("/go/nope", new String[0]);
    assertEquals(404, missing.status());
    assertEquals("Not found", missing.text());
    assertEquals("text/plain; charset=utf-8", missing.headers().get("content-type"));
    // Link previews and crawlers are sent on but not counted.
    assertEquals(
        302,
        go.apply("/go/" + slug, new String[] {"user-agent", "facebookexternalhit/1.1"}).status());

    Map<String, Object> today = t.today();
    long from = Js.asLong(today.get("from"));
    long to = Js.asLong(today.get("to"));
    List<Map<String, Object>> list = t.store().links("default", from, to);
    assertEquals(1L, Js.asLong(list.get(0).get("clicks")));
    assertEquals(1L, Js.asLong(list.get(0).get("visitors")));
    assertEquals(
        loose(Json.array(Json.object("value", "Newsletter", "visitors", 1L, "events", 1L))),
        loose(t.store().linkBreakdown("default", (String) link.get("id"), from, to, "source", 10)));

    // Clicks are not visits: the site's own numbers do not move.
    Map<String, Object> site = t.stats(today);
    assertEquals(0L, site.get("visitors"));
    assertEquals(0L, site.get("pageviews"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void customLinkDomainsAnswerAtTheirRootAndOnlyForTheirOwnLinks(String kind) {
    Harness t = new Harness(kind);
    t.rl.init();
    addDomain(t, "t.thedailypreset.com");
    t.rl.links.create(
        "default",
        Json.object(
            "url", "https://thedailypreset.com/a", "slug", "a", "domain", "t.thedailypreset.com"));
    t.rl.links.create("default", Json.object("url", "https://example.com/b", "slug", "b"));

    BiFunction<String, String, Response> at =
        (host, path) ->
            t.rl.linkDomainResponse(
                get("https://" + host + path, "host", host, "user-agent", Harness.CHROME_MAC));
    assertEquals(
        "https://thedailypreset.com/a",
        at.apply("t.thedailypreset.com", "/a").headers().get("location"));
    assertEquals(
        404,
        at.apply("t.thedailypreset.com", "/b").status(),
        "the main site's links are not on the link domain");
    assertNull(at.apply("example.com", "/a"), "other hosts carry on as normal");
    assertNull(
        at.apply("t.thedailypreset.com", "/runlight/api/sites"),
        "the dashboard's own paths are left alone");
    // The app's own link path answers for every link, as a fallback that never changes.
    assertEquals(
        302,
        t.rl
            .linkHandler()
            .apply(get("https://example.com/go/a", "user-agent", Harness.CHROME_MAC))
            .status());
    Response check = at.apply("t.thedailypreset.com", Runlight.LINK_DOMAIN_CHECK);
    assertEquals("{\"runlight\":true,\"domain\":\"t.thedailypreset.com\"}", check.text());
    assertEquals("application/json", check.headers().get("content-type"));

    // Removing the domain keeps its links: they fall back to the app's own path.
    removeDomain(t, "t.thedailypreset.com");
    assertNull(at.apply("t.thedailypreset.com", "/a"), "the removed domain is no longer answered");
    assertEquals(
        "https://thedailypreset.com/a",
        t.rl
            .linkHandler()
            .apply(get("https://example.com/go/a", "user-agent", Harness.CHROME_MAC))
            .headers()
            .get("location"));
    Map<String, Object> a = null;
    for (Map<String, Object> l : t.store().links("default", 0, t.now + 1)) {
      if ("a".equals(l.get("slug"))) {
        a = l;
      }
    }
    assertEquals("t.thedailypreset.com", a.get("domain"), "the link remembers its domain");

    // Adding it back brings the links home again.
    addDomain(t, "t.thedailypreset.com");
    assertEquals(
        "https://thedailypreset.com/a",
        at.apply("t.thedailypreset.com", "/a").headers().get("location"));
  }

  @Test
  void aClickIsCountedAsAClickWithItsSourceAndNeverWithAnAddress() {
    Harness t = new Harness("sqlite");
    Map<String, Object> link =
        t.rl.links.create("default", Json.object("url", "https://a.com/", "slug", "x"));
    var unused =
        t.rl
            .linkHandler()
            .apply(
                get(
                    "https://example.com/go/x",
                    "user-agent",
                    Harness.CHROME_MAC,
                    "x-forwarded-for",
                    "192.0.2.77",
                    "accept-language",
                    "fr-CA,fr;q=0.9",
                    "host",
                    "example.com:8080"));
    Map<String, Object> event =
        t.store().db().all("SELECT kind, name, link, path, hostname FROM rl_events").get(0);
    List<String> values = new ArrayList<>();
    for (Object v : event.values()) {
      values.add(Js.string(v));
    }
    assertEquals(List.of("click", "x", (String) link.get("id"), "/go/x", "example.com"), values);
    Map<String, Object> session =
        t.store().db().all("SELECT language, pageviews FROM rl_sessions").get(0);
    assertEquals("fr-CA", session.get("language"));
    assertFalse(
        Json.stringify(t.store().db().all("SELECT * FROM rl_sessions")).contains("192.0.2.77"));
    // A HEAD request, as a link checker sends, is answered and not counted.
    unused =
        t.rl
            .linkHandler()
            .apply(
                new Request(
                    "https://example.com/go/x",
                    "HEAD",
                    Headers.of("user-agent", Harness.CHROME_MAC),
                    ""));
    assertEquals(1, t.count("SELECT COUNT(*) AS n FROM rl_events"));
  }
}
