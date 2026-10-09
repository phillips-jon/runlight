package sh.runlight.core;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.core.Harness.DAY;
import static sh.runlight.core.Harness.HOUR;
import static sh.runlight.core.Harness.utc;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.store.Databases;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * The scheduled check and the rollups it builds, as rollups.test.ts and hardening.test.ts test the
 * process around the store.
 */
class CheckTest {
  private static final List<String> PAGES =
      List.of("/", "/blog/one", "/blog/two", "/pricing", "/about");
  private static final List<String> REFERRERS =
      List.of(
          "https://www.google.com/",
          "https://news.ycombinator.com/",
          "",
          "https://chatgpt.com/",
          "https://t.co/x");
  private static final List<String> COUNTRIES = List.of("GB", "US", "DE", "CA");

  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void tearDown() {
    Databases.cleanup();
  }

  /** A value with its numbers as JSON writes them, so 0 and 0.0 compare equal, as assertEquals. */
  static Object loose(Object value) {
    return Json.parse(Json.stringify(value));
  }

  static Runlight.Options site(String timezone) {
    return new Runlight.Options()
        .site(Json.object("hostnames", List.of("example.com"), "timezone", timezone));
  }

  /** Every report this test compares before and after the days are built. */
  private static Map<String, Object> everything(Harness t) {
    Map<String, Object> out = new LinkedHashMap<>();
    Map<String, Map<String, Object>> ranges = new LinkedHashMap<>();
    ranges.put("7d", t.query("2026-09-30", "2026-10-06"));
    ranges.put("30d", t.query("2026-09-07", "2026-10-06"));
    ranges.put("some", t.query("2026-09-29", "2026-10-03"));
    ranges.put("all", t.all());
    for (Map.Entry<String, Map<String, Object>> range : ranges.entrySet()) {
      String name = range.getKey();
      Map<String, Object> q = range.getValue();
      out.put("stats " + name, t.stats(q));
      out.put("hourly " + name, t.store().hourly(q));
      for (String dimension :
          List.of(
              "page",
              "event",
              "entry",
              "exit",
              "source",
              "channel",
              "referrer",
              "country",
              "browser",
              "device",
              "os")) {
        out.put(dimension + " " + name, t.store().breakdown(q, dimension, 3, 0));
        out.put(dimension + " " + name + " page 2", t.store().breakdown(q, dimension, 3, 3));
      }
    }
    out.put(
        "filtered",
        t.stats(
            t.query(
                "2026-09-07",
                "2026-10-06",
                null,
                Json.array(Json.object("dimension", "country", "op", "is", "value", "GB")))));
    return out;
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void reportsReadFromDailyRollupsMatchReportsReadFromEveryVisit(String kind) {
    // Toronto, so local days and UTC days differ, starting ten days back.
    Harness t = new Harness(kind, site("America/Toronto"));
    long start = t.now;
    t.advance(-10 * 24 * HOUR);
    int n = 0;
    for (int day = 0; day < 10; day++) {
      for (int v = 0; v < 6; v++) {
        n++;
        Map<String, Object> init =
            Json.object(
                "ip",
                "203.0.113." + (n % 40),
                "headers",
                Json.object("x-vercel-ip-country", COUNTRIES.get(n % 4)));
        if (n % 3 == 0) {
          init.put("ua", Harness.SAFARI_IPHONE);
        }
        for (int p = 0; p < 1 + (n % 3); p++) {
          String id = "pv" + n + "x" + p;
          t.send(
              Json.object(
                  "k",
                  "pageview",
                  "u",
                  "https://example.com" + PAGES.get((n + p) % 5),
                  "r",
                  p == 0 ? REFERRERS.get(n % 5) : "",
                  "i",
                  id),
              init);
          t.advance(20_000 + (n % 5) * 7_000L);
          if (n % 2 == 0) {
            t.send(
                Json.object(
                    "k",
                    "engagement",
                    "u",
                    "https://example.com/",
                    "i",
                    id,
                    "e",
                    9_000L + n * 100L,
                    "d",
                    40L + (n % 60)),
                init);
          }
          if (n % 4 == 0) {
            t.send(
                Json.object("k", "event", "u", "https://example.com/", "i", id, "n", "Signup"),
                init);
          }
        }
        t.advance(3 * HOUR + (n % 7) * 60_000L);
      }
      // A visit that runs past midnight: it belongs to the day it started.
      t.advance(24 * HOUR - 6 * (3 * HOUR) - 30 * 60_000L);
    }
    t.advance(start - t.now + 2 * HOUR);

    Object before = loose(everything(t));
    int built = 0;
    for (int made = t.rl.buildRollups(); made > 0; made = t.rl.buildRollups()) {
      built += made;
    }
    assertTrue(built >= 8);
    assertEquals(0, t.rl.buildRollups(), "a built day is not built again");
    assertEquals(before, loose(everything(t)));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aLateEventAndEngagementOnAnOldPageviewAreCountedOnceTheDayIsBuiltAgain(String kind) {
    Harness t = new Harness(kind, site("UTC"));
    // Evening of October 5th, then rollups built the next morning.
    t.now = utc(2026, 10, 5, 20);
    t.sendFrom(
        Json.object("k", "pageview", "u", "https://example.com/", "i", "late1"), "203.0.113.50");
    t.advance(7 * HOUR);
    assertTrue(t.rl.buildRollups() >= 1);
    // The tab was left open overnight: its event and engagement arrive now.
    t.sendFrom(
        Json.object("k", "event", "u", "https://example.com/", "i", "late1", "n", "Signup"),
        "203.0.113.50");
    t.sendFrom(
        Json.object(
            "k", "engagement", "u", "https://example.com/", "i", "late1", "e", 60_000L, "d", 80L),
        "203.0.113.50");
    Map<String, Object> q = t.query("2026-10-05", "2026-10-05");
    Supplier<Map<String, Object>> read =
        () ->
            Json.object(
                "stats",
                t.stats(q),
                "events",
                t.store().breakdown(q, "event", 10, 0),
                "pages",
                t.store().breakdown(q, "page", 10, 0));
    t.rl.buildRollups();
    Map<String, Object> rolled = read.get();
    t.store().clearRollups("default");
    Map<String, Object> raw = read.get();
    assertEquals(loose(raw), loose(rolled));
    assertEquals(
        0.0,
        Js.asDouble(Js.map(raw.get("stats")).get("bounceRate")),
        "the event means the visit did not bounce");
    List<Object> events = new ArrayList<>();
    for (Object e : Js.list(raw.get("events"))) {
      events.add(Js.get(e, "value"));
    }
    assertEquals(List.of("Signup"), events);
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void afterATimezoneChangeOnlyDaysAfterItAreBuilt(String kind) {
    Harness t = new Harness(kind, site("UTC"));
    t.rl.init();
    t.now = utc(2026, 10, 3, 10);
    t.sendFrom(
        Json.object("k", "pageview", "u", "https://example.com/", "r", "", "i", "a1"),
        "203.0.113.1");
    t.advance(10 * HOUR);
    t.sendFrom(
        Json.object("k", "pageview", "u", "https://example.com/", "r", "", "i", "a2"),
        "203.0.113.1");
    t.now = utc(2026, 10, 4, 12);
    t.sendFrom(
        Json.object("k", "pageview", "u", "https://example.com/", "r", "", "i", "b1"),
        "203.0.113.2");
    t.now = utc(2026, 10, 6, 12);
    assertTrue(t.rl.buildRollups() >= 2);

    t.rl.updateSite("default", Json.object("timezone", "Asia/Tokyo"));
    Map<String, Object> q = t.query("2026-10-03", "2026-10-05");
    Map<String, Object> before = t.stats(q);
    assertEquals(0, t.rl.buildRollups(), "days before the change stay counted visit by visit");
    Fixtures.assertJson(before, t.stats(q));
    assertEquals(2L, before.get("visitors"));
    // A day that starts after the change is built as usual.
    t.advance(3 * 24 * HOUR);
    assertTrue(t.rl.buildRollups() >= 1);
  }

  private static long builtDays(Runlight rl) {
    return Js.asLong(rl.store.db().all("SELECT COUNT(*) AS n FROM rl_rollup_days").get(0).get("n"));
  }

  private static Runlight onFile(Path file, String timezone, LongSupplier clock) {
    return new Runlight(site(timezone).store(Stores.sqlite(file.toString())).now(clock));
  }

  @Test
  void twoProcessesOnOneDatabaseAStaleTimezoneBuildsNothingAndClearsNothing() throws IOException {
    Path file = Files.createTempFile("runlight-zones-", "");
    try {
      AtomicLong now = new AtomicLong(utc(2026, 10, 3, 12));
      Runlight old = onFile(file, "UTC", now::get);
      old.init();
      old.collect(
          Harness.hit(
              "https://example.com/runlight/e",
              Json.object("k", "pageview", "u", "https://example.com/"),
              Json.object("ip", "203.0.113.1", "ua", Harness.SAFARI_IPHONE)));
      now.set(utc(2026, 10, 6, 12));
      assertTrue(old.buildRollups() >= 2, "the old process builds in UTC");

      // A new copy starts with the timezone changed in code: it clears the old days once, at
      // startup.
      Runlight fresh = onFile(file, "Asia/Tokyo", now::get);
      fresh.init();
      assertEquals(0, builtDays(old));
      // The old copy, still running, neither builds in UTC nor clears what the new one does.
      now.addAndGet(3 * DAY);
      assertEquals(0, old.buildRollups());
      assertTrue(fresh.buildRollups() >= 1);
      long afterFresh = builtDays(old);
      assertEquals(0, old.buildRollups());
      assertEquals(afterFresh, builtDays(old), "nothing cleared by the stale copy");
      old.store.close();
      fresh.store.close();
    } finally {
      Files.deleteIfExists(file);
    }
  }

  @Test
  void aTimezoneChangedInTheDashboardReachesAnotherProcessAtItsNextCheck() throws IOException {
    Path file = Files.createTempFile("runlight-zones-", "");
    try {
      AtomicLong now = new AtomicLong(utc(2026, 10, 6, 12));
      Runlight a = onFile(file, "UTC", now::get);
      Runlight b = onFile(file, "UTC", now::get);
      a.init();
      b.init();
      a.updateSite("default", Json.object("timezone", "Europe/Paris"));
      assertEquals("UTC", b.site("default").get("timezone"));
      // A visit after the change, and days enough for its day to be built.
      b.store
          .db()
          .run(
              "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)",
              List.of(now.get() + DAY, now.get() + DAY));
      now.addAndGet(3 * DAY);
      assertEquals(0, b.buildRollups(), "holding the old timezone, it builds nothing");
      b.check();
      assertEquals("Europe/Paris", b.site("default").get("timezone"));
      List<String> days = new ArrayList<>(b.store.rollupDays("default"));
      days.sort(null);
      assertEquals(
          List.of("2026-10-07", "2026-10-08"), days, "then it builds the days after the change");
      a.store.close();
      b.store.close();
    } finally {
      Files.deleteIfExists(file);
    }
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void eventsLeftBehindByAnOlderVersionWhoseVisitRetentionRemovedAreSweptOnce(String kind) {
    Harness t = new Harness(kind, site("UTC"));
    t.rl.init();
    long old = t.now - 400 * DAY;
    var db = t.store().db();
    db.run(
        "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)",
        List.of(old, old));
    db.run(
        "INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', 'v1', 's1', 'p1', '/', 'example.com')",
        List.of(old));
    // An event that joined the visit long after it started, as older versions allowed.
    db.run(
        "INSERT INTO rl_events (site, ts, kind, visitor, session, name, path, hostname) VALUES ('default', ?, 'event', 'v1', 's1', 'Late', '/', 'example.com')",
        List.of(t.now - 30 * DAY));
    t.rl.setRetention("default", 6L);
    t.rl.idle();
    t.rl.check();
    assertEquals(List.of(), db.all("SELECT name FROM rl_events WHERE site = 'default'"));
    assertEquals("1", t.store().setting("orphans-swept:default"));
  }

  @Test
  void plannerStatisticsAreGatheredOnceADay() {
    WatchedDb watched = new WatchedDb(Databases.fresh("sqlite").db());
    AtomicInteger analyzed = new AtomicInteger();
    watched.before =
        sql -> {
          if (sql.equals("ANALYZE")) {
            analyzed.incrementAndGet();
          }
        };
    Harness t = new Harness(new SqlStore(watched), site("UTC"));
    t.rl.init();
    assertEquals(1, analyzed.get(), "a database without statistics gets them at the start");
    t.rl.check();
    t.rl.check();
    assertEquals(2, analyzed.get(), "not again the same day");
    t.advance(DAY);
    t.rl.check();
    assertEquals(3, analyzed.get());
    assertFalse(
        t.store().db().all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'").isEmpty(),
        "statistics written");
  }

  @Test
  void shortLinkClicksAreNotVisitsInTheHeatmapRawOrRolledUpNorTheFirstVisit() {
    AtomicLong clock = new AtomicLong(utc(2026, 10, 7, 12));
    Runlight rl =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .sites(
                    List.of(
                        Json.object("id", "a", "name", "Site A", "hostnames", List.of("a.com"))))
                .now(clock::get));
    rl.init();
    long day = utc(2026, 10, 5, 15);
    // A session opened only by a short link click, then a real visit.
    rl.store
        .db()
        .run(
            "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'a', 'v1', ?, ?, 0, 0, 0)",
            List.of(day - 3_600_000, day - 3_600_000));
    rl.store
        .db()
        .run(
            "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'a', 'v2', ?, ?, 1, 0, 0)",
            List.of(day, day));
    assertEquals(day, Js.asLong(rl.store.firstOwnVisit("a")));
    Map<String, Object> query =
        Json.object(
            "site", "a", "from", utc(2026, 10, 1), "to", utc(2026, 10, 7), "filters", List.of());
    assertEquals(1L, visits(rl.store.hourly(query)), "raw");
    clock.addAndGet(3 * 3_600_000L);
    rl.buildRollups();
    assertEquals(1L, visits(rl.store.hourly(query)), "rolled up");
  }

  private static long visits(List<Map<String, Object>> rows) {
    long sum = 0;
    for (Map<String, Object> r : rows) {
      sum += Js.asLong(r.get("visits"));
    }
    return sum;
  }

  @Test
  void aCheckReportsWhatItSent() {
    Harness t = new Harness("sqlite");
    Fixtures.assertJson(
        Json.object("ok", true, "reports", Json.object("sent", 0L, "failed", 0L)), t.rl.check());
  }
}
