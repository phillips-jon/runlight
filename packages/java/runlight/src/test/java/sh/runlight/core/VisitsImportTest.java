package sh.runlight.core;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.core.CheckTest.loose;
import static sh.runlight.core.Harness.at;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.Time;
import sh.runlight.importers.FakeService;
import sh.runlight.importers.Visits;
import sh.runlight.store.Databases;

/**
 * Visit history from Umami and from CSV files where it meets the core: Runlight's own first visit,
 * and days the scheduled check builds between import steps, as visits-import*.test.ts and
 * visits-csv.test.ts test them. The rest is in sh.runlight.importers.VisitsImportTest.
 */
class VisitsImportTest {
  private static final Map<String, String> CREDENTIALS =
      Map.of("url", "https://umami.example.com", "apiKey", "key");

  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void tearDown() {
    Databases.cleanup();
  }

  /** A small Umami: one website, events answered by time window like the real API, newest first. */
  private static FakeService umami(List<Map<String, Object>> events, String created) {
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
              long from = Long.parseLong(u.searchParams().get("startAt"));
              long to = Long.parseLong(u.searchParams().get("endAt"));
              List<Object> rows = new ArrayList<>();
              for (Map<String, Object> e : events) {
                long t = at((String) e.get("createdAt"));
                if (t >= from && t <= to) {
                  rows.add(e);
                }
              }
              Collections.reverse(rows);
              return Json.object("data", rows, "count", (long) rows.size());
            })
        .route("/api/websites/w1/sessions\\?", Json.object("data", List.of(), "count", 0L));
  }

  private static Map<String, Object> ev(String session, String iso, String path) {
    return Json.object(
        "sessionId",
        session,
        "createdAt",
        Time.isoString(at(iso)),
        "hostname",
        "blog.example.com",
        "urlPath",
        path,
        "eventType",
        1L);
  }

  private static Harness harness(String kind, FakeService router, long now) {
    Harness t =
        new Harness(
            kind,
            new Runlight.Options()
                .site(Json.object("hostnames", List.of("blog.example.com"), "timezone", "UTC"))
                .fetcher(router));
    t.now = now;
    return t;
  }

  private static long importAll(Harness t) {
    String cursor = null;
    long pageviews = 0;
    do {
      Map<String, Object> step =
          Visits.importUmamiVisits(t.rl, "default", CREDENTIALS, "w1", cursor);
      cursor = (String) step.get("cursor");
      pageviews += Js.asLong(step.get("pageviews"));
      assertTrue(Js.asDouble(step.get("done")) <= Js.asDouble(step.get("total")));
    } while (cursor != null);
    return pageviews;
  }

  private static void ownFirstVisit(Harness t) {
    t.rl.collect(
        Harness.hit(
            "https://x.com/runlight/e",
            Json.object("k", "pageview", "u", "https://blog.example.com/"),
            Json.object("ip", "203.0.113.9")));
  }

  @Test
  void umamiVisitHistoryStopsWhereRunlightsOwnVisitsBegin() {
    List<Map<String, Object>> events =
        List.of(
            ev("s1", "2026-03-01T10:00:00Z", "/"),
            ev("s1", "2026-03-01T10:02:00Z", "/pricing"),
            ev("s1", "2026-03-01T12:30:00Z", "/blog"),
            ev("s2", "2026-03-02T09:00:00Z", "/"));
    Harness t =
        harness("sqlite", umami(events, "2026-03-01T08:00:00Z"), at("2026-03-01T23:00:00Z"));
    // Runlight started counting on the evening of March 1st.
    ownFirstVisit(t);
    assertEquals(3, importAll(t), "March 2nd is left to Runlight");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aVisitThatCrossesIntoTheNextImportStepHasItsFirstDayBuiltAgain(String kind) {
    List<Map<String, Object>> events =
        List.of(
            ev("s0", "2026-03-02T10:00:00Z", "/"),
            ev("s1", "2026-03-14T23:50:00Z", "/a"),
            ev("s1", "2026-03-15T00:10:00Z", "/b"),
            ev("s2", "2026-03-20T10:00:00Z", "/"));
    Harness t =
        harness(kind, umami(events, "2026-03-01T00:00:00.000Z"), at("2026-03-25T12:00:00Z"));
    String cursor =
        (String) Visits.importUmamiVisits(t.rl, "default", CREDENTIALS, "w1", null).get("cursor");
    // The scheduled check builds days between two steps.
    while (t.rl.buildRollups() > 0) {
      // Build them all.
    }
    while (cursor != null) {
      cursor =
          (String)
              Visits.importUmamiVisits(t.rl, "default", CREDENTIALS, "w1", cursor).get("cursor");
    }
    while (t.rl.buildRollups() > 0) {
      // Build them all.
    }
    Map<String, Object> q = t.query("2026-03-14", "2026-03-14");
    Supplier<Object> read =
        () -> {
          List<Object> pages = new ArrayList<>();
          for (Map<String, Object> r : t.store().breakdown(q, "page", 10, 0)) {
            pages.add(List.of(r.get("value"), r.get("pageviews")));
          }
          return loose(Json.object("stats", t.stats(q), "pages", pages));
        };
    Object rolled = read.get();
    t.store().clearRollups("default");
    assertEquals(read.get(), rolled);
    assertEquals(2L, Js.get(Js.get(rolled, "stats"), "pageviews"));
  }

  @Test
  void csvRowsFromAfterRunlightsOwnFirstVisitAreLeftToRunlight() {
    Harness t = harness("sqlite", new FakeService(), at("2026-03-01T23:00:00Z"));
    ownFirstVisit(t);
    List<Object> rows =
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
                "desktop"));
    Map<String, Object> step = Visits.importCsvVisits(t.rl, "default", rows);
    assertEquals(2L, step.get("pageviews"), "March 2nd is left to Runlight");
    assertEquals(1L, step.get("skipped"));
  }
}
