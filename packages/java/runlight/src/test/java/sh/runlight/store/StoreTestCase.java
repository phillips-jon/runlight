package sh.runlight.store;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import sh.runlight.Json;

/** Store tests that run on every database at hand (see Databases). */
abstract class StoreTestCase {
  static final long DAY = Seed.DAY;
  static final long HOUR = Seed.HOUR;
  static final long MIN = Seed.MIN;

  /** Date.UTC(2026, 9, 6, 12), the clock the TypeScript tests start from. */
  static final long NOW = 1_791_288_000_000L;

  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void cleanUp() {
    Databases.cleanup();
  }

  /** A fresh store with its tables and the site "default" in UTC. */
  static SqlStore store(String kind) {
    return store(kind, "UTC");
  }

  static SqlStore store(String kind, String timezone) {
    SqlStore store = Databases.fresh(kind);
    store.migrate();
    store.upsertSite(
        Json.object(
            "id",
            "default",
            "name",
            "Example",
            "hostnames",
            List.of("example.com"),
            "timezone",
            timezone),
        NOW);
    return store;
  }

  /** A filter: dimension, op, and value. */
  static Map<String, Object> f(String dimension, String op, String value) {
    return Json.object("dimension", dimension, "op", op, "value", value);
  }

  /** A query over a range, with filters given as {dimension, op, value}. */
  static Map<String, Object> q(long from, long to, String[]... filters) {
    List<Object> list = new ArrayList<>();
    for (String[] filter : filters) {
      list.add(f(filter[0], filter[1], filter[2]));
    }
    return Json.object("site", "default", "from", from, "to", to, "filters", list);
  }

  /** The UTC day holding NOW, as a query. */
  static Map<String, Object> today(String[]... filters) {
    return q(NOW - 12 * HOUR, NOW + 12 * HOUR, filters);
  }

  /** A UTC time in milliseconds, as gmmktime(hour, 0, 0, month, day, year) * 1000. */
  static long utc(int year, int month, int day, int hour) {
    return java.time.LocalDateTime.of(year, month, day, hour, 0)
        .toInstant(java.time.ZoneOffset.UTC)
        .toEpochMilli();
  }

  /** One filter for q() and today(). */
  static String[] w(String dimension, String op, String value) {
    return new String[] {dimension, op, value};
  }

  static Map<String, Object> goal(String id, Map<String, Object> fields) {
    Map<String, Object> goal =
        Json.object(
            "id", id,
            "site", "default",
            "name", id,
            "kind", "event",
            "match", "",
            "clickBy", "",
            "valueMode", "none",
            "value", 0L,
            "valueProp", "",
            "currency", "USD",
            "createdAt", 0L);
    goal.putAll(fields);
    return goal;
  }

  /** A copy of a map with some fields changed, as PHP's [...$a, 'k' => v]. */
  static Map<String, Object> with(Map<String, Object> base, Object... pairs) {
    Map<String, Object> out = new LinkedHashMap<>(base);
    out.putAll(Json.object(pairs));
    return out;
  }

  /** One column of a list of rows, as array_column. */
  static List<Object> column(List<Map<String, Object>> rows, String key) {
    List<Object> out = new ArrayList<>();
    for (Map<String, Object> row : rows) {
      out.add(row.get(key));
    }
    return out;
  }

  /** The sum of one column, as a long. */
  static long sum(List<Map<String, Object>> rows, String key) {
    long total = 0;
    for (Map<String, Object> row : rows) {
      total += ((Number) row.get(key)).longValue();
    }
    return total;
  }
}
