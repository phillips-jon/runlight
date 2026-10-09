package sh.runlight.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.Time;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.store.Databases;
import sh.runlight.store.SqlStore;

/**
 * A Runlight on a fresh database with a clock the test moves, as helpers.ts's setup() is. Tracker
 * hits go straight to collect(), and reports are read from the store, so nothing here needs the
 * routes.
 */
public final class Harness {
  public static final String CHROME_MAC =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
  public static final String SAFARI_IPHONE =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
  public static final long DAY = 86_400_000L;
  public static final long HOUR = 3_600_000L;
  public static final long MIN = 60_000L;

  /** Date.UTC(2026, 9, 6, 12), where the TS tests start the clock. */
  public static final long START = 1_791_288_000_000L;

  public final Runlight rl;
  public long now = START;

  public Harness(String kind) {
    this(kind, new Runlight.Options());
  }

  /** A Harness on a fresh database of a kind, with these options besides the store and clock. */
  public Harness(String kind, Runlight.Options options) {
    this(Databases.fresh(kind), options);
  }

  public Harness(SqlStore store, Runlight.Options options) {
    this.rl = new Runlight(options.store(store).now(() -> this.now));
  }

  public SqlStore store() {
    return rl.store;
  }

  public void advance(long ms) {
    now += ms;
  }

  /** Date.UTC with months counted from 1. */
  public static long utc(int y, int m, int d, int h, int i, int s) {
    return Time.utc(y, m - 1, d, h, i, s);
  }

  public static long utc(int y, int m, int d, int h) {
    return utc(y, m, d, h, 0, 0);
  }

  public static long utc(int y, int m, int d) {
    return utc(y, m, d, 0, 0, 0);
  }

  /** Date.parse of an ISO time. */
  public static long at(String iso) {
    return java.time.OffsetDateTime.parse(iso).toInstant().toEpochMilli();
  }

  /** A tracker hit, as the routes pass it to collect(). */
  public void send(Map<String, Object> body) {
    send(body, Map.of());
  }

  /**
   * A tracker hit, as the routes pass it to collect().
   *
   * @param init any of ua, ip, and headers (a map)
   */
  public void send(Map<String, Object> body, Map<String, Object> init) {
    rl.collect(hit("https://example.com/runlight/e", body, init));
  }

  /** A tracker hit from an address. */
  public void sendFrom(Map<String, Object> body, String ip) {
    send(body, Json.object("ip", ip));
  }

  /**
   * A tracker hit's request.
   *
   * @param init any of ua, ip, and headers (a map)
   */
  public static Request hit(String url, Map<String, Object> body, Map<String, Object> init) {
    Map<String, String> headers = new LinkedHashMap<>();
    headers.put("user-agent", init.get("ua") instanceof String ua ? ua : CHROME_MAC);
    headers.put("x-forwarded-for", init.get("ip") instanceof String ip ? ip : "203.0.113.1");
    headers.put("content-type", "text/plain;charset=UTF-8");
    Map<String, Object> more = Js.map(init.get("headers"));
    if (more != null) {
      for (Map.Entry<String, Object> e : more.entrySet()) {
        headers.put(e.getKey(), (String) e.getValue());
      }
    }
    return new Request(url, "POST", Headers.of(headers), Json.stringify(body));
  }

  /** A query over local dates of a site, as the dashboard's from and to make one. */
  public Map<String, Object> query(String from, String to) {
    return query(from, to, null, List.of());
  }

  public Map<String, Object> query(String from, String to, String site, List<Object> filters) {
    Map<String, Object> row = rl.site(site);
    String tz = (String) row.get("timezone");
    return Json.object(
        "site",
        row.get("id"),
        "from",
        Time.startOf(from, tz),
        "to",
        Time.startOf(Time.addDays(to, 1), tz),
        "filters",
        filters);
  }

  /** Today in the site's timezone, as period=today. */
  public Map<String, Object> today() {
    return today(null);
  }

  public Map<String, Object> today(String site) {
    rl.init();
    String day = Time.localDate(now, (String) rl.site(site).get("timezone"));
    return query(day, day, site, List.of());
  }

  /** Everything, as period=all reads it, wide enough for any test. */
  public Map<String, Object> all() {
    return all(null);
  }

  public Map<String, Object> all(String site) {
    rl.init();
    return Json.object(
        "site", rl.site(site).get("id"), "from", 0L, "to", now + DAY, "filters", List.of());
  }

  public Map<String, Object> stats(Map<String, Object> query) {
    return store().stats(query);
  }

  /** One field of each breakdown row. */
  public List<Object> values(Map<String, Object> query, String dimension) {
    List<Object> out = new ArrayList<>();
    for (Map<String, Object> r : store().breakdown(query, dimension, 10, 0)) {
      out.add(r.get("value"));
    }
    return out;
  }

  public long count(String sql, Object... params) {
    return Js.asLong(store().db().all(sql, List.of(params)).get(0).get("n"));
  }
}
