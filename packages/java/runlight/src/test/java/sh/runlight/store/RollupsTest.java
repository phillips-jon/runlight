package sh.runlight.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.Fixtures.assertJson;
import static sh.runlight.store.Seed.row;
import static sh.runlight.store.Seed.rows;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Js;
import sh.runlight.Json;

/** Daily rollups, as rollups.test.ts and counting.test.ts test them at the store. */
class RollupsTest extends StoreTestCase {
  private static final List<String> PAGES =
      List.of("/", "/blog/one", "/blog/two", "/pricing", "/about");
  private static final List<String> SOURCES =
      List.of("Google", "Hacker News", "", "ChatGPT", "Twitter");
  private static final List<String> COUNTRIES = List.of("GB", "US", "DE", "CA");

  /** Ten days of visits, some running past midnight, ending two hours before NOW. */
  private static void tenDays(SqlStore store) {
    long now = NOW - 10 * DAY;
    int n = 0;
    for (int day = 0; day < 10; day++) {
      for (int v = 0; v < 6; v++) {
        n++;
        long start = now;
        List<Object[]> rows = new ArrayList<>();
        for (int p = 0; p < 1 + n % 3; p++) {
          String id = "pv" + n + "x" + p;
          rows.add(row("pageview", PAGES.get((n + p) % 5), now, id));
          now += 20_000 + (n % 5) * 7_000L;
          if (n % 2 == 0) {
            rows.add(row("engagement", id, now, 9_000L + n * 100L, 40L + n % 60));
          }
          if (n % 4 == 0) {
            rows.add(row("event", "Signup", now, null));
          }
        }
        String source = SOURCES.get(n % 5);
        // Visitor ids change every day, as the daily salt changes them.
        Seed.visit(
            store,
            "s" + n,
            "v" + (n % 4) + Seed.ymd(start).replace("-", ""),
            start,
            Json.object(
                "source", source,
                "channel", source.isEmpty() ? "Direct" : "Referral",
                "referrerHost", source.isEmpty() ? "" : "x.example",
                "country", COUNTRIES.get(n % 4),
                "device", n % 3 == 0 ? "Mobile" : "Desktop",
                "browser", n % 3 == 0 ? "Safari" : "Chrome",
                "os", n % 3 == 0 ? "iOS" : "macOS"),
            rows);
        now += 3 * HOUR + (n % 7) * MIN;
      }
      // A visit that runs past midnight belongs to the day it started.
      now += DAY - 6 * (3 * HOUR) - 30 * MIN;
    }
  }

  /** Every report the dashboard asks the store for, as JSON, for comparing before and after. */
  private static Map<String, String> everything(SqlStore store) {
    Map<String, Object> out = new LinkedHashMap<>();
    Map<String, long[]> ranges = new LinkedHashMap<>();
    ranges.put("7d", new long[] {NOW - 7 * DAY, NOW + DAY});
    ranges.put("30d", new long[] {NOW - 30 * DAY, NOW + DAY});
    ranges.put("odd", new long[] {NOW - 6 * DAY - 5 * HOUR, NOW - 2 * DAY + 3 * HOUR});
    ranges.put("today", new long[] {NOW - 12 * HOUR, NOW + 12 * HOUR});
    ranges.put("all", new long[] {0, NOW + DAY});
    for (Map.Entry<String, long[]> range : ranges.entrySet()) {
      String name = range.getKey();
      long from = range.getValue()[0];
      long to = range.getValue()[1];
      Map<String, Object> query = q(from, to);
      out.put("stats " + name, store.stats(query));
      List<Map<String, Object>> buckets = new ArrayList<>();
      for (long at = from == 0 ? NOW - 12 * DAY : from; at < to; at += DAY) {
        buckets.add(Json.object("start", at, "end", Math.min(at + DAY, to)));
      }
      out.put("series " + name, store.series(query, buckets));
      List<Map<String, Object>> hourly = new ArrayList<>(store.hourly(query));
      hourly.sort(Comparator.comparingDouble(r -> Js.toNumber(r.get("quarter"))));
      out.put("hourly " + name, hourly);
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
        out.put(dimension + " " + name, store.breakdown(query, dimension, 3, 0));
        out.put(dimension + " " + name + " page 2", store.breakdown(query, dimension, 3, 3));
      }
    }
    out.put("filtered", store.stats(q(NOW - 30 * DAY, NOW + DAY, w("country", "is", "GB"))));
    Map<String, String> json = new LinkedHashMap<>();
    for (Map.Entry<String, Object> e : out.entrySet()) {
      json.put(e.getKey(), Json.stringify(e.getValue()));
    }
    return json;
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void reportsReadFromDailyRollupsMatchReportsReadFromEveryVisit(String kind) {
    SqlStore store = store(kind);
    tenDays(store);
    Map<String, String> before = everything(store);
    assertTrue(Seed.buildDays(store, "default", NOW - 11 * DAY, NOW) >= 8);
    assertEquals(11, store.rollupDays("default").size());
    Map<String, String> after = everything(store);
    for (Map.Entry<String, String> e : before.entrySet()) {
      assertEquals(e.getValue(), after.get(e.getKey()), e.getKey());
    }

    // Proof the reports read the rollups: with the built days' raw visits gone, a long range still
    // adds up.
    Map<String, Object> span =
        store.db().all("SELECT MIN(start_at) AS s, MAX(end_at) AS e FROM rl_rollup_days").get(0);
    long s = Js.asLong(span.get("s"));
    long e = Js.asLong(span.get("e"));
    store.db().run("DELETE FROM rl_events WHERE ts >= ? AND ts < ?", List.of(s, e - 2 * HOUR));
    store
        .db()
        .run(
            "DELETE FROM rl_sessions WHERE started_at >= ? AND started_at < ?",
            List.of(s, e - 2 * HOUR));
    Map<String, String> again = everything(store);
    for (String key : List.of("stats 30d", "source 30d", "page 30d", "event 30d", "hourly 30d")) {
      assertEquals(before.get(key), again.get(key), key + " comes from rollups");
    }
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aLateEventAndEngagementOnAnOldPageviewAreCountedOnceTheDayIsBuiltAgain(String kind) {
    SqlStore store = store(kind);
    // Evening of October 5th, then rollups built the next morning.
    long start = utc(2026, 10, 5, 20);
    Seed.visit(store, "s1", "v1", start, Map.of(), rows(row("pageview", "/", start, "late1")));
    long day5 = utc(2026, 10, 5, 0);
    store.buildRollupDay("default", "2026-10-05", day5, day5 + DAY);
    // The tab was left open overnight: its event and engagement arrive now.
    long late = start + 7 * HOUR;
    store.insertEvent(
        Json.object(
            "site",
            "default",
            "ts",
            late,
            "kind",
            "event",
            "visitor",
            "v1",
            "session",
            "s1",
            "pageview",
            "late1",
            "path",
            "/",
            "hostname",
            "example.com",
            "title",
            "",
            "name",
            "Signup",
            "props",
            null,
            "engagedMs",
            0L,
            "scroll",
            null,
            "link",
            ""));
    store.touchSession("s1", late, "event", "/", false);
    store.insertEvent(
        Json.object(
            "site",
            "default",
            "ts",
            late,
            "kind",
            "engagement",
            "visitor",
            "v1",
            "session",
            "s1",
            "pageview",
            "late1",
            "path",
            "/",
            "hostname",
            "example.com",
            "title",
            "",
            "name",
            "",
            "props",
            null,
            "engagedMs",
            60_000L,
            "scroll",
            80L,
            "link",
            ""));
    store.addEngagement("s1", 60_000);
    store.touchedOldVisit("default", start, late - 2 * HOUR);
    assertJson(List.of(), store.rollupDays("default"), "the day is forgotten");
    store.touchedOldVisit("default", start, start - 1);
    Map<String, Object> query = q(day5, day5 + DAY);
    Supplier<String> read =
        () ->
            Json.stringify(
                List.of(
                    store.stats(query),
                    store.breakdown(query, "event", 10, 0),
                    store.breakdown(query, "page", 10, 0)));
    store.buildRollupDay("default", "2026-10-05", day5, day5 + DAY);
    String rolled = read.get();
    store.clearRollups("default");
    assertJson(List.of(), store.rollupDays("default"));
    assertEquals(rolled, read.get());
    assertJson(0, store.stats(query).get("bounceRate"), "the event means the visit did not bounce");
    assertEquals(List.of("Signup"), column(store.breakdown(query, "event", 10, 0), "value"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void tiesComeInCodePointOrderTheSameBeforeAndAfterTheDaysAreBuilt(String kind) {
    SqlStore store = store(kind);
    List<String> values =
        List.of("alpha", "Zeta", "beta", "Gamma", "émile", "Émile", "_x", "a-b", "ab");
    long t = NOW - DAY;
    for (int i = 0; i < values.size(); i++) {
      Seed.visit(
          store,
          "s" + i,
          "v" + i,
          t + i * MIN,
          Json.object("utmCampaign", values.get(i)),
          rows(row("pageview", "/", t + i * MIN, "pv" + i)));
    }
    List<String> expected = new ArrayList<>(values);
    expected.sort(Sql::codeOrder);
    Map<String, Object> week = q(NOW - 7 * DAY, NOW + DAY);
    assertEquals(
        expected,
        column(store.breakdown(week, "utm_campaign", 20, 0), "value"),
        "read from every visit");
    Seed.buildDays(store, "default", NOW - 2 * DAY, NOW);
    assertEquals(
        expected,
        column(store.breakdown(week, "utm_campaign", 20, 0), "value"),
        "read from rollups");
  }

  /** A few visits some days back, built, as the two clearing tests start. */
  private record Built(SqlStore store, Map<String, Object> month, String before) {}

  private static Built built(String kind, int days) {
    SqlStore store = store(kind);
    for (int d = 0; d < days; d++) {
      long t = NOW - (days + 2 - d) * DAY;
      Seed.visit(store, "s" + d, "v" + d, t, Map.of(), rows(row("pageview", "/", t, "d" + d)));
    }
    Seed.buildDays(store, "default", NOW - (days + 3) * DAY, NOW - DAY);
    Map<String, Object> month = q(NOW - 30 * DAY, NOW + DAY);
    return new Built(store, month, Json.stringify(store.stats(month)));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aDayBuiltByAnotherProcessWhileItIsBeingClearedIsNeverLeftMarkedBuiltWithoutItsNumbers(
      String kind) {
    Built b = built(kind, 4);
    SqlStore store = b.store();
    WatchedDb watched = new WatchedDb(store.db());
    SqlStore view = new SqlStore(watched);
    boolean[] raced = {false};
    watched.afterRun =
        (sql, params) -> {
          if (!raced[0]
              && sql.startsWith("DELETE FROM rl_rollup_days WHERE site = ? AND start_at")) {
            raced[0] = true;
            watched.afterRun = null;
            // Another process builds the days right after their marks are deleted.
            Seed.buildDays(store, "default", NOW - 7 * DAY, NOW - DAY);
          }
        };
    view.clearRollups("default", Json.object("from", NOW - 4 * DAY, "to", NOW));
    assertTrue(raced[0]);
    assertEquals(b.before(), Json.stringify(store.stats(b.month())));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void clearingDaysThatStopsPartWayLeavesNoneMarkedBuiltWithoutItsNumbers(String kind) {
    Built b = built(kind, 8);
    SqlStore store = b.store();
    WatchedDb watched = new WatchedDb(store.db());
    int[] deletes = {0};
    watched.before =
        (sql, params) -> {
          if (sql.startsWith("DELETE FROM rl_rollups WHERE") && ++deletes[0] > 3) {
            throw new IllegalStateException("connection lost");
          }
        };
    IllegalStateException error =
        assertThrows(
            IllegalStateException.class,
            () -> new SqlStore(watched).clearRollups("default"),
            "the clear should have stopped");
    assertEquals("connection lost", error.getMessage());
    assertEquals(b.before(), Json.stringify(store.stats(b.month())));
    Seed.buildDays(store, "default", NOW - 12 * DAY, NOW - DAY);
    assertEquals(b.before(), Json.stringify(store.stats(b.month())));
  }

  private static long count(SqlStore store, String sql) {
    return Js.asLong(store.db().all(sql).get(0).get("n"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void retentionDropsOldVisitsWithTheirEventsAndForgetsTheDaysTheyWereIn(String kind) {
    SqlStore store = store(kind);
    long[] ats = {utc(2025, 10, 1, 0), utc(2026, 7, 1, 0), utc(2026, 10, 6, 0)};
    for (int i = 0; i < ats.length; i++) {
      long t = ats[i] + HOUR;
      Seed.visit(
          store,
          "s" + i,
          "v" + i,
          t,
          Map.of(),
          rows(row("pageview", "/", t, "p" + i), row("event", "E", t + 1, null)));
    }
    // An event of the oldest visit that came after the cutoff goes with it.
    store.insertEvent(
        Json.object(
            "site",
            "default",
            "ts",
            utc(2025, 10, 1, 0) + DAY,
            "kind",
            "event",
            "visitor",
            "v0",
            "session",
            "s0",
            "pageview",
            "",
            "path",
            "/",
            "hostname",
            "",
            "title",
            "",
            "name",
            "Late",
            "props",
            null,
            "engagedMs",
            0L,
            "scroll",
            null,
            "link",
            ""));
    Map<String, Object> all = q(0, NOW + DAY);
    assertJson(3, store.stats(all).get("visits"));
    store.buildRollupDay("default", "2026-07-01", utc(2026, 7, 1, 0), utc(2026, 7, 2, 0));
    store.dropBefore("default", utc(2026, 4, 6, 0));
    assertJson(2, store.stats(all).get("visits"), "the visit from a year ago is gone");
    assertEquals(
        0,
        count(store, "SELECT COUNT(*) AS n FROM rl_events WHERE session = 's0'"),
        "its events, even the late one");
    assertEquals(
        List.of("2026-07-01"), store.rollupDays("default"), "a day after the cutoff stays built");
    store.dropBefore("default", utc(2026, 8, 1, 0));
    assertJson(1, store.stats(all).get("visits"));
    assertJson(
        List.of(), store.rollupDays("default"), "a day before the cutoff is built again later");

    // Events whose visit is gone, as an older version left them, are swept.
    store.insertEvent(
        Json.object(
            "site",
            "default",
            "ts",
            NOW - DAY,
            "kind",
            "pageview",
            "visitor",
            "x",
            "session",
            "gone",
            "pageview",
            "g",
            "path",
            "/",
            "hostname",
            "",
            "title",
            "",
            "name",
            "",
            "props",
            null,
            "engagedMs",
            0L,
            "scroll",
            null,
            "link",
            ""));
    store.insertEvent(
        Json.object(
            "site",
            "default",
            "ts",
            NOW - DAY,
            "kind",
            "fetch",
            "visitor",
            "",
            "session",
            "",
            "pageview",
            "",
            "path",
            "/",
            "hostname",
            "",
            "title",
            "",
            "name",
            "GPTBot",
            "props",
            null,
            "engagedMs",
            0L,
            "scroll",
            null,
            "link",
            ""));
    store.dropOrphans("default", 0, NOW + DAY);
    assertEquals(0, count(store, "SELECT COUNT(*) AS n FROM rl_events WHERE session = 'gone'"));
    assertEquals(
        1,
        count(store, "SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'fetch'"),
        "rows of no visit stay");
  }
}
