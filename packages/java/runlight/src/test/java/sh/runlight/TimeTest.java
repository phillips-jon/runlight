package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.Fixtures.assertJson;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** The TypeScript SDK's time tests, then the fixture written from it. */
class TimeTest {
  private static long utc(int y, int m, int d, int h) {
    return Time.utc(y, m, d, h, 0, 0);
  }

  @Test
  void aLocalDayStartsAtLocalMidnight() {
    assertEquals(
        "2026-06-30T23:00:00.000Z", Time.isoString(Time.startOf("2026-07-01", "Europe/London")));
    assertEquals(
        "2026-01-15T05:00:00.000Z", Time.isoString(Time.startOf("2026-01-15", "America/Toronto")));
    assertEquals(
        "2026-01-14T18:30:00.000Z", Time.isoString(Time.startOf("2026-01-15", "Asia/Kolkata")));
    assertEquals("2026-01-15T00:00:00.000Z", Time.isoString(Time.startOf("2026-01-15", "UTC")));
  }

  @Test
  void theSpringDstChangeMakesA23HourDay() {
    Map<String, Object> range =
        Time.resolveRange(
            Map.of("from", "2026-03-07", "to", "2026-03-09"),
            "America/Toronto",
            utc(2026, 2, 10, 0),
            null);
    List<Map<String, Object>> days = Time.buckets(range, "America/Toronto");
    List<Long> hours = new ArrayList<>();
    for (Map<String, Object> d : days) {
      hours.add((Js.asLong(d.get("end")) - Js.asLong(d.get("start"))) / 3_600_000);
    }
    assertEquals(List.of(24L, 23L, 24L), hours);
  }

  @Test
  void namedPeriodsResolveInTheSitesTimezone() {
    long now = utc(2026, 9, 6, 2);
    assertEquals("2026-10-05", Time.localDate(now, "America/Toronto"));
    Map<String, Object> today =
        Time.resolveRange(Map.of("period", "today"), "America/Toronto", now, null);
    assertEquals("2026-10-05", today.get("fromDate"));
    assertEquals("hour", today.get("interval"));
    Map<String, Object> lastMonth =
        Time.resolveRange(Map.of("period", "last_month"), "UTC", now, null);
    assertEquals("2026-09-01", lastMonth.get("fromDate"));
    assertEquals("2026-09-30", lastMonth.get("toDate"));
    assertNull(Time.resolveRange(Map.of("period", "nope"), "UTC", now, null));
    assertNull(
        Time.resolveRange(Map.of("from", "2026-02-30", "to", "2026-03-01"), "UTC", now, null));
  }

  @Test
  void aDayWhoseMidnightIsSkippedByTheClocksBeginsWhenTheyLand() {
    String[][] cases = {
      {"2026-09-06", "America/Santiago", "2026-09-06T04:00:00.000Z"},
      {"2026-03-08", "America/Havana", "2026-03-08T05:00:00.000Z"},
      {"2026-03-29", "Atlantic/Azores", "2026-03-29T01:00:00.000Z"},
    };
    for (String[] c : cases) {
      long at = Time.startOf(c[0], c[1]);
      assertEquals(c[2], Time.isoString(at), c[1]);
      assertEquals(c[0], Time.localDate(at, c[1]));
      assertNotEquals(c[0], Time.localDate(at - 1, c[1]));
    }
  }

  @Test
  void aDateWithAMonthOrDayThatDoesNotExistIsNotADate() {
    for (String bad :
        List.of(
            "2026-13-01",
            "2026-00-05",
            "2026-02-30",
            "2026-04-31",
            "2026-1-01",
            "9999-12-31",
            "0001-01-01")) {
      assertFalse(Time.isDate(bad), bad);
    }
    assertTrue(Time.isDate("2028-02-29"));
  }

  /**
   * ICU's System V zones with summer time keep the United States rules of their day, which no zone
   * in java.time's database has; their names are taken, and they follow today's rules here.
   */
  private static final List<String> SYSTEM_V_SUMMER =
      List.of(
          "systemv/ast4adt",
          "systemv/est5edt",
          "systemv/cst6cdt",
          "systemv/mst7mdt",
          "systemv/pst8pdt",
          "systemv/yst9ydt");

  /**
   * The fixture came from Node's ICU with time zone data 2025c. The JDK carries its own copy, which
   * has British Columbia's later change to permanent summer time from 2026 on.
   */
  private static final List<String> NEWER_RULES = List.of("America/Vancouver", "Canada/Pacific");

  @Test
  void zones() {
    Map<String, Object> fixture = Fixtures.load("time");
    List<String> failures = new ArrayList<>();
    List<Object> times = Js.list(fixture.get("sampleTimes"));
    for (Map<String, Object> zone : Fixtures.cases(fixture, "zones")) {
      String name = (String) zone.get("name");
      boolean valid = Time.isTimezone(name);
      if (valid != Boolean.TRUE.equals(zone.get("valid"))) {
        failures.add(name + (valid ? " taken" : " refused"));
        continue;
      }
      if (!valid
          || SYSTEM_V_SUMMER.contains(name.toLowerCase(Locale.ROOT))
          || NEWER_RULES.contains(name)) {
        continue;
      }
      List<Object> local = Js.list(zone.get("local"));
      for (int i = 0; i < times.size(); i++) {
        long ts = Js.asLong(times.get(i));
        if (ts < 0) {
          continue;
        }
        int[] wh = Time.localWeekdayHour(ts, name);
        String got = Time.localDate(ts, name) + " " + wh[0] + " " + wh[1];
        if (!got.equals(local.get(i))) {
          failures.add(name + " at " + ts + ": " + got + " not " + local.get(i));
        }
      }
    }
    assertEquals(List.of(), failures.subList(0, Math.min(30, failures.size())));
  }

  @Test
  void instantsAroundEveryOffsetChange() {
    List<String> failures = new ArrayList<>();
    for (Object item : Js.list(Fixtures.load("time").get("instants"))) {
      List<Object> c = Js.list(item);
      String zone = (String) c.get(0);
      long ts = Js.asLong(c.get(1));
      int[] wh = Time.localWeekdayHour(ts, zone);
      String got = Time.localDate(ts, zone) + " " + wh[0] + " " + wh[1];
      String want = c.get(2) + " " + c.get(3) + " " + c.get(4);
      if (!got.equals(want)) {
        failures.add(zone + " " + ts + ": " + got + " not " + want);
      }
    }
    assertEquals(List.of(), failures.subList(0, Math.min(30, failures.size())));
  }

  @Test
  void dayStarts() {
    Map<String, Object> fixture = Fixtures.load("time");
    List<String> failures = new ArrayList<>();
    for (Object item : Js.list(fixture.get("starts"))) {
      List<Object> c = Js.list(item);
      long got = Time.startOf((String) c.get(1), (String) c.get(0), (int) Js.asLong(c.get(2)));
      if (got != Js.asLong(c.get(3))) {
        failures.add(c.get(0) + " " + c.get(1) + " " + c.get(2) + ": " + got + " not " + c.get(3));
      }
    }
    for (Object item : Js.list(fixture.get("dayStarts"))) {
      List<Object> c = Js.list(item);
      long year = Js.asLong(c.get(1));
      List<Object> days = new ArrayList<>();
      String end = (year + 1) + "-01-01";
      for (String d = year + "-01-01"; d.compareTo(end) < 0; d = Time.addDays(d, 1)) {
        days.add(Time.startOf(d, (String) c.get(0)));
      }
      if (!Hash.sha256(Json.stringify(days)).equals(c.get(2))) {
        failures.add(c.get(0) + " " + year + ": every day's start");
      }
    }
    assertEquals(List.of(), failures.subList(0, Math.min(30, failures.size())));
  }

  @Test
  void dateMath() {
    Map<String, Object> fixture = Fixtures.load("time");
    for (Map<String, Object> c : Fixtures.cases(fixture, "dates")) {
      String date = (String) c.get("date");
      assertEquals(c.get("isDate"), Time.isDate(date), date);
      if (c.get("plus") != null) {
        List<Object> plus = new ArrayList<>();
        for (int n : new int[] {-400, -366, -365, -31, -1, 0, 1, 28, 29, 31, 365, 366, 1000}) {
          plus.add(Time.addDays(date, n));
        }
        assertJson(c.get("plus"), plus, date);
        List<Object> months = new ArrayList<>();
        for (int n : new int[] {-25, -12, -11, -1, 0, 1, 11, 12, 13}) {
          months.add(Time.addMonths(date, n));
        }
        assertJson(c.get("months"), months, date);
      }
    }
    assertJson(fixture.get("periods"), Time.PERIODS);
  }

  @Test
  void rangesAndBuckets() {
    List<String> failures = new ArrayList<>();
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("time"), "ranges")) {
      String zone = (String) c.get("zone");
      Map<String, Object> range =
          Time.resolveRange(
              Js.map(c.get("input")), zone, Js.asLong(c.get("now")), (String) c.get("firstDate"));
      Map<String, Object> got = Json.object("range", range);
      Map<String, Object> want = Json.object("range", c.get("range"));
      if (range != null) {
        List<Map<String, Object>> buckets = Time.buckets(range, zone);
        got.put(
            "buckets",
            Json.object(
                "count", buckets.size(),
                "first", buckets.isEmpty() ? null : buckets.get(0),
                "sha256", Hash.sha256(Json.stringify(buckets))));
        want.put("buckets", c.get("buckets"));
        if (c.containsKey("compare")) {
          Map<String, Object> compare = Json.object();
          for (String mode : List.of("previous", "year", "off", "custom", "nope")) {
            compare.put(
                mode,
                Time.compareRange(
                    range, mode, zone, Map.of("from", "2025-02-28", "to", "2025-03-31")));
          }
          got.put("compare", compare);
          want.put("compare", c.get("compare"));
        }
      }
      if (!Json.stringify(Fixtures.stored(got)).equals(Json.stringify(want))) {
        failures.add(Fixtures.label(c.get("input")) + " " + zone + " gave " + Fixtures.label(got));
      }
    }
    assertEquals(List.of(), failures.subList(0, Math.min(20, failures.size())));
  }

  @Test
  void compareRanges() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("time"), "compares")) {
      assertJson(
          c.get("compare"),
          Time.compareRange(
              Js.map(c.get("range")),
              (String) c.get("mode"),
              (String) c.get("zone"),
              Js.map(c.get("custom"))),
          Fixtures.label(c));
    }
  }
}
