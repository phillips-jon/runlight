package sh.runlight.store;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * Visits written through the store as the tracker writes them (a session, then its rows, each
 * counted into the session), for store tests that do not go through the core or the routes.
 */
final class Seed {
  private Seed() {}

  static final long DAY = 86_400_000L;
  static final long HOUR = 3_600_000L;
  static final long MIN = 60_000L;

  private static final DateTimeFormatter YMD =
      DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC);

  /** A UTC day, Y-m-d, of a time in milliseconds. */
  static String ymd(long ms) {
    return YMD.format(Instant.ofEpochMilli(ms));
  }

  /** One row of a visit, as visit() takes it. */
  static Object[] row(Object... parts) {
    return parts;
  }

  /** Rows for visit(). */
  static List<Object[]> rows(Object[]... rows) {
    return List.of(rows);
  }

  static void visit(
      SqlStore store,
      String id,
      String visitor,
      long startedAt,
      Map<String, Object> fields,
      List<Object[]> rows) {
    visit(store, id, visitor, startedAt, fields, rows, "default");
  }

  static void visit(SqlStore store, String id, String visitor, long startedAt) {
    visit(store, id, visitor, startedAt, Map.of(), List.of(), "default");
  }

  static void visit(
      SqlStore store, String id, String visitor, long startedAt, Map<String, Object> fields) {
    visit(store, id, visitor, startedAt, fields, List.of(), "default");
  }

  /**
   * A session with its fields, then its rows in order. A row is one of: {"pageview", path, ts,
   * pageviewId} (optional fifth: hostname), {"event", name, ts, props or null} (optional fifth:
   * path), {"engagement", pageviewId, ts, ms, scroll or null}.
   */
  static void visit(
      SqlStore store,
      String id,
      String visitor,
      long startedAt,
      Map<String, Object> fields,
      List<Object[]> rows,
      String site) {
    Map<String, Object> session =
        Json.object(
            "id",
            id,
            "site",
            site,
            "visitor",
            visitor,
            "startedAt",
            startedAt,
            "hostname",
            "example.com",
            "referrerHost",
            "",
            "referrerPath",
            "",
            "source",
            "",
            "channel",
            "Direct",
            "utmSource",
            "",
            "utmMedium",
            "",
            "utmCampaign",
            "",
            "utmTerm",
            "",
            "utmContent",
            "",
            "country",
            "",
            "region",
            "",
            "city",
            "",
            "browser",
            "Chrome",
            "browserVersion",
            "129",
            "os",
            "macOS",
            "osVersion",
            "",
            "device",
            "Desktop",
            "screen",
            "",
            "language",
            "en");
    session.putAll(fields);
    store.insertSession(session);
    Map<String, String> paths = new HashMap<>();
    String last = "/";
    String hostname =
        fields.containsKey("hostname") ? (String) fields.get("hostname") : "example.com";
    for (Object[] r : rows) {
      Map<String, Object> event =
          Json.object(
              "site",
              site,
              "visitor",
              visitor,
              "session",
              id,
              "pageview",
              "",
              "path",
              last,
              "hostname",
              hostname,
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
              "");
      Map<String, Object> e = new LinkedHashMap<>(event);
      long ts = ((Number) r[2]).longValue();
      switch ((String) r[0]) {
        case "pageview" -> {
          String path = (String) r[1];
          String pv = (String) r[3];
          paths.put(pv, path);
          last = path;
          e.put("ts", ts);
          e.put("kind", "pageview");
          e.put("pageview", pv);
          e.put("path", path);
          e.put("hostname", r.length > 4 ? r[4] : hostname);
          e.put("title", Js.slice("Title " + path, 0, 500));
          store.insertEvent(e);
          store.touchSession(id, ts, "pageview", path);
        }
        case "event" -> {
          String path = r.length > 4 ? (String) r[4] : last;
          e.put("ts", ts);
          e.put("kind", "event");
          e.put("name", r[1]);
          e.put("props", r[3]);
          e.put("path", path);
          store.insertEvent(e);
          store.touchSession(id, ts, "event", path);
        }
        default -> {
          String pv = (String) r[1];
          long ms = ((Number) r[3]).longValue();
          e.put("ts", ts);
          e.put("kind", "engagement");
          e.put("pageview", pv);
          e.put("path", paths.getOrDefault(pv, last));
          e.put("engagedMs", ms);
          e.put("scroll", r[4]);
          store.insertEvent(e);
          store.addEngagement(id, ms);
        }
      }
    }
  }

  /**
   * A site's days built as the core builds them, a UTC day at a time, for every whole day before
   * {@code before} that has a visit.
   */
  static int buildDays(SqlStore store, String site, long from, long before) {
    int built = 0;
    for (long day = Math.floorDiv(from, DAY) * DAY; day + DAY <= before; day += DAY) {
      store.buildRollupDay(site, ymd(day), day, day + DAY);
      built++;
    }
    return built;
  }
}
