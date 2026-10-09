package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * Report periods, replayed from what scripts/php-fixtures-core2.mts had the TypeScript SDK write.
 * Rendering the fixture's reports needs the core's collect() to record their visits, so that part
 * of the PHP ReportsTest is left to the core's tests; here an empty period renders in every
 * language.
 */
class ReportsTest {
  private static long utc(int year, int month, int day, int hour) {
    return Time.utc(year, month - 1, day, hour, 0, 0);
  }

  @Test
  void reportPeriodsMatchForEveryZoneAndFrequency() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("reports"), "periods")) {
      Fixtures.assertJson(
          c.get("period"),
          Reports.lastPeriod(
              (String) c.get("frequency"), Js.asLong(c.get("now")), (String) c.get("zone")),
          Fixtures.label(c));
    }
  }

  @Test
  void reportPeriodsAreLastMondayToSundayOrLastMonthDueFrom8amTheDayAfterInTheSitesZone() {
    // Wednesday 8 October 2026, 15:00 UTC (11:00 in Toronto).
    long now = utc(2026, 10, 8, 15);
    Map<String, Object> week = Reports.lastPeriod("weekly", now, "America/Toronto");
    assertEquals(
        List.of("w:2026-09-28", "2026-09-28", "2026-10-04", "2026-09-21"),
        List.of(
            week.get("key"), week.get("fromDate"), week.get("toDate"), week.get("previousFrom")));
    assertEquals(utc(2026, 10, 5, 12), week.get("dueAt"), "Monday 5 October, 8am Toronto");
    Map<String, Object> month = Reports.lastPeriod("monthly", now, "America/Toronto");
    assertEquals(
        List.of("m:2026-09", "2026-09-01", "2026-09-30", "2026-08-01", "2026-08-31"),
        List.of(
            month.get("key"),
            month.get("fromDate"),
            month.get("toDate"),
            month.get("previousFrom"),
            month.get("previousTo")));
    Map<String, Object> early =
        Reports.lastPeriod("weekly", utc(2026, 10, 5, 7), "America/Toronto");
    assertTrue(utc(2026, 10, 5, 7) < (long) early.get("dueAt"));
  }

  @Test
  void anEmptyPeriodRendersInEveryLanguage() {
    SqlStore store = Stores.sqlite(":memory:");
    store.migrate();
    Map<String, Object> site =
        Json.object(
            "id",
            "default",
            "name",
            "Example & Co",
            "hostnames",
            List.of("example.com"),
            "timezone",
            "UTC");
    Map<String, Object> links =
        Json.object(
            "dashboard", "https://example.com/runlight/?site=default",
            "unsubscribe", "https://example.com/runlight/unsubscribe?t=x");
    for (String lang : Messages.languages()) {
      for (String frequency : List.of("weekly", "monthly")) {
        Map<String, Object> period = Reports.lastPeriod(frequency, utc(2026, 10, 8, 15), "UTC");
        Map<String, Object> report =
            Reports.buildReport(store, site, frequency, period, lang, links);
        String text = (String) report.get("text");
        assertTrue(text.startsWith("Runlight · "), lang + " " + text);
        assertTrue(text.contains("example.com/runlight"), lang);
        assertTrue(((String) report.get("html")).contains("Example &amp; Co"), lang);
        assertTrue(((String) report.get("html")).startsWith("<!doctype html><html lang=\"" + lang));
      }
    }
  }
}
