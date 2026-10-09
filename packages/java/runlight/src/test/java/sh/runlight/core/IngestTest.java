package sh.runlight.core;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.core.CheckTest.loose;
import static sh.runlight.core.Harness.DAY;
import static sh.runlight.core.Harness.MIN;
import static sh.runlight.core.Harness.utc;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BiConsumer;
import java.util.function.Consumer;
import java.util.function.LongSupplier;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.store.Databases;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * The tracker endpoint's work, as ingest.test.ts, audit.test.ts, and hardening.test.ts test it,
 * read back from the store.
 */
class IngestTest {
  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void tearDown() {
    Databases.cleanup();
  }

  private static Map<String, Object> pageview(String url, String id) {
    return Json.object("k", "pageview", "u", url, "i", id);
  }

  private static List<Object> sorted(List<Object> values) {
    List<Object> out = new ArrayList<>(values);
    out.sort((a, b) -> ((String) a).compareTo((String) b));
    return out;
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aVisitPageviewsAnEventEngagementAndTheReportsThatFollow(String kind) {
    Harness t = new Harness(kind);
    t.send(
        Json.object(
            "k",
            "pageview",
            "u",
            "https://example.com/?utm_source=chatgpt.com",
            "r",
            "https://chatgpt.com/",
            "i",
            "pv1",
            "t",
            "Home",
            "w",
            1440L,
            "h",
            900L,
            "l",
            "en-GB"),
        Json.object(
            "headers",
            Json.object(
                "x-vercel-ip-country",
                "GB",
                "x-vercel-ip-country-region",
                "ENG",
                "x-vercel-ip-city",
                "London")));
    t.advance(20_000);
    t.send(
        Json.object(
            "k", "engagement", "u", "https://example.com/", "i", "pv1", "e", 18_000L, "d", 75L));
    t.send(
        Json.object(
            "k",
            "pageview",
            "u",
            "https://example.com/pricing",
            "r",
            "https://example.com/",
            "i",
            "pv2",
            "w",
            1440L,
            "h",
            900L));
    t.advance(5_000);
    t.send(
        Json.object(
            "k",
            "event",
            "u",
            "https://example.com/pricing",
            "i",
            "pv2",
            "n",
            "Signup",
            "p",
            Json.object("plan", "pro")));

    // A second visitor on a phone who bounces.
    Map<String, Object> phone = Json.object("ua", Harness.SAFARI_IPHONE, "ip", "198.51.100.7");
    t.send(
        Json.object(
            "k",
            "pageview",
            "u",
            "https://example.com/blog/post",
            "r",
            "https://news.ycombinator.com/",
            "i",
            "pv3",
            "w",
            390L,
            "h",
            844L),
        phone);
    t.send(
        Json.object(
            "k", "engagement", "u", "https://example.com/blog/post", "i", "pv3", "e", 4_000L),
        phone);

    Map<String, Object> today = t.today();
    Fixtures.assertJson(
        Json.object(
            "visitors",
            2L,
            "visits",
            2L,
            "pageviews",
            3L,
            "viewsPerVisit",
            1.5,
            "bounceRate",
            0.5,
            "visitDuration",
            11_000L),
        t.stats(today));
    assertEquals(
        loose(
            Json.array(
                Json.object(
                    "value",
                    "AI",
                    "visitors",
                    1L,
                    "visits",
                    1L,
                    "pageviews",
                    2L,
                    "bounceRate",
                    0L,
                    "visitDuration",
                    18_000L),
                Json.object(
                    "value",
                    "Social",
                    "visitors",
                    1L,
                    "visits",
                    1L,
                    "pageviews",
                    1L,
                    "bounceRate",
                    1L,
                    "visitDuration",
                    4_000L))),
        loose(t.store().breakdown(today, "channel", 10, 0)));
    assertEquals(List.of("ChatGPT", "Hacker News"), t.values(today, "source"));
    assertEquals(List.of("GB"), t.values(today, "country"));
    assertEquals(List.of("GB-ENG"), t.values(today, "region"));
    assertEquals(List.of("desktop", "mobile"), sorted(t.values(today, "device")));
    assertEquals(List.of("1440x900", "390x844"), sorted(t.values(today, "screen")));
    assertEquals(
        loose(Json.array(Json.object("value", "Signup", "visitors", 1L, "events", 1L))),
        loose(t.store().breakdown(today, "event", 10, 0)));
    Map<String, Object> home = null;
    for (Map<String, Object> p : t.store().breakdown(today, "page", 10, 0)) {
      if ("/".equals(p.get("value"))) {
        home = p;
        break;
      }
    }
    assertEquals(
        loose(
            Json.object(
                "value",
                "/",
                "visitors",
                1L,
                "pageviews",
                1L,
                "timeOnPage",
                18_000L,
                "scrollDepth",
                75L)),
        loose(home));
    Object props =
        Json.parse(
            Js.string(
                t.store()
                    .db()
                    .all("SELECT props FROM rl_events WHERE kind = 'event'")
                    .get(0)
                    .get("props")));
    Fixtures.assertJson(Json.object("plan", "pro"), props);

    Map<String, Object> live = t.store().realtime("default", t.now);
    assertEquals(2L, Js.asLong(live.get("visitors")));
    assertEquals(4, Js.list(live.get("recent")).size(), "three pageviews and an event");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void thirtyIdleMinutesStartANewSessionAndANewDayIsANewVisitor(String kind) {
    Harness t = new Harness(kind);
    t.send(pageview("https://example.com/", "a1"));
    t.advance(29 * MIN);
    t.send(pageview("https://example.com/a", "a2"));
    t.advance(31 * MIN);
    t.send(pageview("https://example.com/b", "a3"));
    Map<String, Object> stats = t.stats(t.today());
    assertEquals(2L, stats.get("visits"));
    assertEquals(1L, stats.get("visitors"));

    t.advance(24 * 60 * MIN);
    t.send(pageview("https://example.com/", "a4"));
    assertEquals(
        2L,
        t.stats(t.query("2026-10-01", "2026-10-07")).get("visitors"),
        "the same person on another day is counted again");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aSessionThatRunsPastMidnightUtcStaysOneSession(String kind) {
    Harness t = new Harness(kind);
    t.advance(11 * 60 * MIN + 50 * MIN);
    t.send(pageview("https://example.com/", "m1"));
    t.advance(20 * MIN);
    t.send(pageview("https://example.com/next", "m2"));
    Map<String, Object> stats = t.stats(t.query("2026-10-01", "2026-10-07"));
    assertEquals(1L, stats.get("visits"));
    assertEquals(2L, stats.get("pageviews"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aSaltIsDeletedOnceItsDayHasEndedEverywhere(String kind) {
    Harness t = new Harness(kind);
    t.send(pageview("https://example.com/", "s1"));
    for (int i = 0; i < 3; i++) {
      t.advance(24 * 60 * MIN);
      t.send(pageview("https://example.com/", "s" + (i + 2)));
    }
    t.rl.check();
    // October 9th at noon UTC: the earliest timezone is on the 8th and still needs the 7th.
    List<String> days = new ArrayList<>();
    for (Map<String, Object> r : t.store().db().all("SELECT day FROM rl_salts ORDER BY day")) {
      days.add(Js.string(r.get("day")));
    }
    assertEquals(List.of("2026-10-07", "2026-10-08", "2026-10-09"), days);
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aVisitorIsOneVisitorForTheWholeOfTheSitesOwnDay(String kind) {
    // Toronto: 11pm on the 6th and 1am on the 7th UTC are both the evening of October 6th.
    Harness t =
        new Harness(kind, new Runlight.Options().site(Json.object("timezone", "America/Toronto")));
    t.advance(11 * 60 * MIN);
    t.send(pageview("https://example.com/", "t1"));
    t.advance(2 * 60 * MIN);
    t.send(pageview("https://example.com/later", "t2"));
    Map<String, Object> stats = t.stats(t.query("2026-10-06", "2026-10-06"));
    assertEquals(2L, stats.get("visits"), "two hours apart is two visits");
    assertEquals(1L, stats.get("visitors"), "but one visitor, since it is the same day in Toronto");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void nothingIdentifyingIsStored(String kind) {
    Harness t = new Harness(kind);
    t.sendFrom(
        pageview("https://example.com/?email=jane@example.org&utm_campaign=x", "p1"), "192.0.2.55");
    String dump =
        Json.stringify(
            List.of(
                t.store().db().all("SELECT * FROM rl_sessions"),
                t.store().db().all("SELECT * FROM rl_events")));
    assertFalse(dump.contains("192.0.2.55"), "no IP");
    assertFalse(dump.contains("jane@example.org"), "no query string");
    assertFalse(dump.contains("AppleWebKit"), "no user agent");
  }

  private static Request post(String body, String... headers) {
    return new Request("https://example.com/runlight/e", "POST", Headers.of(headers), body);
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void botsAiAgentsJunkAndOtherSitesAreDroppedQuietly(String kind) {
    Harness t =
        new Harness(
            kind, new Runlight.Options().site(Json.object("hostnames", List.of("example.com"))));
    t.send(
        pageview("https://example.com/", "b1"),
        Json.object(
            "ua", "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"));
    t.send(
        pageview("https://example.com/", "b2"),
        Json.object(
            "ua", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2)"));
    t.send(pageview("https://elsewhere.net/", "b3"));
    t.send(Json.object("k", "pageview", "u", "javascript:alert(1)"));
    t.send(Json.object("k", "nonsense", "u", "https://example.com/"));
    t.send(Json.object("k", "event", "u", "https://example.com/"));
    t.rl.collect(post("{not json", "user-agent", Harness.CHROME_MAC));
    // Too long, whatever the length header says.
    t.rl.collect(
        post(
            Json.stringify(
                Json.object("k", "pageview", "u", "https://example.com/", "t", "x".repeat(9000))),
            "user-agent",
            Harness.CHROME_MAC));
    t.rl.collect(
        post(
            Json.stringify(Json.object("k", "pageview", "u", "https://example.com/")),
            "user-agent",
            Harness.CHROME_MAC,
            "content-length",
            "99999"));
    assertEquals(0L, t.stats(t.today()).get("pageviews"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aiAgentsAreRecordedAsFetchesByObserve(String kind) {
    Harness t = new Harness(kind);
    BiPredicate fetch =
        (path, ua) ->
            t.rl.observe(
                new Request(
                    "https://example.com" + path,
                    "GET",
                    Headers.of("user-agent", ua, "host", "example.com"),
                    ""));
    assertTrue(
        fetch.test(
            "/blog/post",
            "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ChatGPT-User/1.0; +https://openai.com/bot"));
    assertTrue(
        fetch.test(
            "/blog/post",
            "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)"));
    assertFalse(
        fetch.test(
            "/logo.png",
            "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)"));
    assertFalse(fetch.test("/", Harness.CHROME_MAC));
    Map<String, Object> today = t.today();
    assertEquals(
        loose(
            Json.array(
                Json.object("value", "ChatGPT-User", "visitors", 0L, "fetches", 1L),
                Json.object("value", "ClaudeBot", "visitors", 0L, "fetches", 1L))),
        loose(t.store().breakdown(today, "ai_agent", 10, 0)));
    assertEquals(
        loose(Json.array(Json.object("value", "/blog/post", "visitors", 0L, "fetches", 2L))),
        loose(t.store().breakdown(today, "ai_page", 10, 0)));
    assertEquals(0L, t.stats(today).get("visitors"), "fetches are not visits");
    // A log reader's time: older than a week is dropped, ahead of now counts as now.
    String ua = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)";
    assertFalse(
        t.rl.observe(
            new Request("https://example.com/old", "GET", Headers.of("user-agent", ua), ""),
            (double) (t.now - 8 * DAY)));
    assertTrue(
        t.rl.observe(
            new Request("https://example.com/later", "GET", Headers.of("user-agent", ua), ""),
            (double) (t.now + DAY)));
    assertEquals(
        t.now,
        Js.asLong(
            t.store().db().all("SELECT ts FROM rl_events WHERE path = '/later'").get(0).get("ts")));
  }

  private interface BiPredicate {
    boolean test(String path, String ua);
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void severalSitesInOneInstallToldApartByHostname(String kind) {
    Harness t =
        new Harness(
            kind,
            new Runlight.Options()
                .sites(
                    List.of(
                        Json.object("id", "brand-a", "hostnames", List.of("brand-a.com")),
                        Json.object(
                            "id",
                            "brand-b",
                            "hostnames",
                            List.of("brand-b.com"),
                            "timezone",
                            "America/Toronto"))));
    t.send(pageview("https://www.brand-a.com/", "x1"));
    t.send(pageview("https://brand-b.com/", "x2"));
    t.send(pageview("https://brand-b.com/two", "x3"));
    assertEquals(1L, t.stats(t.today("brand-a")).get("pageviews"));
    assertEquals(2L, t.stats(t.today("brand-b")).get("pageviews"));
    assertEquals(2, t.rl.sites().size());
    assertNull(t.rl.site("brand-c"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aVisitorsPageviewAndEventsMakeOneSession(String kind) {
    Harness t = new Harness(kind);
    t.send(pageview("https://example.com/", "p1"));
    t.send(Json.object("k", "event", "u", "https://example.com/", "n", "Signup", "i", "p1"));
    t.send(Json.object("k", "event", "u", "https://example.com/", "n", "Clicked"));
    Map<String, Object> stats = t.stats(t.today());
    assertEquals(1L, stats.get("visits"));
    assertEquals(1L, stats.get("visitors"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aManagedInstallCountsTheFirstHitItGetsBeforeAnythingElseHasLoadedItsSites(String kind) {
    SqlStore store = Databases.fresh(kind);
    Runlight first = new Runlight(new Runlight.Options().store(store).managedSites(true));
    first.addSite(Json.object("hostnames", "blog.example.com"));
    Runlight cold =
        new Runlight(
            new Runlight.Options().store(store).managedSites(true).now(() -> Harness.START));
    cold.collect(
        Harness.hit(
            "https://stats.example.com/runlight/e",
            Json.object("k", "pageview", "u", "https://blog.example.com/"),
            Json.object("ip", "203.0.113.4")));
    assertEquals(
        1L,
        Js.asLong(
            store
                .db()
                .all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'")
                .get(0)
                .get("n")));
  }

  @Test
  void aRegionNameFromALocationDatabaseIsKeptReadableAndACodeStaysACode() {
    Map<String, Map<String, Object>> names =
        Map.of(
            "203.0.113.1", Json.object("country", "ca", "region", "Ontario", "city", "Toronto"),
            "203.0.113.2", Json.object("country", "GB", "region", "ENG", "city", "London"));
    Harness t = new Harness("sqlite", new Runlight.Options().geo(names::get));
    for (String ip : names.keySet()) {
      t.rl.collect(
          Harness.hit(
              "https://x.com/runlight/e",
              Json.object("k", "pageview", "u", "https://x.com/"),
              Json.object(
                  "ua", "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "ip", ip)));
    }
    assertEquals(List.of("CA-Ontario", "GB-ENG"), sorted(t.values(t.today(), "region")));
  }

  @Test
  void trackerRequestsOverThePerAddressLimitAreDroppedUntilTheNextMinute() {
    Harness t =
        new Harness(
            "sqlite",
            new Runlight.Options()
                .site(Json.object("hostnames", List.of("example.com")))
                .rateLimit(3L));
    // Counts are kept per minute window, so the window must be one no other test used.
    ThreadLocalRandom random = ThreadLocalRandom.current();
    t.now = utc(2026, 10, 6, 12) + random.nextLong(1, 1_000_001) * 60_000L;
    BiConsumer<String, Integer> hit =
        (ip, n) ->
            t.rl.collect(
                Harness.hit(
                    "https://example.com/runlight/e",
                    Json.object("k", "pageview", "u", "https://example.com/" + n),
                    Json.object(
                        "ua", "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "ip", ip)));
    String ip = "203.0.113." + random.nextInt(1, 251);
    for (int n = 0; n < 5; n++) {
      hit.accept(ip, n);
    }
    hit.accept("198.51.100." + random.nextInt(1, 251), 9);
    LongSupplier views =
        () -> t.count("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'");
    assertEquals(4, views.getAsLong(), "three from the busy address, one from the other");
    t.advance(60_000);
    hit.accept(ip, 7);
    assertEquals(5, views.getAsLong(), "a new minute starts a new count");
  }

  @Test
  void aTrackerHitThatFindsTheDatabaseBusyIsTriedAgainAtTheTimeItArrived() {
    WatchedDb watched = new WatchedDb(Databases.fresh("sqlite").db());
    Harness t =
        new Harness(
            new SqlStore(watched),
            new Runlight.Options()
                .site(Json.object("hostnames", List.of("example.com"), "timezone", "UTC")));
    t.rl.init();
    AtomicInteger refused = new AtomicInteger();
    Consumer<String> busy =
        sql -> {
          if (refused.get() < 2 && sql.contains("FROM rl_sessions WHERE site = ? AND visitor IN")) {
            refused.incrementAndGet();
            throw new IllegalStateException("timeout exceeded when trying to connect");
          }
        };
    watched.before = busy;
    long arrived = t.now;
    t.send(pageview("https://example.com/", "busy"));
    watched.before = null;
    assertEquals(2, refused.get());
    assertEquals(1L, t.stats(t.today()).get("pageviews"));
    assertEquals(
        arrived, Js.asLong(t.store().db().all("SELECT ts FROM rl_events").get(0).get("ts")));
  }

  @Test
  void aLocalTestCountsWhileASiteIsBeingSetUpAndLocalTrafficIsIgnoredAfterItsFirstVisit() {
    Harness t =
        new Harness(
            "sqlite",
            new Runlight.Options().site(Json.object("hostnames", List.of("example.com"))));
    Consumer<String> hit =
        url ->
            t.rl.collect(
                Harness.hit(
                    "https://x.com/runlight/e",
                    Json.object("k", "pageview", "u", url),
                    Json.object("ip", "203.0.113.5")));
    LongSupplier views = () -> Js.asLong(t.stats(t.today()).get("pageviews"));
    hit.accept("http://localhost:3000/");
    assertEquals(1, views.getAsLong(), "the first local test shows up");
    hit.accept("http://localhost:3000/again");
    hit.accept("http://myapp.test/");
    assertEquals(1, views.getAsLong(), "after that, local hits are ignored");
    hit.accept("https://example.com/");
    assertEquals(2, views.getAsLong());
  }

  private static Request from(String... headers) {
    return new Request(
        "https://example.com/", "GET", Headers.of(headers), new byte[0], "192.0.2.9");
  }

  @Test
  void theClientAddressComesFromTheHeaderTrustedOrTheConnection() {
    SqlStore store = Stores.sqlite(":memory:");
    Runlight byDefault = new Runlight(new Runlight.Options().store(store));
    assertEquals(
        "198.51.100.2",
        byDefault.clientIp(from("x-forwarded-for", "203.0.113.1, 198.51.100.2")),
        "the last entry, which the nearest proxy wrote");
    assertEquals("203.0.113.3", byDefault.clientIp(from("x-real-ip", "203.0.113.3")));
    assertEquals("203.0.113.4", byDefault.clientIp(from("cf-connecting-ip", "203.0.113.4")));
    assertEquals("192.0.2.9", byDefault.clientIp(from()), "the connection, with no header");
    assertEquals(
        "192.0.2.1",
        byDefault.clientIp(from(), Json.object("ip", "192.0.2.1")),
        "the context names the connection");
    Runlight off = new Runlight(new Runlight.Options().store(store).trustProxy(false));
    assertEquals("192.0.2.9", off.clientIp(from("x-forwarded-for", "203.0.113.1")));
    Runlight cf = new Runlight(new Runlight.Options().store(store).trustProxy("cf-connecting-ip"));
    assertEquals(
        "203.0.113.4",
        cf.clientIp(from("x-forwarded-for", "203.0.113.1", "cf-connecting-ip", "203.0.113.4")));
    assertEquals("192.0.2.9", cf.clientIp(from("x-forwarded-for", "203.0.113.1")));
  }

  @Test
  void optionsAreCheckedAsTsChecksThem() {
    SqlStore store = Stores.sqlite(":memory:");
    List<Object[]> cases =
        List.of(
            new Object[] {
              new Runlight.Options().site(Json.object("timezone", "Mars/Base")), "unknown timezone"
            },
            new Object[] {
              new Runlight.Options().site(Json.object("id", "has space")), "must be letters"
            },
            new Object[] {
              new Runlight.Options()
                  .sites(
                      List.of(
                          Json.object("id", "a", "hostnames", List.of("a.com")),
                          Json.object("id", "b"))),
              "give each one its hostnames"
            },
            new Object[] {
              new Runlight.Options()
                  .sites(
                      List.of(
                          Json.object("id", "a", "hostnames", List.of("a.com")),
                          Json.object("id", "a", "hostnames", List.of("b.com")))),
              "share an id"
            });
    for (Object[] c : cases) {
      Runlight.Options options = ((Runlight.Options) c[0]).store(store);
      IllegalArgumentException e =
          assertThrows(IllegalArgumentException.class, () -> new Runlight(options), (String) c[1]);
      assertTrue(e.getMessage().contains((String) c[1]), e.getMessage());
    }
    Runlight rl =
        new Runlight(
            new Runlight.Options()
                .store(store)
                .site(Json.object("hostnames", List.of("www.Example.com")))
                .linkPath("//links/"));
    assertEquals("/links", rl.linkPath);
    Fixtures.assertJson(
        List.of(
            Json.object(
                "id",
                "default",
                "name",
                "www.Example.com",
                "hostnames",
                List.of("example.com"),
                "timezone",
                "UTC")),
        rl.sites());
  }
}
