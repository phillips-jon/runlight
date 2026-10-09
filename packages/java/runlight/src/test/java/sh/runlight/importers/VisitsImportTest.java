package sh.runlight.importers;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Consumer;
import java.util.function.Function;
import java.util.stream.Stream;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Time;
import sh.runlight.db.Db;
import sh.runlight.http.SearchParams;
import sh.runlight.store.Databases;
import sh.runlight.store.SqlStore;

/**
 * Visit history from Umami and from CSV files, as visits-import*.test.ts and visits-csv.test.ts
 * test it at the store.
 */
class VisitsImportTest {
  private static final long DAY = TestHost.DAY;
  private static final Map<String, String> CREDENTIALS =
      Map.of("url", "https://umami.example.com", "apiKey", "key");

  static Stream<String> kinds() {
    return Databases.kinds().stream();
  }

  @AfterEach
  void tearDown() {
    Databases.cleanup();
  }

  /** Date.parse of an ISO time. */
  private static long at(String iso) {
    return (long) Http.parseDate(iso);
  }

  /** A small Umami: one website, events answered by time window like the real API, newest first. */
  private static FakeService umami(
      List<Map<String, Object>> events,
      List<Object> sessions,
      String created,
      boolean newestFirst) {
    Function<SearchParams, List<Object>> inside =
        q -> {
          long from = Long.parseLong(q.get("startAt"));
          long to = Long.parseLong(q.get("endAt"));
          List<Object> rows = new ArrayList<>();
          for (Map<String, Object> e : events) {
            long t = at((String) e.get("createdAt"));
            if (t >= from && t <= to) {
              rows.add(e);
            }
          }
          if (newestFirst) {
            Collections.reverse(rows);
          }
          return rows;
        };
    return new FakeService()
        .route(
            "/api/websites\\?",
            Json.object(
                "data",
                Json.array(Json.object("id", "w1", "name", "Blog", "domain", "blog.example.com")),
                "count",
                1L))
        .route("/api/websites/w1$", Json.object("id", "w1", "createdAt", created))
        .route(
            "/api/websites/w1/events\\?",
            (u, init) -> {
              List<Object> rows = inside.apply(u.searchParams());
              return Json.object("data", rows, "count", (long) rows.size());
            })
        .route(
            "/api/websites/w1/sessions\\?",
            Json.object("data", sessions, "count", (long) sessions.size()));
  }

  private static FakeService umami(List<Map<String, Object>> events, List<Object> sessions) {
    return umami(events, sessions, "2026-03-01T08:00:00Z", true);
  }

  private static Map<String, Object> event(Object... fields) {
    Map<String, Object> e = Json.object("hostname", "blog.example.com", "eventType", 1L);
    for (int i = 0; i + 1 < fields.length; i += 2) {
      e.put((String) fields[i], fields[i + 1]);
    }
    return e;
  }

  private static Map<String, Object> visit1(String createdAt, Object... fields) {
    List<Object> all =
        new ArrayList<>(
            List.of(
                "sessionId",
                "s1",
                "createdAt",
                createdAt,
                "country",
                "CA",
                "city",
                "Toronto",
                "device",
                "mobile",
                "os",
                "iOS",
                "browser",
                "ios"));
    all.addAll(List.of(fields));
    return event(all.toArray());
  }

  private static Map<String, Object> visit2(String createdAt, Object... fields) {
    List<Object> all =
        new ArrayList<>(
            List.of(
                "sessionId",
                "s2",
                "createdAt",
                createdAt,
                "country",
                "GB",
                "city",
                "London",
                "device",
                "desktop",
                "os",
                "Mac OS",
                "browser",
                "chrome"));
    all.addAll(List.of(fields));
    return event(all.toArray());
  }

  private static List<Map<String, Object>> fakeEvents() {
    return List.of(
        // Visit 1: Google, two pages and a signup, in Toronto on a phone.
        visit1(
            "2026-03-01T10:00:00.000Z",
            "urlPath",
            "/",
            "urlQuery",
            "utm_campaign=spring",
            "referrerDomain",
            "www.google.com",
            "referrerPath",
            "/",
            "pageTitle",
            "Home"),
        visit1("2026-03-01T10:02:00.000Z", "urlPath", "/pricing", "pageTitle", "Pricing"),
        visit1(
            "2026-03-01T10:03:00.000Z",
            "urlPath",
            "/pricing",
            "eventType",
            2L,
            "eventName",
            "Signup"),
        // The same Umami session two hours later is a second visit.
        visit1("2026-03-01T12:30:00.000Z", "urlPath", "/blog"),
        // Visit 3: direct, desktop, the next day.
        visit2("2026-03-02T09:00:00.000Z", "urlPath", "/"),
        // A performance event is not a visit.
        visit2("2026-03-02T09:00:01.000Z", "urlPath", "/", "eventType", 5L));
  }

  private static final List<Object> SESSIONS =
      Json.array(
          Json.object("id", "s1", "screen", "390x844", "language", "en-CA", "region", "CA-ON"),
          Json.object("id", "s2", "screen", "1440x900", "language", "en-GB", "region", "GB-ENG"));

  private static TestHost harness(SqlStore store, FakeService router, long now, String timezone) {
    return new TestHost(store, router, now, List.of("blog.example.com"), timezone);
  }

  private static TestHost harness(String kind, FakeService router, long now) {
    return harness(Databases.fresh(kind), router, now, "UTC");
  }

  private static long[] importAll(TestHost t, Map<String, String> credentials) {
    String cursor = null;
    long[] totals = {0, 0, 0, 0};
    do {
      Map<String, Object> step = Visits.importUmamiVisits(t, "default", credentials, "w1", cursor);
      cursor = (String) step.get("cursor");
      totals[0] += Js.asLong(step.get("pageviews"));
      totals[1] += Js.asLong(step.get("events"));
      totals[2] += Js.asLong(step.get("visits"));
      totals[3]++;
      assertTrue(Js.asLong(step.get("done")) <= Js.asLong(step.get("total")));
    } while (cursor != null);
    return totals;
  }

  private static long[] importAll(TestHost t) {
    return importAll(t, CREDENTIALS);
  }

  private static List<Object> sorted(List<Object> values) {
    List<Object> out = new ArrayList<>(values);
    out.sort((a, b) -> Js.compare(Js.string(a), Js.string(b)));
    return out;
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void umamiVisitHistoryPageviewsAndEventsBecomeVisitsWithSourcesPlacesAndDevices(String kind) {
    FakeService router = umami(fakeEvents(), SESSIONS);
    assertEquals(
        Json.stringify(
            Json.array(Json.object("id", "w1", "name", "Blog", "domain", "blog.example.com"))),
        Json.stringify(Visits.umamiWebsites(CREDENTIALS, router)));
    TestHost t = harness(kind, router, at("2026-03-04T00:00:00Z"));
    long[] totals = importAll(t);
    assertEquals(List.of(4L, 1L, 3L), List.of(totals[0], totals[1], totals[2]));
    for (FakeService.Sent r : router.requests) {
      assertEquals(
          "Bearer key", FakeService.authorization(r.init()), "every request carries the key");
    }

    Map<String, Object> q = t.query("2026-03-01", "2026-03-03");
    Map<String, Object> stats = t.store.stats(q);
    assertEquals(4L, stats.get("pageviews"));
    assertEquals(3L, stats.get("visits"));
    assertEquals(2L, stats.get("visitors"), "one Umami session on one day is one visitor");
    assertTrue(
        Js.asDouble(stats.get("visitDuration")) > 0,
        "imported visits take their length from first to last pageview");
    assertEquals(List.of("Google"), t.values(q, "source"));
    assertEquals(List.of("CA-ON", "GB-ENG"), sorted(t.values(q, "region")));
    assertEquals(List.of("Chrome", "Safari"), sorted(t.values(q, "browser")));
    assertEquals(List.of("Signup"), t.values(q, "event"));
    assertEquals(List.of("spring"), t.values(q, "utm_campaign"));

    // Running it again carries on from where it stopped, so nothing doubles.
    t.now += DAY;
    Map<String, Object> again = Visits.importUmamiVisits(t, "default", CREDENTIALS, "w1", null);
    assertEquals(0L, again.get("pageviews"));
    assertEquals(4L, t.store.stats(q).get("pageviews"));

    // No imported visitor id lasts past a day.
    Map<String, Set<String>> days = new HashMap<>();
    for (Map<String, Object> r : t.store.db().all("SELECT visitor, ts FROM rl_events")) {
      days.computeIfAbsent(Js.string(r.get("visitor")), k -> new HashSet<>())
          .add(Time.isoString(Js.asLong(r.get("ts"))).substring(0, 10));
    }
    for (Set<String> set : days.values()) {
      assertEquals(1, set.size());
    }
  }

  /** A Db that lets a test step into every statement, as the TS tests replace db.run. */
  private static final class WatchedDb implements Db {
    private final Db inner;
    Consumer<String> before;

    WatchedDb(Db inner) {
      this.inner = inner;
    }

    private void watch(String sql) {
      if (before != null) {
        before.accept(sql);
      }
    }

    @Override
    public String dialect() {
      return inner.dialect();
    }

    @Override
    public List<Map<String, Object>> all(String sql, List<?> params) {
      watch(sql);
      return inner.all(sql, params);
    }

    @Override
    public void run(String sql, List<?> params) {
      watch(sql);
      inner.run(sql, params);
    }

    @Override
    public long affected(String sql, List<?> params) {
      watch(sql);
      return inner.affected(sql, params);
    }

    @Override
    public <T> T transaction(Function<Db, T> fn) {
      return inner.transaction(d -> fn.apply(this));
    }

    @Override
    public <T> T exclusive(Function<Db, T> fn) {
      return inner.exclusive(d -> fn.apply(this));
    }

    @Override
    public void close() {
      inner.close();
    }
  }

  @Test
  void aStepThatFailedPartWayCanRunAgainWithoutCountingAnythingTwice() {
    WatchedDb watched = new WatchedDb(Databases.fresh("sqlite").db());
    TestHost t =
        harness(
            new SqlStore(watched),
            umami(fakeEvents(), SESSIONS),
            at("2026-03-04T00:00:00Z"),
            "UTC");
    t.init();
    int[] writes = {0};
    watched.before =
        sql -> {
          if (sql.startsWith("INSERT INTO rl_events") && ++writes[0] > 2) {
            throw new IllegalStateException("connection lost");
          }
        };
    IllegalStateException e =
        assertThrows(
            IllegalStateException.class,
            () -> Visits.importUmamiVisits(t, "default", CREDENTIALS, "w1", null),
            "the first try fails");
    assertEquals("connection lost", e.getMessage());
    watched.before = null;
    importAll(t);
    Map<String, Object> stats = t.store.stats(t.query("2026-03-01", "2026-03-03"));
    assertEquals(4L, stats.get("pageviews"));
    assertEquals(3L, stats.get("visits"));
    Map<String, Object> totals =
        t.store
            .db()
            .all("SELECT SUM(pageviews) AS pageviews, SUM(events) AS events FROM rl_sessions")
            .get(0);
    assertEquals(
        List.of(4L, 1L),
        List.of(Js.asLong(totals.get("pageviews")), Js.asLong(totals.get("events"))));
  }

  @Test
  void umamiVisitHistorySkipsDaysOlderThanTheSiteKeeps() {
    TestHost t = harness("sqlite", umami(fakeEvents(), SESSIONS), at("2026-09-01T12:00:00Z"));
    // Six months back from September 1st at noon is March 1st at noon, so March 1st is left out.
    // (The Runlight's own retentionCutoff after setRetention(site, 6) is the lead's to test.)
    t.cutoff = at("2026-03-01T12:00:00Z");
    assertEquals(1L, importAll(t)[0], "only March 2nd comes in");
  }

  @Test
  void anImportedVisitAcrossUtcMidnightIsOneVisitOnTheSitesOwnDay() {
    List<Map<String, Object>> events =
        List.of(
            event(
                "sessionId",
                "n1",
                "createdAt",
                "2026-03-02T23:55:00.000Z",
                "urlPath",
                "/",
                "country",
                "CA",
                "device",
                "desktop",
                "os",
                "Mac OS",
                "browser",
                "chrome"),
            event(
                "sessionId",
                "n1",
                "createdAt",
                "2026-03-03T00:05:00.000Z",
                "urlPath",
                "/about",
                "country",
                "CA",
                "device",
                "desktop",
                "os",
                "Mac OS",
                "browser",
                "chrome"));
    TestHost t =
        harness(
            Databases.fresh("sqlite"),
            umami(events, Json.array(Json.object("id", "n1")), "2026-03-02T00:00:00Z", false),
            at("2026-03-10T00:00:00Z"),
            "America/Toronto");
    importAll(t);
    Map<String, Object> stats = t.store.stats(t.query("2026-03-02", "2026-03-02"));
    assertEquals(
        List.of(1L, 1L, 2L),
        List.of(stats.get("visits"), stats.get("visitors"), stats.get("pageviews")));
  }

  private static Map<String, Object> ev(String session, String iso, String path, String name) {
    Map<String, Object> e =
        Json.object(
            "sessionId",
            session,
            "createdAt",
            Time.isoString(at(iso)),
            "hostname",
            "blog.example.com",
            "urlPath",
            path,
            "eventType",
            name != null ? 2L : 1L);
    if (name != null) {
      e.put("eventName", name);
    }
    return e;
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void anImportedVisitThatRunsPastMidnightKeepsOneVisitorOnAllItsRows(String kind) {
    List<Map<String, Object>> events =
        List.of(
            ev("s1", "2026-03-01T23:50:00Z", "/a", null),
            ev("s1", "2026-03-02T00:05:00Z", "/b", null),
            ev("s1", "2026-03-02T00:06:00Z", "/b", "Signup"),
            ev("s1", "2026-03-02T10:00:00Z", "/b", null),
            ev("s1", "2026-03-02T10:01:00Z", "/b", "Signup"));
    TestHost t =
        harness(
            kind,
            umami(events, Json.array(), "2026-03-01T00:00:00.000Z", true),
            at("2026-03-05T12:00:00Z"));
    importAll(t);
    assertEquals(
        List.of(),
        t.store
            .db()
            .all(
                "SELECT e.id FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.visitor <> s.visitor"));
    // The same numbers once the days are built is the lead's to test, with buildRollups.
    Map<String, Object> q = t.query("2026-03-01", "2026-03-02");
    List<Object> signups = new ArrayList<>();
    for (Map<String, Object> r : t.store.breakdown(q, "event", 10, 0)) {
      signups.add(Json.array(r.get("value"), r.get("visitors")));
    }
    assertEquals(Json.stringify(Json.array(Json.array("Signup", 2L))), Json.stringify(signups));
  }

  @Test
  void aStepCursorCarriesASignInTokenButNeverAnApiKey() {
    List<Map<String, Object>> events =
        List.of(
            ev("s0", "2026-03-02T10:00:00Z", "/", null),
            ev("s2", "2026-03-20T10:00:00Z", "/", null));
    FakeService router = umami(events, Json.array(), "2026-03-01T00:00:00.000Z", true);
    TestHost t = harness("sqlite", router, at("2026-03-25T12:00:00Z"));
    Map<String, Object> cursor =
        Js.map(
            Json.parse(
                (String)
                    Visits.importUmamiVisits(t, "default", CREDENTIALS, "w1", null).get("cursor")));
    assertEquals(List.of("website", "day", "start", "end"), Js.keys(cursor));
    assertEquals(at("2026-03-15T00:00:00Z"), Js.asLong(cursor.get("day")), "fourteen days a step");
    ImportError e =
        assertThrows(
            ImportError.class,
            () -> Visits.importUmamiVisits(t, "default", CREDENTIALS, "w/1", null),
            "a bad website id");
    assertEquals("import_website", e.code());

    // Signed in with a password, the token rides in the cursor.
    router.route("/api/auth/login", Json.object("token", "tok"));
    TestHost u = harness("sqlite", router, at("2026-03-25T12:00:00Z"));
    Map<String, Object> signedIn =
        Js.map(
            Json.parse(
                (String)
                    Visits.importUmamiVisits(
                            u,
                            "default",
                            Map.of(
                                "url",
                                "https://umami.example.com",
                                "username",
                                "jon",
                                "password",
                                "pw"),
                            "w1",
                            null)
                        .get("cursor")));
    assertEquals("tok", signedIn.get("token"));
  }

  // CSV

  private static final List<Object> RUNLIGHT_ROWS =
      Json.array(
          Json.object(
              "time",
              "2026-03-01T10:00:00Z",
              "url",
              "https://blog.example.com/?utm_campaign=spring",
              "referrer",
              "www.google.com",
              "visitor",
              "a",
              "country",
              "CA",
              "region",
              "CA-ON",
              "city",
              "Toronto",
              "browser",
              "Safari",
              "os",
              "iOS",
              "device",
              "mobile",
              "title",
              "Home"),
          Json.object(
              "time",
              "2026-03-01T10:02:00Z",
              "url",
              "https://blog.example.com/pricing",
              "visitor",
              "a",
              "country",
              "CA",
              "browser",
              "Safari",
              "os",
              "iOS",
              "device",
              "mobile"),
          Json.object(
              "time",
              "2026-03-01T10:03:00Z",
              "url",
              "https://blog.example.com/pricing",
              "event",
              "Signup",
              "visitor",
              "a"),
          Json.object(
              "time",
              "1772442000",
              "path",
              "/",
              "hostname",
              "blog.example.com",
              "visitor",
              "b",
              "country",
              "GB",
              "browser",
              "Chrome",
              "os",
              "macOS",
              "device",
              "desktop"),
          // Not a time at all.
          Json.object("time", "yesterday", "path", "/x", "visitor", "c"));

  private static TestHost csv() {
    return harness(Databases.fresh("sqlite"), new FakeService(), at("2026-03-04T00:00:00Z"), "UTC");
  }

  private static String counts(Map<String, Object> step) {
    return Json.stringify(step);
  }

  @Test
  void csvInRunlightsFormatRowsBecomeVisitsWithSourcesPlacesDevicesAndEvents() {
    TestHost t = csv();
    assertEquals(
        Json.stringify(Json.object("pageviews", 3L, "events", 1L, "visits", 2L, "skipped", 1L)),
        counts(Visits.importCsvVisits(t, "default", RUNLIGHT_ROWS)));
    Map<String, Object> q = t.query("2026-03-01", "2026-03-03");
    Map<String, Object> stats = t.store.stats(q);
    assertEquals(
        List.of(3L, 2L, 2L),
        List.of(stats.get("pageviews"), stats.get("visits"), stats.get("visitors")));
    assertEquals(List.of("Google"), t.values(q, "source"));
    assertEquals(List.of("spring"), t.values(q, "utm_campaign"));
    assertEquals(List.of("Signup"), t.values(q, "event"));
    assertEquals(List.of("desktop", "mobile"), sorted(t.values(q, "device")));
    assertEquals(List.of("CA-ON"), t.values(q, "region"));

    // The same file again replaces what it brought in, so nothing doubles.
    Visits.importCsvVisits(t, "default", RUNLIGHT_ROWS);
    assertEquals(3L, t.store.stats(q).get("pageviews"));
    assertEquals(2L, t.store.stats(q).get("visits"));
  }

  @Test
  void csvInRunlightsFormatWithoutAVisitorColumnEveryRowIsItsOwnVisit() {
    TestHost t = csv();
    List<Object> rows =
        Json.array(
            Json.object("time", "2026-03-01 10:00:00", "path", "/a"),
            Json.object("time", "2026-03-01 10:01:00", "path", "/b?ref=x"));
    assertEquals(2L, Visits.importCsvVisits(t, "default", rows).get("visits"));
    Visits.importCsvVisits(t, "default", rows);
    Map<String, Object> q = t.query("2026-03-01", "2026-03-03");
    assertEquals(
        2L, t.store.stats(q).get("visits"), "the same rows get the same ids the second time");
    assertEquals(List.of("/a", "/b"), sorted(t.values(q, "page")));
  }

  @Test
  void csvFromUmamisExportPageviewsAndNamedEventsComeAcrossOtherEventTypesDoNot() {
    TestHost t = csv();
    List<Object> rows =
        Json.array(
            Json.object(
                "website_id",
                "w1",
                "session_id",
                "s1",
                "created_at",
                "2026-03-01 10:00:00",
                "hostname",
                "blog.example.com",
                "url_path",
                "/",
                "url_query",
                "",
                "referrer_domain",
                "news.ycombinator.com",
                "page_title",
                "Home",
                "event_type",
                "1",
                "country",
                "CA",
                "subdivision1",
                "ON",
                "city",
                "Toronto",
                "browser",
                "ios",
                "os",
                "iOS",
                "device",
                "mobile",
                "screen",
                "390x844",
                "language",
                "en-CA"),
            Json.object(
                "website_id",
                "w1",
                "session_id",
                "s1",
                "created_at",
                "2026-03-01 10:03:00",
                "hostname",
                "blog.example.com",
                "url_path",
                "/pricing",
                "event_type",
                "2",
                "event_name",
                "Signup"),
            Json.object(
                "website_id",
                "w1",
                "session_id",
                "s1",
                "created_at",
                "2026-03-01 10:03:01",
                "hostname",
                "blog.example.com",
                "url_path",
                "/pricing",
                "event_type",
                "5"),
            Json.object(
                "website_id",
                "w1",
                "session_id",
                "s2",
                "created_at",
                "2026-03-02T09:00:00.000Z",
                "hostname",
                "blog.example.com",
                "url_path",
                "/blog",
                "event_type",
                "1",
                "country",
                "GB",
                "browser",
                "chrome",
                "os",
                "Mac OS",
                "device",
                "desktop"));
    assertEquals(
        Json.stringify(Json.object("pageviews", 2L, "events", 1L, "visits", 2L, "skipped", 1L)),
        counts(Visits.importCsvVisits(t, "default", rows)));
    Map<String, Object> q = t.query("2026-03-01", "2026-03-03");
    assertEquals(List.of("Hacker News"), t.values(q, "source"));
    assertEquals(List.of("CA-ON"), t.values(q, "region"));
    assertEquals(List.of("Chrome", "Safari"), sorted(t.values(q, "browser")));
  }

  @Test
  void aCsvItCannotReadAndABatchThatIsTooBigAreRefused() {
    TestHost t = csv();
    List<Object> big = new ArrayList<>(Collections.nCopies(2001, RUNLIGHT_ROWS.get(0)));
    Object[][] cases = {
      {Json.array(Json.object("date", "2026-03-01", "visitors", "12")), "import_csv_format"},
      {big, "import_csv_batch"},
      {"not rows", "import_csv_batch"},
    };
    for (Object[] c : cases) {
      ImportError e =
          assertThrows(ImportError.class, () -> Visits.importCsvVisits(t, "default", c[0]));
      assertEquals(c[1], e.code());
    }
    assertEquals(2L, Visits.importCsvVisits(t, "default", RUNLIGHT_ROWS).get("visits"));
  }

  @Test
  void csvTimesAndFormats() {
    assertEquals("umami", CsvVisits.csvFormat(List.of("created_at", "url_path", "session_id")));
    assertEquals("runlight", CsvVisits.csvFormat(List.of("time", "url")));
    assertNull(CsvVisits.csvFormat(List.of("date", "visitors")));
    double iso = at("2026-03-01T10:00:00Z");
    assertEquals(
        iso,
        CsvVisits.rowTime(Map.of("time", "2026-03-01 10:00:00"), "runlight"),
        "no zone reads as UTC");
    assertEquals(iso, CsvVisits.rowTime(Map.of("time", "2026-03-01T12:00:00+02:00"), "runlight"));
    assertEquals(
        iso,
        CsvVisits.rowTime(Map.of("time", Long.toString((long) iso / 1000)), "runlight"),
        "Unix seconds");
    assertEquals(
        iso,
        CsvVisits.rowTime(Map.of("time", Long.toString((long) iso)), "runlight"),
        "Unix milliseconds");
    assertEquals(iso, CsvVisits.rowTime(Map.of("created_at", "2026-03-01 10:00:00"), "umami"));
    assertTrue(Double.isNaN(CsvVisits.rowTime(Map.of("time", ""), "runlight")));
    assertTrue(Double.isNaN(CsvVisits.rowTime(Map.of("time", "yesterday"), "runlight")));
  }
}
