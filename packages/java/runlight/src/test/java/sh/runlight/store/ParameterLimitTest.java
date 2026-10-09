package sh.runlight.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.store.Seed.row;
import static sh.runlight.store.Seed.rows;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Json;

/**
 * d1-limits.test.ts at the store: no statement binds more than 100 values, as Cloudflare D1
 * requires, over a year of data, on SQLite as D1 runs it and on MySQL, whose statements for the
 * same reports are written differently.
 */
class ParameterLimitTest extends StoreTestCase {
  static List<String> limited() {
    List<String> kinds = Databases.kinds();
    kinds.remove("postgres");
    return kinds;
  }

  private static List<Map<String, Object>> days(long from, long to, long size) {
    List<Map<String, Object>> out = new ArrayList<>();
    for (long at = from; at < to; at += size) {
      out.add(Json.object("start", at, "end", Math.min(at + size, to)));
    }
    return out;
  }

  @ParameterizedTest
  @MethodSource("limited")
  void noStatementBindsMoreThan100Parameters(String kind) {
    SqlStore store = store(kind);
    // A visit every third day for a year, so a year of days can be built.
    store.transaction(
        tx -> {
          for (int d = 0; d < 365; d += 3) {
            long t = NOW - 365 * DAY + d * DAY;
            Seed.visit(
                tx,
                "y" + d,
                "v" + d,
                t,
                Json.object("country", "GB"),
                rows(
                    row("pageview", "/p" + (d % 40), t, "y" + d),
                    row("event", "Goal" + (d % 30), t + 1, Json.object("amount", (long) d))));
          }
          return null;
        });
    Seed.buildDays(store, "default", NOW - 366 * DAY, NOW - DAY);
    for (int g = 0; g < 30; g++) {
      store.saveGoal(
          goal(
              String.format("%24s", Integer.toHexString(g)).replace(' ', '0'),
              Json.object(
                  "name",
                  "Goal " + g,
                  "match",
                  "Goal" + g,
                  "valueMode",
                  g % 2 != 0 ? "prop" : "fixed",
                  "value",
                  5L,
                  "valueProp",
                  "amount")));
    }
    Map<String, Object> funnel =
        Json.object(
            "id",
            "f".repeat(24),
            "site",
            "default",
            "name",
            "Funnel",
            "steps",
            List.of(
                Json.object("kind", "page", "match", "/p1"),
                Json.object("kind", "event", "match", "Goal1")),
            "createdAt",
            0L);
    store.saveFunnel(funnel);
    // Days not built, scattered through the last month, as late engagement or an import leaves
    // them.
    for (int d = 2; d < 30; d += 3) {
      store.clearRollups("default", Json.object("from", NOW - d * DAY, "to", NOW - d * DAY + 1));
    }

    // Every statement from here on is checked.
    WatchedDb watched = new WatchedDb(store.db());
    int[] most = {0};
    watched.before =
        (sql, params) -> {
          most[0] = Math.max(most[0], params.size());
          if (params.size() > 100) {
            throw new IllegalStateException("a statement bound " + params.size() + " parameters");
          }
        };
    SqlStore view = new SqlStore(watched);
    List<Map<String, Object>> goals = view.goals("default");
    // As many filters as a query takes, each of the kind that binds the most.
    List<Map<String, Object>> many =
        List.of(
            f("page", "contains", "/P"),
            f("page", "contains", "é"),
            f("event", "contains", "goal"),
            f("hostname", "contains", "example"),
            f("page", "not", "/x"),
            f("country", "not", "XX"));
    // Path filters in mixed case are tried in several forms, each a value of its own.
    List<Map<String, Object>> paths =
        List.of(
            f("page", "contains", "/pÉ"),
            f("page", "contains", "/Pé"),
            f("page", "contains", "/xÜ"),
            f("page", "contains", "/üX"),
            f("page", "contains", "/ÉtÉ"),
            f("hostname", "contains", "eXa"));
    Map<String, long[]> ranges = new LinkedHashMap<>();
    ranges.put("12mo", new long[] {NOW - 365 * DAY, NOW + DAY, DAY});
    ranges.put("all", new long[] {NOW - 400 * DAY, NOW + DAY, 30 * DAY});
    ranges.put("90d", new long[] {NOW - 90 * DAY, NOW + DAY, DAY});
    ranges.put("30d", new long[] {NOW - 30 * DAY, NOW + DAY, DAY});
    ranges.put("7d hourly", new long[] {NOW - 7 * DAY, NOW + DAY, HOUR});
    for (long[] range : ranges.values()) {
      long from = range[0];
      long to = range[1];
      long size = range[2];
      for (List<Map<String, Object>> filters :
          List.of(
              List.<Map<String, Object>>of(),
              List.of(f("page", "contains", "/p")),
              List.of(f("country", "not", "XX")),
              many,
              paths)) {
        Map<String, Object> query =
            Json.object("site", "default", "from", from, "to", to, "filters", filters);
        view.stats(query);
        view.series(query, days(from, to, size));
        view.hourly(query);
        view.breakdown(query, "page", 1000, 0);
        view.breakdown(query, "source", 1000, 0);
        view.breakdown(query, "event", 1000, 0);
        assertEquals(30, view.goalTotalsAll(query, goals).size());
        for (Map<String, Object> goal : List.of(goals.get(1), goals.get(2))) {
          view.goalTotals(query, goal);
          view.goalSeries(query, goal, days(from, to, size));
          view.goalBreakdown(query, goal, "path");
        }
        view.funnelCounts(query, funnel);
        view.journeyPages(query, 5);
        view.eventPropKeys(query, "Goal1");
        view.eventPropValues(query, "Goal1", "amount", 10);
      }
    }
    assertTrue(most[0] <= 100);
    assertTrue(most[0] > 50, "the reads came close");
  }
}
