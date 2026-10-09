package sh.runlight.store;

import static sh.runlight.store.Sql.dnum;
import static sh.runlight.store.Sql.list;
import static sh.runlight.store.Sql.num;
import static sh.runlight.store.Sql.str;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Query;
import sh.runlight.db.Db;
import sh.runlight.db.JdbcDb;

/**
 * Runlight's tables, read and written with the same SQL as store.ts's SqlStore for each dialect, so
 * a database made by either implementation opens in the other. Rows are the TypeScript interfaces
 * as maps with the same camelCase keys (SiteRow, GoalRow, ReportRow, ShareRow, FunnelRow, TokenRow,
 * LinkRow, SessionRow, EventRow), a query is an object with site, from, to, and filters, and a
 * bucket an object with start and end.
 *
 * <p>Numbers come back as {@link Long} when whole and {@link Double} otherwise, as JavaScript's one
 * number type writes them.
 */
public final class SqlStore implements AutoCloseable {
  public static final long BOUNCE_MS = Sql.BOUNCE_MS;
  public static final int JOURNEY_VISITS = Sql.JOURNEY_VISITS;
  public static final long EVENT_TAIL_MS = Sql.EVENT_TAIL_MS;
  public static final String MYSQL_COLLATION = Sql.MYSQL_COLLATION;

  private final Db db;
  private volatile boolean ready;
  private volatile boolean checkedAll;

  public SqlStore(Db db) {
    this.db = db;
  }

  public Db db() {
    return db;
  }

  private static String site(Map<String, Object> query) {
    return (String) query.get("site");
  }

  private static long from(Map<String, Object> query) {
    return Js.asLong(query.get("from"));
  }

  private static long to(Map<String, Object> query) {
    return Js.asLong(query.get("to"));
  }

  @SuppressWarnings("unchecked")
  private static List<Map<String, Object>> filters(Map<String, Object> query) {
    Object filters = query.get("filters");
    return filters == null ? List.of() : (List<Map<String, Object>>) filters;
  }

  private static Map<String, Object> first(List<Map<String, Object>> rows) {
    return rows.isEmpty() ? null : rows.get(0);
  }

  private static Object at(Map<String, Object> row, String key) {
    return row == null ? null : row.get(key);
  }

  /** A whole double as a Long, as JavaScript holds one number type. */
  private static Object whole(double n) {
    return Js.num(n);
  }

  private static List<Object> concat(List<?>... lists) {
    List<Object> out = new ArrayList<>();
    for (List<?> l : lists) {
      out.addAll(l);
    }
    return out;
  }

  public void migrate() {
    migrate(false);
  }

  /**
   * Creates the tables on first use. Safe to call any number of times. When the database already
   * records the current schema version, that is taken as done; {@code full} goes over everything
   * anyway, as the scheduled check does, which adds an index a database of this version may lack.
   */
  public synchronized void migrate(boolean full) {
    if (checkedAll || (ready && !full)) {
      return;
    }
    if (!full && !ready) {
      try {
        Object found =
            at(first(db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'")), "value");
        if (found != null && text(found).equals(Integer.toString(Sql.SCHEMA_VERSION))) {
          ready = true;
          return;
        }
      } catch (RuntimeException e) {
        // No rl_meta yet: a new database, made below.
      }
    }
    db.exclusive(
        d -> {
          // On Postgres an index on a big table takes a while to build, so the build may run past
          // the statement timeout, and goes CONCURRENTLY, so another process keeps writing.
          boolean postgres = d.dialect().equals("postgres");
          if (postgres) {
            d.run("SET statement_timeout = 0");
          }
          try {
            upgrade(d, postgres);
          } finally {
            if (postgres) {
              try {
                d.run("RESET statement_timeout");
              } catch (RuntimeException e) {
                // A lost connection takes its setting with it.
              }
            }
          }
          return null;
        });
    ready = true;
    checkedAll = true;
  }

  private static final Pattern INDEX =
      Pattern.compile("^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\\w+) ON (\\w+)");
  private static final Pattern DUPLICATE =
      Pattern.compile("duplicate column|already exists", Pattern.CASE_INSENSITIVE);

  private void upgrade(Db d, boolean postgres) {
    List<String> statements = Sql.schema(d.dialect());
    d.run(statements.get(0));
    Map<String, Object> found = first(d.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'"));
    double from = found != null ? Js.toNumber(found.get("value")) : Sql.SCHEMA_VERSION;
    if (postgres) {
      // A concurrent build that was stopped leaves its index unusable; it goes, and is built again.
      List<Map<String, Object>> broken =
          d.all(
              "SELECT c.relname AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid\n"
                  + "           WHERE NOT i.indisvalid AND c.relname LIKE 'rl\\_%' AND c.relnamespace = current_schema()::regnamespace");
      for (Map<String, Object> row : broken) {
        d.run("DROP INDEX IF EXISTS \"" + text(row.get("name")).replace("\"", "") + "\"");
      }
    }
    for (String statement : statements) {
      Matcher index = INDEX.matcher(statement);
      if (d.dialect().equals("mysql") && index.find()) {
        // MySQL has no CREATE INDEX IF NOT EXISTS, so it is looked for first.
        String unique = index.group(1) == null ? "" : index.group(1);
        List<Map<String, Object>> there =
            d.all(
                "SELECT 1 AS there FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1",
                List.of(index.group(3), index.group(2)));
        if (there.isEmpty()) {
          d.run(
              statement.replaceFirst(
                  "^CREATE (UNIQUE )?INDEX IF NOT EXISTS", "CREATE " + unique + "INDEX"));
        }
      } else {
        d.run(
            postgres
                ? statement.replaceFirst(
                    "^CREATE (UNIQUE )?INDEX IF NOT EXISTS",
                    "CREATE $1INDEX CONCURRENTLY IF NOT EXISTS")
                : statement);
      }
    }
    // A column added by an upgrade that stopped before it recorded the new version is already
    // there.
    java.util.function.Consumer<String> addColumn =
        sql -> {
          try {
            d.run(sql);
          } catch (RuntimeException e) {
            if (!DUPLICATE.matcher(String.valueOf(e.getMessage())).find()) {
              throw e;
            }
          }
        };
    // Version 2: settings changed in the dashboard, kept apart from the ones in code.
    if (from < 2) {
      addColumn.accept("ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'");
    }
    if (from < 4) {
      d.run("DROP INDEX IF EXISTS rl_links_slug");
    }
    // Version 10: tokens that may change one site's settings, for a hub.
    if (from >= 8 && from < 10) {
      addColumn.accept("ALTER TABLE rl_tokens ADD COLUMN scope TEXT NOT NULL DEFAULT 'read'");
    }
    // Written only when it changes, so a database opened read-only can still be read.
    if (found == null || !text(found.get("value")).equals(Integer.toString(Sql.SCHEMA_VERSION))) {
      d.run(
          Sql.upsert(
              d.dialect(),
              "rl_meta",
              List.of("\"key\"", "value"),
              List.of("\"key\""),
              List.of("value")),
          List.of("schema", Integer.toString(Sql.SCHEMA_VERSION)));
    }
  }

  public void optimize() {
    optimize(false);
  }

  /**
   * Keeps SQLite's planner statistics current, which it never gathers by itself. A sample of each
   * index is enough. Postgres gathers its own.
   */
  public void optimize(boolean onlyWhenMissing) {
    if (!db.dialect().equals("sqlite")) {
      return;
    }
    try {
      if (onlyWhenMissing
          && !db.all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'").isEmpty()) {
        return;
      }
      db.run("PRAGMA analysis_limit = 1000");
      db.run("ANALYZE");
    } catch (RuntimeException e) {
      // Some hosted SQLite services refuse these, and gather statistics themselves.
    }
  }

  @Override
  public void close() {
    db.close();
  }

  private boolean metered() {
    return db.metered();
  }

  /** How many rows an UPDATE or DELETE of rows with an id matched. */
  private long changed(String sql, List<?> params) {
    if (db.dialect().equals("mysql")) {
      return db.affected(sql, params);
    }
    return db.all(sql + " RETURNING id", params).size();
  }

  /** Runs {@code fn} with a store whose every query is in one transaction. */
  public <T> T transaction(Function<SqlStore, T> fn) {
    return db.transaction(d -> fn.apply(d == db ? this : new SqlStore(d)));
  }

  // Sites

  /** Writes a site from code, leaving an unchanged one alone. */
  public void upsertSite(Map<String, Object> site, long now) {
    // Unchanged sites are left alone, so starting needs no write and a read-only database opens.
    String hostnames = Json.stringify(site.get("hostnames"));
    Map<String, Object> row =
        first(
            db.all(
                "SELECT name, hostnames, timezone FROM rl_sites WHERE id = ?",
                List.of(site.get("id"))));
    if (row != null
        && text(row.get("name")).equals(site.get("name"))
        && text(row.get("hostnames")).equals(hostnames)
        && text(row.get("timezone")).equals(site.get("timezone"))) {
      return;
    }
    db.run(
        Sql.upsert(
            db.dialect(),
            "rl_sites",
            List.of("id", "name", "hostnames", "timezone", "created_at"),
            List.of("id"),
            List.of("name", "hostnames", "timezone")),
        list(site.get("id"), site.get("name"), hostnames, site.get("timezone"), now));
  }

  /** Settings changed in the dashboard, by site. They win over the ones in code. */
  public Map<String, Map<String, Object>> siteOverrides() {
    Map<String, Map<String, Object>> out = new LinkedHashMap<>();
    for (Map<String, Object> row : db.all("SELECT id, overrides FROM rl_sites")) {
      Json.Parsed value = Json.tryParse(text(row.get("overrides")));
      out.put(
          text(row.get("id")),
          value.ok() && value.value() instanceof Map<?, ?>
              ? Js.map(value.value())
              : new LinkedHashMap<>());
    }
    return out;
  }

  private static final List<String> SITE_TABLES =
      List.of(
          "rl_events",
          "rl_sessions",
          "rl_links",
          "rl_link_domains",
          "rl_shares",
          "rl_goals",
          "rl_funnels",
          "rl_reports",
          "rl_tokens",
          "rl_rollups",
          "rl_rollup_days",
          "rl_sites");

  /**
   * Deletes a site and everything recorded for it. Its events and visits go a day at a time first,
   * so a big site does not hold the database for minutes, and what is left goes in one transaction.
   */
  public void deleteSite(String id) {
    long piece = metered() ? 30 * Sql.PIECE_MS : Sql.PIECE_MS;
    for (String[] tc : new String[][] {{"rl_events", "ts"}, {"rl_sessions", "started_at"}}) {
      // A piece at a time from the oldest row, skipping straight over stretches with none.
      for (Double at = oldest(tc[0], tc[1], id, null);
          at != null;
          at = oldest(tc[0], tc[1], id, at + piece)) {
        db.run(
            "DELETE FROM " + tc[0] + " WHERE site = ? AND " + tc[1] + " < ?",
            list(id, Js.num(at + piece)));
      }
    }
    transaction(
        store -> {
          for (String table : SITE_TABLES) {
            store.db.run(
                "DELETE FROM "
                    + table
                    + " WHERE "
                    + (table.equals("rl_sites") ? "id" : "site")
                    + " = ?",
                List.of(id));
          }
          return null;
        });
  }

  /**
   * When a site's oldest row at or after {@code from} is (null for no bound), or null when none.
   */
  private Double oldest(String table, String col, String site, Double from) {
    Map<String, Object> row =
        first(
            db.all(
                "SELECT MIN("
                    + col
                    + ") AS t FROM "
                    + table
                    + " WHERE site = ?"
                    + (from == null ? "" : " AND " + col + " >= ?"),
                from == null ? List.of(site) : list(site, Js.num(from))));
    return row == null || row.get("t") == null ? null : dnum(row.get("t"));
  }

  /** Deletes a site's visits and events from before a time, for its retention setting. */
  public void dropBefore(String site, long ts) {
    // A day at a time from the oldest, each its own short transaction. Stretches with nothing in
    // them are skipped, so one stray old row does not cost a piece for every day since.
    long piece = metered() ? 30 * Sql.PIECE_MS : Sql.PIECE_MS;
    Function<Double, Double> next =
        at -> {
          Double a = oldest("rl_sessions", "started_at", site, at);
          Double b = oldest("rl_events", "ts", site, at);
          if (a == null && b == null) {
            return null;
          }
          double min = a == null ? b : b == null ? a : Math.min(a, b);
          return at == null ? min : Math.max(at, min);
        };
    for (Double at = next.apply(null);
        at != null && at < ts;
        at = next.apply(Math.min(at + piece, (double) ts))) {
      double f = at;
      double t = Math.min(at + piece, ts);
      transaction(
          store -> {
            // A visit's events go with it, even ones after the cutoff, so nothing is left without
            // its visit. They come after it starts and within EVENT_TAIL_MS.
            store.db.run(
                "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND started_at >= ? AND started_at < ?)",
                list(site, Js.num(f), Js.num(t + Sql.EVENT_TAIL_MS), site, Js.num(f), Js.num(t)));
            store.db.run("DELETE FROM rl_events WHERE site = ? AND ts < ?", list(site, Js.num(t)));
            store.db.run(
                "DELETE FROM rl_sessions WHERE site = ? AND started_at < ?", list(site, Js.num(t)));
            return null;
          });
    }
    // A day that lost any of its visits is built again later, from what is left.
    clearRollups(site, Map.of("before", ts));
  }

  /** Deletes a site's events from {@code from} on whose visit no longer exists, a day at a time. */
  public void dropOrphans(String site, long from, long until) {
    long piece = metered() ? 30 * Sql.PIECE_MS : Sql.PIECE_MS;
    for (Double at = oldest("rl_events", "ts", site, (double) from);
        at != null && at < until;
        at = oldest("rl_events", "ts", site, at + piece)) {
      db.run(
          "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session <> '' AND NOT EXISTS (SELECT 1 FROM rl_sessions s WHERE s.id = rl_events.session)",
          list(site, Js.num(at), Js.num(at + piece)));
    }
  }

  // Daily rollups

  /**
   * Adds up one local day of a site: totals, each visit dimension, and pages. A visit belongs to
   * the day it started. Visitor ids change every day, so the days of a range add up to exactly what
   * counting the range would give.
   */
  public void buildRollupDay(String site, String day, long start, long end) {
    // A day with no visits still gets its row of zeros, so it counts as built.
    String bounce = Sql.BOUNCE;
    String sums =
        "COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN "
            + bounce
            + " THEN 1 ELSE 0 END), 0), COALESCE(SUM("
            + Sql.DURATION
            + "), 0)";
    String cols = "(site, day, dim, value, visitors, visits, pageviews, bounced, duration)";
    // Each piece names its own site and day, as text, so Postgres knows their type inside a UNION.
    String dialect = db.dialect();
    String head = Sql.asText(dialect, "?") + ", " + Sql.asText(dialect, "?");
    String quarter = Sql.div(dialect, "s.started_at", 900000);
    // The day's totals, each visit dimension, and the heatmap's quarter hours, in one statement
    // over
    // the day's visits, since a Cloudflare D1 check may only send so many.
    List<String> pieces = new ArrayList<>();
    pieces.add("SELECT " + head + ", '', '', " + sums + " FROM v s");
    for (Map.Entry<String, String> e : Query.SESSION_DIMENSIONS.entrySet()) {
      String col = e.getValue();
      pieces.add(
          "SELECT "
              + head
              + ", '"
              + e.getKey()
              + "', s."
              + col
              + ", "
              + sums
              + " FROM v s WHERE s."
              + col
              + " <> '' GROUP BY s."
              + col);
    }
    pieces.add(
        "SELECT "
            + head
            + ", 'quarter', "
            + Sql.asText(dialect, quarter)
            + ", COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN "
            + bounce
            + " THEN 1 ELSE 0 END), 0), 0 FROM v s GROUP BY "
            + Sql.asText(dialect, quarter));
    // Pages and events, from the rows of the day's visits. The time bounds let the (site, kind, ts)
    // index find them; a visit's last row comes at most EVENT_TAIL_MS after it starts.
    Function<String, String> ofDay =
        kind ->
            "FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n       WHERE e.site = ? AND e.kind = '"
                + kind
                + "' AND e.ts >= ? AND e.ts < ? AND s.started_at >= ? AND s.started_at < ? AND "
                + Sql.IS_VISIT;
    List<Object> window = list(site, start, end + Sql.EVENT_TAIL_MS, start, end);
    transaction(
        store -> {
          Db d = store.db;
          d.run("DELETE FROM rl_rollups WHERE site = ? AND day = ?", List.of(site, day));
          // The WITH goes after INSERT INTO, the one place every database takes it.
          List<Object> params = list(site, start, end);
          for (int i = 0; i < pieces.size(); i++) {
            params.add(site);
            params.add(day);
          }
          d.run(
              "INSERT INTO rl_rollups "
                  + cols
                  + "\n         WITH v AS (SELECT * FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND "
                  + Sql.IS_VISIT
                  + ")\n         "
                  + String.join(" UNION ALL ", pieces),
              params);
          // A page's engaged time and scroll come per pageview first (its time added up, its
          // deepest scroll), as the raw report counts them.
          d.run(
              "INSERT INTO rl_rollups (site, day, dim, value, visitors, visits, pageviews, views, engaged, scroll_sum, scroll_n)\n"
                  + "         SELECT ?, ?, 'page', p.value, p.visitors, p.visits, p.pageviews, p.views, COALESCE(t.engaged, 0), COALESCE(t.scroll_sum, 0), COALESCE(t.scroll_n, 0)\n"
                  + "         FROM (SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, "
                  + Sql.LIVE_VIEWS
                  + " AS views\n               "
                  + ofDay.apply("pageview")
                  + " GROUP BY e.path) p\n"
                  + "         LEFT JOIN (SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (\n"
                  + "               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest "
                  + ofDay.apply("engagement")
                  + " GROUP BY e.path, e.pageview) x\n               GROUP BY value) t ON t.value = p.value",
              concat(List.of(site, day), window, window));
          d.run(
              "INSERT INTO rl_rollups (site, day, dim, value, visitors, events)\n         SELECT ?, ?, 'event', e.name, COUNT(DISTINCT e.visitor), COUNT(*) "
                  + ofDay.apply("event")
                  + " GROUP BY e.name",
              concat(List.of(site, day), window));
          d.run("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", List.of(site, day));
          d.run(
              "INSERT INTO rl_rollup_days (site, day, start_at, end_at) VALUES (?, ?, ?, ?)",
              list(site, day, start, end));
          return null;
        });
  }

  /** The days of a site already built. */
  public List<String> rollupDays(String site) {
    LinkedHashSet<String> days = new LinkedHashSet<>();
    for (Map<String, Object> r :
        db.all("SELECT day FROM rl_rollup_days WHERE site = ?", List.of(site))) {
      days.add(text(r.get("day")));
    }
    return new ArrayList<>(days);
  }

  public void clearRollups(String site) {
    clearRollups(site, Map.of());
  }

  /**
   * Forgets built days, all of a site's or those touching a stretch of time (before, or from and
   * to), so they are built again.
   */
  public void clearRollups(String site, Map<String, ?> range) {
    String where = "site = ?";
    List<Object> params = list(site);
    if (range.get("before") != null) {
      where += " AND start_at < ?";
      params.add(Js.num(range.get("before")));
    } else if (range.get("from") != null && range.get("to") != null) {
      where += " AND start_at < ? AND end_at > ?";
      params.add(Js.num(range.get("to")));
      params.add(Js.num(range.get("from")));
    }
    List<String> days = new ArrayList<>();
    for (Map<String, Object> r : db.all("SELECT day FROM rl_rollup_days WHERE " + where, params)) {
      days.add(text(r.get("day")));
    }
    // The days stop counting as built first, so if this stops part way, no day is left marked built
    // without its rows. Another process may build a day between the two deletes, so its mark goes
    // again after its rows: the day is then simply built once more.
    db.run("DELETE FROM rl_rollup_days WHERE " + where, params);
    for (String day : days) {
      db.run("DELETE FROM rl_rollups WHERE site = ? AND day = ?", List.of(site, day));
      db.run("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", List.of(site, day));
    }
  }

  /** A built day with where it begins and ends. */
  private record Day(String day, double start, double end) {}

  /** How to answer a range from rollups: the built days inside it, and the stretches left over. */
  private record Plan(List<Day> days, List<double[]> rest) {}

  private Plan rollupPlan(Map<String, Object> query, double from, double to) {
    if (!filters(query).isEmpty()) {
      return null;
    }
    List<Map<String, Object>> rows =
        db.all(
            "SELECT day, start_at, end_at FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ? ORDER BY start_at",
            list(site(query), Js.num(from), Js.num(to)));
    if (rows.isEmpty()) {
      return null;
    }
    List<Day> days = new ArrayList<>();
    for (Map<String, Object> r : rows) {
      days.add(new Day(text(r.get("day")), dnum(r.get("start_at")), dnum(r.get("end_at"))));
    }
    List<double[]> rest = new ArrayList<>();
    double at = from;
    for (Day d : days) {
      if (d.start() > at) {
        rest.add(new double[] {at, d.start()});
      }
      at = Math.max(at, d.end());
    }
    if (at < to) {
      rest.add(new double[] {at, to});
    }
    return new Plan(days, rest);
  }

  /** SQL for "a visit that started in one of these stretches". */
  private static Sql.Piece within(List<double[]> rest) {
    if (rest.isEmpty()) {
      return new Sql.Piece("1 = 0", new ArrayList<>());
    }
    List<Object> params = new ArrayList<>();
    for (double[] r : rest) {
      params.add(Js.num(r[0]));
      params.add(Js.num(r[1]));
    }
    return new Sql.Piece(
        "("
            + String.join(
                " OR ",
                Collections.nCopies(rest.size(), "(s.started_at >= ? AND s.started_at < ?)"))
            + ")",
        params);
  }

  private static final List<String> SUM_KEYS =
      List.of(
          "visitors",
          "visits",
          "pageviews",
          "bounced",
          "duration",
          "engaged",
          "views",
          "scroll_sum",
          "scroll_n",
          "events");

  /**
   * A breakdown of a visit dimension or of pages from rollups and the visits left over, merged,
   * then sorted and cut to the page asked for.
   */
  private List<Map<String, Object>> rolledBreakdown(
      Map<String, Object> query, String dimension, int limit, int offset) {
    boolean page = dimension.equals("page");
    boolean event = dimension.equals("event");
    if (!page && !event && !Query.isSessionDimension(dimension)) {
      return null;
    }
    if (!filters(query).isEmpty()) {
      return null;
    }
    // Pages and events always go this way without filters, so a range gives the same answer whether
    // its days are built or not.
    Plan plan = rollupPlan(query, from(query), to(query));
    if (plan == null && (page || event)) {
      List<double[]> rest = new ArrayList<>();
      rest.add(new double[] {from(query), to(query)});
      plan = new Plan(List.of(), rest);
    }
    if (plan == null) {
      return null;
    }
    Map<String, Map<String, Double>> sums = new LinkedHashMap<>();
    java.util.function.Consumer<Map<String, Object>> bump =
        row -> {
          String key = text(row.get("value"));
          Map<String, Double> into = sums.computeIfAbsent(key, k -> zeros(SUM_KEYS));
          for (String k : SUM_KEYS) {
            into.put(k, into.get(k) + dnum(row.get(k)));
          }
        };
    if (!plan.days().isEmpty()) {
      List<Map<String, Object>> rolled =
          db.all(
              "SELECT value, SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration,\n"
                  + "           SUM(engaged) AS engaged, SUM(views) AS views, SUM(scroll_sum) AS scroll_sum, SUM(scroll_n) AS scroll_n, SUM(events) AS events\n"
                  + "         FROM rl_rollups WHERE site = ? AND dim = ? AND day IN ("
                  + Sql.BUILT_DAYS
                  + ") GROUP BY value",
              list(site(query), dimension, site(query), from(query), to(query)));
      rolled.forEach(bump);
    }
    Sql.Piece w = within(plan.rest());
    String isVisit = Sql.IS_VISIT;
    if ((page || event) && !plan.rest().isEmpty()) {
      // A visit's pageviews and events belong to the day it started, as in the rollups.
      double lo = Double.POSITIVE_INFINITY;
      double hi = Double.NEGATIVE_INFINITY;
      for (double[] r : plan.rest()) {
        lo = Math.min(lo, r[0]);
        hi = Math.max(hi, r[1]);
      }
      hi += Sql.EVENT_TAIL_MS;
      Function<String, String> ofRest =
          kind ->
              "FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.kind = '"
                  + kind
                  + "' AND e.ts >= ? AND e.ts < ? AND "
                  + isVisit
                  + " AND "
                  + w.sql();
      List<Object> at = concat(list(site(query), Js.num(lo), Js.num(hi)), w.params());
      if (page) {
        db.all(
                "SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, "
                    + Sql.LIVE_VIEWS
                    + " AS views "
                    + ofRest.apply("pageview")
                    + " GROUP BY e.path",
                at)
            .forEach(bump);
        db.all(
                "SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (\n"
                    + "             SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest "
                    + ofRest.apply("engagement")
                    + " GROUP BY e.path, e.pageview) t GROUP BY value",
                at)
            .forEach(bump);
      } else {
        db.all(
                "SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events "
                    + ofRest.apply("event")
                    + " GROUP BY e.name",
                at)
            .forEach(bump);
      }
    } else if (page || event) {
      // Every day of the range is built.
    } else {
      String col = "s." + Query.SESSION_DIMENSIONS.get(dimension);
      db.all(
              "SELECT "
                  + col
                  + " AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,\n"
                  + "           SUM(CASE WHEN "
                  + Sql.BOUNCE
                  + " THEN 1 ELSE 0 END) AS bounced, SUM("
                  + Sql.DURATION
                  + ") AS duration\n"
                  + "         FROM rl_sessions s WHERE s.site = ? AND "
                  + isVisit
                  + " AND "
                  + w.sql()
                  + " AND "
                  + col
                  + " <> '' GROUP BY "
                  + col,
              concat(List.of(site(query)), w.params()))
          .forEach(bump);
    }
    boolean entryExit = dimension.equals("entry") || dimension.equals("exit");
    List<Map.Entry<String, Map<String, Double>>> rows = new ArrayList<>();
    for (Map.Entry<String, Map<String, Double>> e : sums.entrySet()) {
      Map<String, Double> x = e.getValue();
      if ((event || !e.getKey().isEmpty())
          && (page ? x.get("pageviews") > 0 : event ? x.get("events") > 0 : x.get("visits") > 0)) {
        rows.add(e);
      }
    }
    rows.sort(
        (p, q) -> {
          Map<String, Double> x = p.getValue();
          Map<String, Double> y = q.getValue();
          double[] order =
              entryExit
                  ? new double[] {y.get("visits") - x.get("visits")}
                  : event
                      ? new double[] {
                        y.get("visitors") - x.get("visitors"), y.get("events") - x.get("events")
                      }
                      : page
                          ? new double[] {
                            y.get("visitors") - x.get("visitors"),
                            y.get("pageviews") - x.get("pageviews")
                          }
                          : new double[] {
                            y.get("visitors") - x.get("visitors"), y.get("visits") - x.get("visits")
                          };
          for (double d : order) {
            if (d != 0) {
              return d < 0 ? -1 : 1;
            }
          }
          return Sql.codeOrder(p.getKey(), q.getKey());
        });
    List<Map<String, Object>> out = new ArrayList<>();
    for (Map.Entry<String, Map<String, Double>> e :
        rows.subList(Math.min(offset, rows.size()), Math.min(rows.size(), offset + limit))) {
      String value = e.getKey();
      Map<String, Double> x = e.getValue();
      if (event) {
        out.add(
            Json.object(
                "value",
                value,
                "visitors",
                Js.num(x.get("visitors")),
                "events",
                Js.num(x.get("events"))));
        continue;
      }
      if (page) {
        out.add(
            Json.object(
                "value",
                value,
                "visitors",
                Js.num(x.get("visitors")),
                "pageviews",
                Js.num(x.get("pageviews")),
                // Over every pageview that could report its time, counting those that sent none as
                // none.
                "timeOnPage",
                x.get("views") > 0 ? whole(Js.round(x.get("engaged") / x.get("views"))) : 0L,
                "scrollDepth",
                x.get("scroll_n") > 0
                    ? whole(Js.round(x.get("scroll_sum") / x.get("scroll_n")))
                    : 0L));
        continue;
      }
      Map<String, Object> row =
          Json.object(
              "value",
              value,
              "visitors",
              Js.num(x.get("visitors")),
              "visits",
              Js.num(x.get("visits")),
              "bounceRate",
              x.get("visits") > 0 ? whole(x.get("bounced") / x.get("visits")) : 0L);
      if (!entryExit) {
        row.put("pageviews", Js.num(x.get("pageviews")));
        row.put(
            "visitDuration",
            x.get("visits") > 0 ? whole(Js.round(x.get("duration") / x.get("visits"))) : 0L);
      }
      out.add(row);
    }
    return out;
  }

  private static Map<String, Double> zeros(List<String> keys) {
    Map<String, Double> out = new HashMap<>();
    for (String k : keys) {
      out.put(k, 0.0);
    }
    return out;
  }

  private Map<String, Object> rolledStats(Map<String, Object> query) {
    Plan plan = rollupPlan(query, from(query), to(query));
    if (plan == null) {
      return null;
    }
    Map<String, Object> rolled =
        first(
            db.all(
                "SELECT SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration\n"
                    + "       FROM rl_rollups WHERE site = ? AND dim = '' AND day IN ("
                    + Sql.BUILT_DAYS
                    + ")",
                list(site(query), site(query), from(query), to(query))));
    Sql.Piece w = within(plan.rest());
    Map<String, Object> raw =
        first(
            db.all(
                "SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,\n"
                    + "         SUM(CASE WHEN "
                    + Sql.BOUNCE
                    + " THEN 1 ELSE 0 END) AS bounced, SUM("
                    + Sql.DURATION
                    + ") AS duration\n"
                    + "       FROM rl_sessions s WHERE s.site = ? AND "
                    + Sql.IS_VISIT
                    + " AND "
                    + w.sql(),
                concat(List.of(site(query)), w.params())));
    Function<String, Double> add = k -> dnum(at(rolled, k)) + dnum(at(raw, k));
    return statsOf(
        add.apply("visitors"),
        add.apply("visits"),
        add.apply("pageviews"),
        add.apply("bounced"),
        add.apply("duration"));
  }

  private static Map<String, Object> statsOf(
      double visitors, double visits, double pageviews, double bounced, double duration) {
    return Json.object(
        "visitors",
        Js.num(visitors),
        "visits",
        Js.num(visits),
        "pageviews",
        Js.num(pageviews),
        "viewsPerVisit",
        visits > 0 ? whole(Js.round((pageviews / visits) * 100) / 100) : 0L,
        "bounceRate",
        visits > 0 ? whole(bounced / visits) : 0L,
        "visitDuration",
        visits > 0 ? whole(Js.round(duration / visits)) : 0L);
  }

  public void setSiteOverrides(String id, Map<String, Object> overrides) {
    db.run(
        "UPDATE rl_sites SET overrides = ? WHERE id = ?", List.of(Json.stringify(overrides), id));
  }

  /** When the site last recorded a visit, or null if it never has. */
  public Object lastSeen(String site) {
    Map<String, Object> row =
        first(
            db.all(
                "SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')",
                List.of(site)));
    return row == null || row.get("t") == null ? null : num(row.get("t"));
  }

  public List<Map<String, Object>> sites() {
    List<Map<String, Object>> out = new ArrayList<>();
    for (Map<String, Object> row :
        db.all("SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id")) {
      out.add(
          Json.object(
              "id", text(row.get("id")),
              "name", text(row.get("name")),
              "hostnames", Json.parse(text(row.get("hostnames"))),
              "timezone", text(row.get("timezone"))));
    }
    return out;
  }

  // Salts

  /** The salt for a day, made on first ask. Two racing callers agree on one. */
  public String salt(String day, String fresh) {
    db.run(
        Sql.upsert(db.dialect(), "rl_salts", List.of("day", "salt"), List.of("day"), List.of()),
        List.of(day, fresh));
    Map<String, Object> row =
        first(db.all("SELECT salt FROM rl_salts WHERE day = ?", List.of(day)));
    return row != null && row.get("salt") != null ? text(row.get("salt")) : fresh;
  }

  public String saltIfExists(String day) {
    Map<String, Object> row =
        first(db.all("SELECT salt FROM rl_salts WHERE day = ?", List.of(day)));
    return row != null && row.get("salt") != null ? text(row.get("salt")) : null;
  }

  /** Deletes every salt older than {@code day}, so old hashes can never be recomputed. */
  public void dropSaltsBefore(String day) {
    db.run("DELETE FROM rl_salts WHERE day < ?", List.of(day));
  }

  // Ingest

  /**
   * The visitor's open session: any of their hashes, active since {@code since}; id and visitor.
   */
  public Map<String, Object> openSession(String site, List<String> visitors, long since) {
    if (visitors.isEmpty()) {
      return null;
    }
    List<Object> params = list(site);
    params.addAll(visitors);
    params.add(since);
    Map<String, Object> row =
        first(
            db.all(
                "SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN ("
                    + String.join(", ", Collections.nCopies(visitors.size(), "?"))
                    + ") AND last_at >= ?\n       ORDER BY last_at DESC, id LIMIT 1",
                params));
    return row == null
        ? null
        : Json.object("id", text(row.get("id")), "visitor", text(row.get("visitor")));
  }

  /** Opens a session from a SessionRow. */
  public void insertSession(Map<String, Object> row) {
    db.run(
        "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,\n"
            + "        source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,\n"
            + "        browser, browser_version, os, os_version, device, screen, language)\n"
            + "       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        list(
            row.get("id"),
            row.get("site"),
            row.get("visitor"),
            row.get("startedAt"),
            row.get("startedAt"),
            row.get("hostname"),
            row.get("referrerHost"),
            row.get("referrerPath"),
            row.get("source"),
            row.get("channel"),
            row.get("utmSource"),
            row.get("utmMedium"),
            row.get("utmCampaign"),
            row.get("utmTerm"),
            row.get("utmContent"),
            row.get("country"),
            row.get("region"),
            row.get("city"),
            row.get("browser"),
            row.get("browserVersion"),
            row.get("os"),
            row.get("osVersion"),
            row.get("device"),
            row.get("screen"),
            row.get("language")));
  }

  public void touchSession(String id, long ts, String kind, String path) {
    touchSession(id, ts, kind, path, true);
  }

  /**
   * Counts a row into its session. An event with {@code reopen} false, one that joins a visit
   * already ended, counts without moving the session's last activity.
   */
  public void touchSession(String id, long ts, String kind, String path, boolean reopen) {
    if (kind.equals("click")) {
      db.run("UPDATE rl_sessions SET last_at = ? WHERE id = ?", list(ts, id));
    } else if (kind.equals("pageview")) {
      db.run(
          "UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,\n"
              + "           entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?",
          list(ts, path, path, id));
    } else if (reopen) {
      db.run("UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?", list(ts, id));
    } else {
      db.run("UPDATE rl_sessions SET events = events + 1 WHERE id = ?", List.of(id));
    }
  }

  public void addEngagement(String id, long ms) {
    db.run(
        "UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?",
        list(ms, id));
  }

  /**
   * The pageview an engagement ping or event belongs to, with when its visit started and was last
   * active: session, visitor, path, hostname, ts, startedAt, and lastAt.
   */
  public Map<String, Object> pageview(String site, String pageview) {
    Map<String, Object> row =
        first(
            db.all(
                "SELECT e.session AS session, e.visitor AS visitor, e.path AS path, e.hostname AS hostname, e.ts AS ts, s.started_at AS started_at, s.last_at AS last_at\n"
                    + "       FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.pageview = ? AND e.kind = 'pageview' LIMIT 1",
                List.of(site, pageview)));
    return row == null
        ? null
        : Json.object(
            "session", text(row.get("session")),
            "visitor", text(row.get("visitor")),
            "path", text(row.get("path")),
            "hostname", text(row.get("hostname")),
            "ts", num(row.get("ts")),
            "startedAt", num(row.get("started_at")),
            "lastAt", num(row.get("last_at")));
  }

  /**
   * After a late event or engagement ping joins an old visit (a tab left open overnight), the day
   * that visit started may already be added up. Forget that day so the next check builds it again.
   */
  public void touchedOldVisit(String site, long started, long before) {
    if (started < before) {
      clearRollups(site, Map.of("from", started, "to", started + 1));
    }
  }

  /** Writes an EventRow. */
  public void insertEvent(Map<String, Object> row) {
    Object props = row.get("props");
    db.run(
        "INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)\n"
            + "       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        list(
            row.get("site"),
            row.get("ts"),
            row.get("kind"),
            row.get("visitor"),
            row.get("session"),
            row.get("pageview"),
            row.get("path"),
            row.get("hostname"),
            row.get("title"),
            row.get("name"),
            props == null || props == Json.UNDEFINED ? null : Json.stringify(props),
            row.get("engagedMs"),
            row.get("scroll") == Json.UNDEFINED ? null : row.get("scroll"),
            row.get("link")));
  }

  // Links

  /** The live link with a slug. Slugs are unique across every domain. */
  public Map<String, Object> linkBySlug(String slug) {
    Map<String, Object> row =
        first(
            db.all(
                "SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1",
                List.of(slug)));
    return row == null ? null : Sql.linkRow(row);
  }

  public Map<String, Object> linkById(String id) {
    Map<String, Object> row =
        first(
            db.all(
                "SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1", List.of(id)));
    return row == null ? null : Sql.linkRow(row);
  }

  public void insertLink(Map<String, Object> link) {
    db.run(
        "INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        list(
            link.get("id"),
            link.get("site"),
            link.get("domain"),
            link.get("slug"),
            link.get("name"),
            link.get("url"),
            link.get("createdAt"),
            link.get("updatedAt")));
  }

  public void updateLink(Map<String, Object> link) {
    db.run(
        "UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?",
        list(
            link.get("domain"),
            link.get("slug"),
            link.get("name"),
            link.get("url"),
            link.get("updatedAt"),
            link.get("id")));
  }

  /** Hides a link and frees its slug; its clicks stay in the history. */
  public void deleteLink(String id, long now) {
    db.run("UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", list(now, id));
  }

  // Shares

  private static Map<String, Object> shareRow(Map<String, Object> r) {
    return Json.object(
        "id",
        text(r.get("id")),
        "site",
        text(r.get("site")),
        "name",
        text(r.get("name")),
        "createdAt",
        num(r.get("created_at")));
  }

  public List<Map<String, Object>> shares(String site) {
    return map(
        db.all(
            "SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC, id",
            List.of(site)),
        SqlStore::shareRow);
  }

  public Map<String, Object> shareById(String id) {
    Map<String, Object> r =
        first(db.all("SELECT id, site, name, created_at FROM rl_shares WHERE id = ?", List.of(id)));
    return r == null ? null : shareRow(r);
  }

  public void insertShare(Map<String, Object> share) {
    db.run(
        "INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)",
        list(share.get("id"), share.get("site"), share.get("name"), share.get("createdAt")));
  }

  public void renameShare(String id, String name) {
    db.run("UPDATE rl_shares SET name = ? WHERE id = ?", List.of(name, id));
  }

  /** Deleting a share is how it is revoked: the link stops working at once. */
  public void deleteShare(String id) {
    db.run("DELETE FROM rl_shares WHERE id = ?", List.of(id));
  }

  // Funnels

  public List<Map<String, Object>> funnels(String site) {
    return map(
        db.all("SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at, id", List.of(site)),
        r ->
            Json.object(
                "id", text(r.get("id")),
                "site", text(r.get("site")),
                "name", text(r.get("name")),
                "steps", Json.parse(text(r.get("steps"))),
                "createdAt", num(r.get("created_at"))));
  }

  public void saveFunnel(Map<String, Object> f) {
    db.run(
        Sql.upsert(
            db.dialect(),
            "rl_funnels",
            List.of("id", "site", "name", "steps", "created_at"),
            List.of("id"),
            List.of("name", "steps")),
        list(
            f.get("id"),
            f.get("site"),
            f.get("name"),
            Json.stringify(f.get("steps")),
            f.get("createdAt")));
  }

  public void deleteFunnel(String id) {
    db.run("DELETE FROM rl_funnels WHERE id = ?", List.of(id));
  }

  /**
   * How many visits reached each step, in order, within the same visit. Step one is the first
   * matching row in the range; each later step must come after the step before it. Filters choose
   * which visits enter the funnel.
   */
  public List<Object> funnelCounts(Map<String, Object> query, Map<String, Object> funnel) {
    // The rows of the picked visits that match any step, in order, read once and walked here.
    Sql.VisitRows v =
        Sql.visitRows(filters(query), site(query), from(query), to(query), db.dialect());
    List<Object> steps = Js.list(funnel.get("steps"));
    List<String> cases = new ArrayList<>();
    List<String> any = new ArrayList<>();
    List<Object> scopeParams = new ArrayList<>();
    for (int i = 0; i < steps.size(); i++) {
      Map<String, Object> step = Js.map(steps.get(i));
      Sql.Piece scope =
          goalScope(
              Json.object(
                  "kind", step.get("kind"), "match", step.get("match"), "name", step.get("match")));
      cases.add("CASE WHEN " + scope.sql() + " THEN 1 ELSE 0 END AS m" + i);
      any.add("(" + scope.sql() + ")");
      scopeParams.addAll(scope.params());
    }
    List<Map<String, Object>> rows =
        db.all(
            "SELECT e.session AS session, "
                + String.join(", ", cases)
                + "\n       FROM "
                + v.from()
                + " WHERE "
                + v.sql()
                + " AND ("
                + String.join(" OR ", any)
                + ")\n       ORDER BY e.session, e.ts, e.id",
            concat(scopeParams, v.params(), scopeParams));
    long[] counts = new long[steps.size()];
    Object session = null;
    boolean started = false;
    int reached = 0;
    for (Map<String, Object> row : rows) {
      if (!started || !Js.same(row.get("session"), session)) {
        for (int i = 0; i < reached; i++) {
          counts[i]++;
        }
        session = row.get("session");
        started = true;
        reached = 0;
      }
      // Each step is the first matching row after the step before, so two steps in the same
      // millisecond both count, and one row never counts as two steps.
      if (reached < counts.length && dnum(row.get("m" + reached)) == 1) {
        reached++;
      }
    }
    for (int i = 0; i < reached; i++) {
      counts[i]++;
    }
    List<Object> out = new ArrayList<>();
    for (long c : counts) {
      out.add(c);
    }
    return out;
  }

  /**
   * Each visit's pageviews in order, at most {@code perVisit} of them, for journeys: rows of
   * session and path, and whether the visits were sampled. Visits belong to the range they started
   * in.
   */
  public Map<String, Object> journeyPages(Map<String, Object> query, int perVisit) {
    Sql.Piece scope =
        Sql.visitScope(filters(query), site(query), from(query), to(query), db.dialect());
    // The newest visits the filters pick, JOURNEY_VISITS at most, so a long range stays quick.
    java.util.function.BiFunction<String, Integer, String> newest =
        (columns, limit) ->
            "SELECT "
                + columns
                + " FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND "
                + Sql.IS_VISIT
                + scope.sql()
                + "\n         ORDER BY s.started_at DESC, s.id LIMIT "
                + limit;
    List<Object> visitParams = concat(list(site(query), from(query), to(query)), scope.params());
    // How many there are, one past the cap telling whether it was reached, and when the oldest of
    // them began, so the rows are read from there on rather than from the start of a long range.
    Map<String, Object> firstRow =
        first(
            db.all(
                "SELECT COUNT(*) AS n, MIN(started_at) AS t FROM ("
                    + newest.apply("s.started_at AS started_at", Sql.JOURNEY_VISITS + 1)
                    + ") x",
                visitParams));
    if (dnum(at(firstRow, "n")) == 0) {
      return Json.object("rows", new ArrayList<>(), "sampled", false);
    }
    double fromAt = Math.max(from(query), dnum(at(firstRow, "t")));
    // MySQL takes no LIMIT in an IN list, but does in a table inside one.
    String visits =
        db.dialect().equals("mysql")
            ? "SELECT id FROM (" + newest.apply("s.id AS id", Sql.JOURNEY_VISITS) + ") x"
            : newest.apply("s.id", Sql.JOURNEY_VISITS);
    List<Map<String, Object>> rows =
        db.all(
            // The visits are read as an IN list, which every database probes from the events side.
            // Refreshes (the same page twice in a row) are dropped before counting.
            "WITH raw AS (\n         SELECT e.session AS session, e.path AS path, e.ts AS ts, e.id AS id,\n"
                + "           LAG(e.path) OVER (PARTITION BY e.session ORDER BY e.ts, e.id) AS prev\n         FROM rl_events e\n"
                + "         WHERE e.site = ? AND e.kind = 'pageview' AND e.ts >= ? AND e.ts < ? AND e.session IN ("
                + visits
                + ")),\n"
                + "       v AS (\n         SELECT session, path, ROW_NUMBER() OVER (PARTITION BY session ORDER BY ts, id) AS n\n"
                + "         FROM raw WHERE prev IS NULL OR prev <> path)\n       SELECT session, path FROM v WHERE n <= ? ORDER BY session, n",
            concat(
                list(site(query), Js.num(fromAt), to(query) + Sql.EVENT_TAIL_MS),
                visitParams,
                List.of(perVisit)));
    return Json.object(
        "rows",
        map(rows, r -> Json.object("session", text(r.get("session")), "path", text(r.get("path")))),
        "sampled",
        dnum(firstRow.get("n")) > Sql.JOURNEY_VISITS);
  }

  // API tokens

  private static Map<String, Object> tokenRow(Map<String, Object> r) {
    return Json.object(
        "id", text(r.get("id")),
        "name", text(r.get("name")),
        "site", text(r.get("site")),
        "scope", "manage".equals(r.get("scope")) ? "manage" : "read",
        "hash", text(r.get("hash")),
        "hint", text(r.get("hint")),
        "createdAt", num(r.get("created_at")),
        "lastUsedAt", r.get("last_used_at") == null ? null : num(r.get("last_used_at")));
  }

  public List<Map<String, Object>> tokens() {
    return map(db.all("SELECT * FROM rl_tokens ORDER BY created_at DESC, id"), SqlStore::tokenRow);
  }

  public Map<String, Object> tokenByHash(String hash) {
    Map<String, Object> row =
        first(db.all("SELECT * FROM rl_tokens WHERE hash = ?", List.of(hash)));
    return row == null ? null : tokenRow(row);
  }

  public void insertToken(Map<String, Object> t) {
    db.run(
        "INSERT INTO rl_tokens (id, name, site, scope, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        list(
            t.get("id"),
            t.get("name"),
            t.get("site"),
            t.get("scope"),
            t.get("hash"),
            t.get("hint"),
            t.get("createdAt"),
            t.get("lastUsedAt")));
  }

  public void touchToken(String id, long now) {
    db.run("UPDATE rl_tokens SET last_used_at = ? WHERE id = ?", list(now, id));
  }

  /** Deleting a token is how it is revoked: it stops working at once. */
  public boolean deleteToken(String id) {
    return changed("DELETE FROM rl_tokens WHERE id = ?", List.of(id)) == 1;
  }

  // Settings

  public String setting(String key) {
    Map<String, Object> row =
        first(db.all("SELECT value FROM rl_settings WHERE \"key\" = ?", List.of(key)));
    return row == null ? null : text(row.get("value"));
  }

  /**
   * Every setting whose key starts with a prefix, such as each connected install's: key and value.
   */
  public List<Map<String, Object>> settingsStartingWith(String prefix) {
    return map(
        db.all(
            "SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE ? ESCAPE '\\'",
            List.of(Sql.escapeLike(prefix) + "%")),
        r -> Json.object("key", text(r.get("key")), "value", text(r.get("value"))));
  }

  public void setSetting(String key, String value) {
    if (value == null) {
      db.run("DELETE FROM rl_settings WHERE \"key\" = ?", List.of(key));
    } else {
      db.run(
          Sql.upsert(
              db.dialect(),
              "rl_settings",
              List.of("\"key\"", "value"),
              List.of("\"key\""),
              List.of("value")),
          List.of(key, value));
    }
  }

  // Email reports

  private static Map<String, Object> reportRow(Map<String, Object> r) {
    return Json.object(
        "id", text(r.get("id")),
        "site", text(r.get("site")),
        "email", text(r.get("email")),
        "frequency", text(r.get("frequency")),
        "lang", str(r.get("lang"), "en"),
        "token", text(r.get("token")),
        "origin", text(r.get("origin")),
        "lastPeriod", text(r.get("last_period")),
        "lastSentAt", r.get("last_sent_at") == null ? null : num(r.get("last_sent_at")),
        "createdAt", num(r.get("created_at")));
  }

  public List<Map<String, Object>> reports(String site) {
    List<Map<String, Object>> rows =
        site != null && !site.isEmpty()
            ? db.all(
                "SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at, id", List.of(site))
            : db.all("SELECT * FROM rl_reports ORDER BY created_at, id");
    return map(rows, SqlStore::reportRow);
  }

  /** A report by "id" or by "token". */
  public Map<String, Object> reportBy(String field, String value) {
    Map<String, Object> row =
        first(
            db.all(
                "SELECT * FROM rl_reports WHERE " + (field.equals("id") ? "id" : "token") + " = ?",
                List.of(value)));
    return row == null ? null : reportRow(row);
  }

  public void insertReport(Map<String, Object> r) {
    db.run(
        "INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        list(
            r.get("id"),
            r.get("site"),
            r.get("email"),
            r.get("frequency"),
            r.get("lang"),
            r.get("token"),
            r.get("origin"),
            r.get("lastPeriod"),
            r.get("lastSentAt"),
            r.get("createdAt")));
  }

  /**
   * Records a period as sent. Only one caller wins, so two cron runs at once cannot both send it.
   */
  public boolean claimReport(String id, String period, long now) {
    return changed(
            "UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ?",
            list(period, now, id, period))
        == 1;
  }

  /** Puts a period back when its email failed, so the next run tries again. */
  public void releaseReport(String id, String period, String previous) {
    db.run(
        "UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?",
        List.of(previous, id, period));
  }

  public void deleteReport(String id) {
    db.run("DELETE FROM rl_reports WHERE id = ?", List.of(id));
  }

  // Goals

  public List<Map<String, Object>> goals(String site) {
    List<Map<String, Object>> rows =
        site != null && !site.isEmpty()
            ? db.all("SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at, id", List.of(site))
            : db.all("SELECT * FROM rl_goals ORDER BY created_at, id");
    return map(rows, Sql::goalRow);
  }

  public Map<String, Object> goalById(String id) {
    Map<String, Object> row = first(db.all("SELECT * FROM rl_goals WHERE id = ?", List.of(id)));
    return row == null ? null : Sql.goalRow(row);
  }

  public void saveGoal(Map<String, Object> g) {
    saveGoal(g, null);
  }

  public void saveGoal(Map<String, Object> g, Map<String, Object> before) {
    // A click goal is counted by its name, which the tracker sends as the event name. Renaming one
    // renames its past clicks too, so its history stays.
    if (before != null
        && "click".equals(before.get("kind"))
        && "click".equals(g.get("kind"))
        && !Js.same(before.get("name"), g.get("name"))) {
      db.run(
          "UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?",
          list(g.get("name"), g.get("site"), before.get("name")));
    }
    db.run(
        Sql.upsert(
            db.dialect(),
            "rl_goals",
            List.of(
                "id",
                "site",
                "name",
                "kind",
                "\"match\"",
                "click_by",
                "value_mode",
                "value",
                "value_prop",
                "currency",
                "created_at"),
            List.of("id"),
            List.of(
                "name",
                "kind",
                "\"match\"",
                "click_by",
                "value_mode",
                "value",
                "value_prop",
                "currency")),
        list(
            g.get("id"),
            g.get("site"),
            g.get("name"),
            g.get("kind"),
            g.get("match"),
            g.get("clickBy"),
            g.get("valueMode"),
            g.get("value"),
            g.get("valueProp"),
            g.get("currency"),
            g.get("createdAt")));
  }

  public void deleteGoal(String id) {
    db.run("DELETE FROM rl_goals WHERE id = ?", List.of(id));
  }

  /** The events a goal counts, as a WHERE fragment over rl_events e. */
  private Sql.Piece goalScope(Map<String, Object> goal) {
    String match = text(goal.get("match"));
    if ("page".equals(goal.get("kind"))) {
      if (!match.contains("*")) {
        return Sql.Piece.of("e.kind = 'pageview' AND e.path = ?", match);
      }
      return !db.dialect().equals("sqlite")
          // Postgres's LIKE heeds case, and so does MySQL's under Runlight's binary collation.
          ? Sql.Piece.of(
              "e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\\'", Sql.likePattern(match))
          // SQLite's LIKE ignores case; GLOB does not, so every database agrees.
          : Sql.Piece.of("e.kind = 'pageview' AND e.path GLOB ?", Sql.globPattern(match));
    }
    // Event goals count the named event; click goals count the event the tracker sends for them.
    return Sql.Piece.of(
        "e.kind = 'event' AND e.name = ?",
        "click".equals(goal.get("kind")) ? goal.get("name") : match);
  }

  /** A numeric event property for one row, as SQL (0 when it is not a number). */
  private Sql.Piece propValue(String prop) {
    if (db.dialect().equals("postgres")) {
      return Sql.Piece.of(
          "(CASE WHEN (e.props::jsonb ->> ?) ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)",
          prop,
          prop);
    }
    String path = "$.\"" + prop + "\"";
    if (db.dialect().equals("mysql")) {
      // As SQLite: a JSON number as it is, or text of digits with an optional sign and one decimal
      // point.
      String value = "JSON_EXTRACT(e.props, ?)";
      return new Sql.Piece(
          "(CASE\n          WHEN JSON_TYPE("
              + value
              + ") IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN CAST("
              + value
              + " AS DOUBLE)\n"
              + "          WHEN JSON_TYPE("
              + value
              + ") = 'STRING' AND JSON_UNQUOTE("
              + value
              + ") REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN CAST(JSON_UNQUOTE("
              + value
              + ") AS DOUBLE)\n"
              + "          ELSE 0 END)",
          new ArrayList<>(Collections.nCopies(5, path)));
    }
    // As Postgres's pattern: a JSON number, or text of digits with an optional sign and one decimal
    // point.
    String t = "CAST(json_extract(e.props, ?) AS TEXT)";
    return new Sql.Piece(
        "(CASE\n        WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)\n"
            + "        WHEN json_type(e.props, ?) = 'text' AND "
            + t
            + " GLOB '[0-9]*' AND "
            + t
            + " NOT GLOB '*[^0-9.]*' AND "
            + t
            + " NOT GLOB '*.*.*' AND "
            + t
            + " NOT GLOB '*.' THEN CAST("
            + t
            + " AS REAL)\n"
            + "        WHEN json_type(e.props, ?) = 'text' AND "
            + t
            + " GLOB '-[0-9]*' AND substr("
            + t
            + ", 2) NOT GLOB '*[^0-9.]*' AND "
            + t
            + " NOT GLOB '*.*.*' AND "
            + t
            + " NOT GLOB '*.' THEN CAST("
            + t
            + " AS REAL)\n"
            + "        ELSE 0 END)",
        new ArrayList<>(Collections.nCopies(14, path)));
  }

  /** The property names sent with an event in a query's range, most used first: key and events. */
  public List<Map<String, Object>> eventPropKeys(Map<String, Object> query, String event) {
    Sql.VisitRows v =
        Sql.visitRows(filters(query), site(query), from(query), to(query), db.dialect());
    String where = v.sql() + " AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL";
    List<Object> params = concat(v.params(), List.of(event));
    List<Map<String, Object>> rows =
        switch (db.dialect()) {
          // Each key as a row of its own, compared and sorted by code point like every other value.
          case "mysql" ->
              db.all(
                  "SELECT j.k AS \"key\", COUNT(*) AS events FROM "
                      + v.from()
                      + "\n"
                      + "             CROSS JOIN JSON_TABLE(JSON_KEYS(CASE WHEN JSON_TYPE(e.props) = 'OBJECT' THEN e.props ELSE '{}' END), '$[*]' COLUMNS (k VARCHAR(255) COLLATE "
                      + Sql.MYSQL_COLLATION
                      + " PATH '$')) j\n             WHERE "
                      + where
                      + " GROUP BY j.k ORDER BY events DESC, j.k LIMIT 30",
                  params);
          case "postgres" ->
              db.all(
                  "SELECT k AS \"key\", COUNT(*) AS events FROM "
                      + v.from()
                      + " CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{}'::jsonb END) AS k\n"
                      + "             WHERE "
                      + where
                      + " GROUP BY k ORDER BY events DESC, k"
                      + textOrder()
                      + " LIMIT 30",
                  params);
          default ->
              db.all(
                  "SELECT j.key AS \"key\", COUNT(*) AS events FROM "
                      + v.from()
                      + ", json_each(e.props) j\n             WHERE "
                      + where
                      + " AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key"
                      + textOrder()
                      + " LIMIT 30",
                  params);
        };
    return map(rows, r -> Json.object("key", text(r.get("key")), "events", num(r.get("events"))));
  }

  /** The values one property of an event took, with how often and by how many visitors. */
  public List<Map<String, Object>> eventPropValues(
      Map<String, Object> query, String event, String key, int limit) {
    Sql.VisitRows v =
        Sql.visitRows(filters(query), site(query), from(query), to(query), db.dialect());
    String value =
        switch (db.dialect()) {
          case "postgres" -> "(e.props::jsonb ->> ?)";
          case "mysql" ->
              "(JSON_UNQUOTE(JSON_EXTRACT(e.props, ?)) COLLATE " + Sql.MYSQL_COLLATION + ")";
          default -> "CAST(json_extract(e.props, ?) AS TEXT)";
        };
    String path = db.dialect().equals("postgres") ? key : "$.\"" + key + "\"";
    List<Map<String, Object>> rows =
        db.all(
            "SELECT * FROM (SELECT "
                + value
                + " AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM "
                + v.from()
                + "\n"
                + "         WHERE "
                + v.sql()
                + " AND e.kind = 'event' AND e.name = ? AND "
                + value
                + " IS NOT NULL GROUP BY 1) t\n"
                + "       ORDER BY events DESC, value"
                + textOrder()
                + " LIMIT ?",
            concat(List.of(path), v.params(), list(event, path, limit)));
    return map(
        rows,
        r ->
            Json.object(
                "value",
                text(r.get("value")),
                "events",
                num(r.get("events")),
                "visitors",
                num(r.get("visitors"))));
  }

  /** The floating point type to cast to, which MySQL names in one word. */
  private String doubleType() {
    return db.dialect().equals("mysql") ? "DOUBLE" : "DOUBLE PRECISION";
  }

  /** A goal's worth for one converting row, as SQL. */
  private Sql.Piece revenueValue(Map<String, Object> goal) {
    if ("prop".equals(goal.get("valueMode")) && !text(goal.get("valueProp")).isEmpty()) {
      return propValue(text(goal.get("valueProp")));
    }
    if ("fixed".equals(goal.get("valueMode"))) {
      return Sql.Piece.of("CAST(? AS " + doubleType() + ")", goal.get("value"));
    }
    return new Sql.Piece("0", new ArrayList<>());
  }

  /** Math.round(n * 100) / 100, for money. */
  private static Object cents(double n) {
    return whole(Js.round(n * 100) / 100);
  }

  /**
   * Every goal's totals in one pass over the range's events, instead of a query per goal: each goal
   * adds a conditional count, distinct count, and sum. Keyed by goal id.
   */
  public Map<String, Map<String, Object>> goalTotalsAll(
      Map<String, Object> query, List<Map<String, Object>> goals) {
    Map<String, Map<String, Object>> out = new LinkedHashMap<>();
    Sql.VisitRows v =
        Sql.visitRows(filters(query), site(query), from(query), to(query), db.dialect());
    // As many goals per query as keep it under D1's parameter limit.
    List<List<Map<String, Object>>> chunks = new ArrayList<>();
    chunks.add(new ArrayList<>());
    int count = v.params().size();
    for (Map<String, Object> goal : goals) {
      int cost = goalScope(goal).params().size() * 4 + revenueValue(goal).params().size();
      if (!chunks.get(chunks.size() - 1).isEmpty() && count + cost > Sql.MAX_PARAMS) {
        chunks.add(new ArrayList<>());
        count = v.params().size();
      }
      chunks.get(chunks.size() - 1).add(goal);
      count += cost;
    }
    for (List<Map<String, Object>> chunk : chunks) {
      if (chunk.isEmpty()) {
        continue;
      }
      List<String> columns = new ArrayList<>();
      List<Object> params = new ArrayList<>();
      // Only rows some goal of the chunk counts are read.
      List<String> any = new ArrayList<>();
      List<Object> anyParams = new ArrayList<>();
      for (int i = 0; i < chunk.size(); i++) {
        Sql.Piece scope = goalScope(chunk.get(i));
        Sql.Piece value = revenueValue(chunk.get(i));
        columns.add("SUM(CASE WHEN " + scope.sql() + " THEN 1 ELSE 0 END) AS c" + i);
        columns.add("COUNT(DISTINCT CASE WHEN " + scope.sql() + " THEN e.visitor END) AS v" + i);
        columns.add(
            "SUM(CASE WHEN " + scope.sql() + " THEN " + value.sql() + " ELSE 0 END) AS r" + i);
        params.addAll(scope.params());
        params.addAll(scope.params());
        params.addAll(scope.params());
        params.addAll(value.params());
        any.add("(" + scope.sql() + ")");
        anyParams.addAll(scope.params());
      }
      Map<String, Object> row =
          first(
              db.all(
                  "SELECT "
                      + String.join(", ", columns)
                      + " FROM "
                      + v.from()
                      + "\n         WHERE "
                      + v.sql()
                      + " AND e.kind IN ('pageview', 'event') AND ("
                      + String.join(" OR ", any)
                      + ")",
                  concat(params, v.params(), anyParams)));
      for (int i = 0; i < chunk.size(); i++) {
        out.put(
            text(chunk.get(i).get("id")),
            Json.object(
                "conversions", num(at(row, "c" + i)),
                "visitors", num(at(row, "v" + i)),
                "revenue", cents(dnum(at(row, "r" + i)))));
      }
    }
    return out;
  }

  private Sql.Piece revenueSql(Map<String, Object> goal) {
    if ("prop".equals(goal.get("valueMode")) && !text(goal.get("valueProp")).isEmpty()) {
      Sql.Piece value = propValue(text(goal.get("valueProp")));
      return new Sql.Piece("SUM(" + value.sql() + ")", value.params());
    }
    // Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
    if ("fixed".equals(goal.get("valueMode"))) {
      return Sql.Piece.of("COUNT(*) * CAST(? AS " + doubleType() + ")", goal.get("value"));
    }
    return new Sql.Piece("0", new ArrayList<>());
  }

  /** One goal's conversions, converting visitors, and revenue for a query's range and filters. */
  public Map<String, Object> goalTotals(Map<String, Object> query, Map<String, Object> goal) {
    Sql.VisitRows v =
        Sql.visitRows(filters(query), site(query), from(query), to(query), db.dialect());
    Sql.Piece scope = goalScope(goal);
    Sql.Piece revenue = revenueSql(goal);
    Map<String, Object> row =
        first(
            db.all(
                "SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, "
                    + revenue.sql()
                    + " AS revenue\n       FROM "
                    + v.from()
                    + " WHERE "
                    + v.sql()
                    + " AND "
                    + scope.sql(),
                concat(revenue.params(), v.params(), scope.params())));
    return Json.object(
        "conversions",
        num(at(row, "conversions")),
        "visitors",
        num(at(row, "visitors")),
        "revenue",
        cents(dnum(at(row, "revenue"))));
  }

  public List<Map<String, Object>> goalBreakdown(
      Map<String, Object> query, Map<String, Object> goal, String by) {
    return goalBreakdown(query, goal, by, 10);
  }

  /**
   * A goal's conversions split by where the visit came from (source, channel), or by the page
   * (path).
   */
  public List<Map<String, Object>> goalBreakdown(
      Map<String, Object> query, Map<String, Object> goal, String by, int limit) {
    Sql.VisitRows v =
        Sql.visitRows(filters(query), site(query), from(query), to(query), db.dialect());
    String col = by.equals("path") ? "e.path" : "s." + by;
    Sql.Piece scope = goalScope(goal);
    Sql.Piece revenue = revenueSql(goal);
    List<Map<String, Object>> rows =
        db.all(
            "SELECT "
                + col
                + " AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, "
                + revenue.sql()
                + " AS revenue\n"
                + "       FROM "
                + v.from()
                + " WHERE "
                + v.sql()
                + " AND "
                + scope.sql()
                + "\n       GROUP BY "
                + col
                + " ORDER BY conversions DESC, "
                + col
                + textOrder()
                + " LIMIT ?",
            concat(revenue.params(), v.params(), scope.params(), List.of(limit)));
    return map(
        rows,
        r ->
            Json.object(
                "value", text(r.get("value")),
                "conversions", num(r.get("conversions")),
                "visitors", num(r.get("visitors")),
                "revenue", cents(dnum(r.get("revenue")))));
  }

  /** A goal's conversions and revenue in each bucket, by when each visit started. */
  public List<Map<String, Object>> goalSeries(
      Map<String, Object> query, Map<String, Object> goal, List<Map<String, Object>> buckets) {
    if (buckets.isEmpty()) {
      return new ArrayList<>();
    }
    Sql.Piece scope = goalScope(goal);
    Sql.Piece revenue = revenueSql(goal);
    // Each bucket binds three values; the rest are fixed. As many buckets a statement as keep it
    // under D1's 100.
    int fixed =
        revenue.params().size()
            + scope.params().size()
            + Sql.visitRows(filters(query), site(query), 0, 0, db.dialect()).params().size();
    int size = Math.max(1, Math.min(Sql.BUCKETS_PER_QUERY, (Sql.MAX_PARAMS - fixed) / 3));
    if (buckets.size() > size) {
      return Sql.inPieces(buckets, size, piece -> goalSeries(query, goal, piece));
    }
    Map<String, Object> last = buckets.get(buckets.size() - 1);
    Sql.VisitRows v =
        Sql.visitRows(
            filters(query),
            site(query),
            Js.asLong(buckets.get(0).get("start")),
            Js.asLong(last.get("end")),
            db.dialect());
    List<Map<String, Object>> rows =
        db.all(
            "WITH b (i, bs, be) AS ("
                + Sql.bucketTable(db.dialect(), buckets.size())
                + ")\n       SELECT b.i AS i, COUNT(*) AS conversions, "
                + revenue.sql()
                + " AS revenue\n       FROM "
                + v.from()
                + " CROSS JOIN b\n       WHERE "
                + v.sql()
                + " AND s.started_at >= b.bs AND s.started_at < b.be AND "
                + scope.sql()
                + "\n       GROUP BY b.i",
            concat(bucketParams(buckets), revenue.params(), v.params(), scope.params()));
    Map<Integer, Map<String, Object>> found = new HashMap<>();
    for (Map<String, Object> r : rows) {
      found.put((int) dnum(r.get("i")), r);
    }
    List<Map<String, Object>> out = new ArrayList<>();
    for (int i = 0; i < buckets.size(); i++) {
      Map<String, Object> r = found.get(i);
      out.add(
          Json.object(
              "start",
              buckets.get(i).get("start"),
              "conversions",
              num(at(r, "conversions")),
              "revenue",
              cents(dnum(at(r, "revenue")))));
    }
    return out;
  }

  private static List<Object> bucketParams(List<Map<String, Object>> buckets) {
    List<Object> params = new ArrayList<>();
    for (int i = 0; i < buckets.size(); i++) {
      params.add((long) i);
      params.add(Js.num(buckets.get(i).get("start")));
      params.add(Js.num(buckets.get(i).get("end")));
    }
    return params;
  }

  public List<Map<String, Object>> linkDomains() {
    return map(
        db.all("SELECT domain, site FROM rl_link_domains ORDER BY domain"),
        r -> Json.object("domain", text(r.get("domain")), "site", text(r.get("site"))));
  }

  public void addLinkDomain(String domain, String site, long now) {
    db.run(
        Sql.upsert(
            db.dialect(),
            "rl_link_domains",
            List.of("domain", "site", "created_at"),
            List.of("domain"),
            List.of()),
        list(domain, site, now));
  }

  /**
   * Removes a domain. Its links keep it as their home and fall back to the app's own link path
   * until the domain is added again.
   */
  public void removeLinkDomain(String domain) {
    db.run("DELETE FROM rl_link_domains WHERE domain = ?", List.of(domain));
  }

  /**
   * A site's links, newest first, with their clicks in a range. Clicks imported as daily counts
   * have no visitor, so they add to clicks only.
   */
  public List<Map<String, Object>> links(String site, long from, long to) {
    List<Map<String, Object>> rows =
        db.all(
            "SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors\n       FROM rl_links l LEFT JOIN (\n"
                + "         SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events\n"
                + "         WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link\n       ) c ON c.link = l.id\n"
                + "       WHERE l.site = ? AND l.deleted_at IS NULL\n       ORDER BY l.created_at DESC, l.id",
            list(site, from, to, site));
    return map(
        rows,
        row -> {
          Map<String, Object> link = Sql.linkRow(row);
          link.put("clicks", num(row.get("clicks")));
          link.put("visitors", num(row.get("visitors")));
          return link;
        });
  }

  /** One link's clicks per bucket. */
  public List<Map<String, Object>> linkSeries(
      String site, String link, List<Map<String, Object>> buckets) {
    if (buckets.isEmpty()) {
      return new ArrayList<>();
    }
    if (buckets.size() > Sql.BUCKETS_PER_QUERY) {
      return Sql.inPieces(buckets, Sql.BUCKETS_PER_QUERY, piece -> linkSeries(site, link, piece));
    }
    List<Map<String, Object>> rows =
        db.all(
            "WITH b (i, bs, be) AS ("
                + Sql.bucketTable(db.dialect(), buckets.size())
                + ")\n"
                + "       SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors\n"
                + "       FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be\n"
                + "       WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i",
            concat(bucketParams(buckets), List.of(link, site)));
    Map<Integer, Map<String, Object>> found = new HashMap<>();
    for (Map<String, Object> r : rows) {
      found.put((int) dnum(r.get("i")), r);
    }
    List<Map<String, Object>> out = new ArrayList<>();
    for (int i = 0; i < buckets.size(); i++) {
      Map<String, Object> r = found.get(i);
      out.add(
          Json.object(
              "start",
              buckets.get(i).get("start"),
              "clicks",
              num(at(r, "clicks")),
              "visitors",
              num(at(r, "visitors"))));
    }
    return out;
  }

  /**
   * One link's clicks by a visit dimension: where they came from, where they were, what they used.
   */
  public List<Map<String, Object>> linkBreakdown(
      String site, String link, long from, long to, String dimension, int limit) {
    String col = "s." + Query.SESSION_DIMENSIONS.get(dimension);
    List<Map<String, Object>> rows =
        db.all(
            "SELECT "
                + col
                + " AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors\n"
                + "       FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n"
                + "       WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND "
                + col
                + " <> ''\n"
                + "       GROUP BY "
                + col
                + " ORDER BY clicks DESC, "
                + col
                + textOrder()
                + " LIMIT ?",
            list(site, link, from, to, limit));
    return map(
        rows,
        row ->
            Json.object(
                "value",
                text(row.get("value")),
                "visitors",
                num(row.get("visitors")),
                "events",
                num(row.get("clicks"))));
  }

  // Reports

  /**
   * Ties are broken by the value in code point order, the order the rolled-up path sorts in, so a
   * report reads the same before and after its days are built.
   */
  private String textOrder() {
    return switch (db.dialect()) {
      case "postgres" -> " COLLATE \"C\"";
      case "mysql" -> " COLLATE " + Sql.MYSQL_COLLATION;
      default -> "";
    };
  }

  /** When Runlight itself first counted a visit, leaving out imported history. */
  public Object firstOwnVisit(String site) {
    // A session opened only by a short link click is not a visit, so it does not count as the
    // first.
    Map<String, Object> row =
        first(
            db.all(
                "SELECT MIN(started_at) AS t FROM rl_sessions s WHERE s.site = ? AND s.imported = 0 AND "
                    + Sql.IS_VISIT,
                List.of(site)));
    return row == null || row.get("t") == null ? null : num(row.get("t"));
  }

  /** When the site's first visit was recorded, or null with no data yet. */
  public Object firstSeen(String site) {
    Map<String, Object> row =
        first(db.all("SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?", List.of(site)));
    return row == null || row.get("t") == null ? null : num(row.get("t"));
  }

  /** Just the visitor count from stats(), in one query, for conversion rates. */
  public Object visitors(Map<String, Object> query) {
    Sql.Piece scope =
        Sql.visitScope(filters(query), site(query), from(query), to(query), db.dialect());
    Map<String, Object> row =
        first(
            db.all(
                "SELECT COUNT(DISTINCT s.visitor) AS visitors FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND "
                    + Sql.IS_VISIT
                    + scope.sql(),
                concat(list(site(query), from(query), to(query)), scope.params())));
    return num(at(row, "visitors"));
  }

  /**
   * The headline numbers: visitors, visits, pageviews, viewsPerVisit, bounceRate, visitDuration.
   */
  public Map<String, Object> stats(Map<String, Object> query) {
    Map<String, Object> rolled = rolledStats(query);
    if (rolled != null) {
      return rolled;
    }
    // Filtered or not, the numbers describe visits that started in the range (see visitScope).
    Sql.Piece scope =
        Sql.visitScope(filters(query), site(query), from(query), to(query), db.dialect());
    Sql.Piece pv =
        Sql.pageviewsOf(filters(query), site(query), from(query), to(query), db.dialect());
    Map<String, Object> row =
        first(
            db.all(
                "SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM("
                    + (pv != null ? "COALESCE(pv.n, 0)" : "s.pageviews")
                    + ") AS pageviews,\n"
                    + "         SUM(CASE WHEN "
                    + Sql.BOUNCE
                    + " THEN 1 ELSE 0 END) AS bounced, SUM("
                    + Sql.DURATION
                    + ") AS duration\n"
                    + "       FROM rl_sessions s "
                    + (pv != null ? "LEFT JOIN " + pv.sql() + " pv ON pv.session = s.id" : "")
                    + "\n"
                    + "       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND "
                    + Sql.IS_VISIT
                    + scope.sql(),
                concat(
                    pv != null ? pv.params() : List.of(),
                    list(site(query), from(query), to(query)),
                    scope.params())));
    return statsOf(
        dnum(at(row, "visitors")),
        dnum(at(row, "visits")),
        dnum(at(row, "pageviews")),
        dnum(at(row, "bounced")),
        dnum(at(row, "duration")));
  }

  /**
   * The chart: each bucket's visitors, visits, pageviews, viewsPerVisit, bounceRate, visitDuration.
   */
  public List<Map<String, Object>> series(
      Map<String, Object> query, List<Map<String, Object>> buckets) {
    if (buckets.isEmpty()) {
      return new ArrayList<>();
    }
    if (buckets.size() > Sql.BUCKETS_PER_QUERY) {
      return Sql.inPieces(buckets, Sql.BUCKETS_PER_QUERY, piece -> series(query, piece));
    }
    List<Object> params = bucketParams(buckets);
    long firstStart = Js.asLong(buckets.get(0).get("start"));
    long lastEnd = Js.asLong(buckets.get(buckets.size() - 1).get("end"));
    String dialect = db.dialect();
    // Filtered or not, each bucket counts the visits that started in it (see visitScope).
    Sql.Piece scope = Sql.visitScope(filters(query), site(query), firstStart, lastEnd, dialect);
    Sql.Piece pv = Sql.pageviewsOf(filters(query), site(query), firstStart, lastEnd, dialect);
    // Built days that fit inside one bucket come from rollups; the rest from the visits.
    Plan plan = rollupPlan(query, firstStart, lastEnd);
    Function<Day, Integer> inBucket =
        d -> {
          for (int i = 0; i < buckets.size(); i++) {
            Map<String, Object> b = buckets.get(i);
            if (dnum(b.get("start")) <= d.start() && d.end() <= dnum(b.get("end"))) {
              return i;
            }
          }
          return -1;
        };
    List<Day> used = new ArrayList<>();
    if (plan != null) {
      for (Day d : plan.days()) {
        if (inBucket.apply(d) >= 0) {
          used.add(d);
        }
      }
    }
    List<double[]> rest = null;
    if (!used.isEmpty()) {
      rest = new ArrayList<>();
      double at = firstStart;
      for (Day d : used) {
        if (d.start() > at) {
          rest.add(new double[] {at, d.start()});
        }
        at = Math.max(at, d.end());
      }
      if (at < lastEnd) {
        rest.add(new double[] {at, lastEnd});
      }
    }
    // MySQL joins the buckets to every visit of the site unless told the whole range as well.
    Sql.Piece w =
        rest != null
            ? within(rest)
            : dialect.equals("mysql")
                ? within(List.<double[]>of(new double[] {firstStart, lastEnd}))
                : new Sql.Piece("1 = 1", new ArrayList<>());
    // Filters and scattered unbuilt days add values of their own; when they would pass D1's 100,
    // the
    // buckets go in halves.
    if (params.size()
                + 1
                + w.params().size()
                + scope.params().size()
                + (pv != null ? pv.params().size() : 0)
            > Sql.MAX_PARAMS
        && buckets.size() > 1) {
      int half = (buckets.size() + 1) / 2;
      List<Map<String, Object>> out = new ArrayList<>(series(query, buckets.subList(0, half)));
      out.addAll(series(query, buckets.subList(half, buckets.size())));
      return out;
    }
    List<String> keys = List.of("visitors", "n", "views", "bounced", "duration");
    Map<Integer, Map<String, Double>> sums = new HashMap<>();
    java.util.function.BiConsumer<Integer, Map<String, Object>> bump =
        (i, row) -> {
          Map<String, Double> into = sums.computeIfAbsent(i, k -> zeros(keys));
          for (String k : keys) {
            into.put(k, into.get(k) + dnum(row.get(k)));
          }
        };
    if (!used.isEmpty()) {
      List<Map<String, Object>> rolled =
          db.all(
              "SELECT day, visitors, visits AS n, pageviews AS views, bounced, duration FROM rl_rollups WHERE site = ? AND dim = '' AND day IN ("
                  + Sql.BUILT_DAYS
                  + ")",
              list(site(query), site(query), firstStart, lastEnd));
      Map<String, Integer> where = new HashMap<>();
      for (Day d : used) {
        where.put(d.day(), inBucket.apply(d));
      }
      for (Map<String, Object> row : rolled) {
        Integer i = where.get(text(row.get("day")));
        if (i != null) {
          bump.accept(i, row);
        }
      }
    }
    List<Map<String, Object>> rows =
        db.all(
            "WITH b (i, bs, be) AS ("
                + Sql.bucketTable(dialect, buckets.size())
                + ")\n"
                + "       SELECT b.i AS i, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS n, SUM("
                + (pv != null ? "COALESCE(pv.n, 0)" : "s.pageviews")
                + ") AS views,\n"
                + "         SUM(CASE WHEN "
                + Sql.BOUNCE
                + " THEN 1 ELSE 0 END) AS bounced, SUM("
                + Sql.DURATION
                + ") AS duration\n"
                + "       FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be\n"
                + "       "
                + (pv != null ? "LEFT JOIN " + pv.sql() + " pv ON pv.session = s.id" : "")
                + "\n"
                + "       WHERE "
                + Sql.IS_VISIT
                + scope.sql()
                + " AND "
                + w.sql()
                + "\n       GROUP BY b.i",
            concat(
                params,
                List.of(site(query)),
                pv != null ? pv.params() : List.of(),
                scope.params(),
                w.params()));
    for (Map<String, Object> row : rows) {
      bump.accept((int) dnum(row.get("i")), row);
    }
    List<Map<String, Object>> out = new ArrayList<>();
    for (int i = 0; i < buckets.size(); i++) {
      Map<String, Double> row = sums.getOrDefault(i, zeros(keys));
      double n = row.get("n");
      double views = row.get("views");
      out.add(
          Json.object(
              "start", buckets.get(i).get("start"),
              "visitors", Js.num(row.get("visitors")),
              "visits", Js.num(n),
              "pageviews", Js.num(views),
              "viewsPerVisit", n > 0 ? whole(Js.round((views / n) * 100) / 100) : 0L,
              "bounceRate", n > 0 ? whole(row.get("bounced") / n) : 0L,
              "visitDuration", n > 0 ? whole(Js.round(row.get("duration") / n)) : 0L));
    }
    return out;
  }

  /** One breakdown's rows (BreakdownRow), sorted and cut to the page asked for. */
  public List<Map<String, Object>> breakdown(
      Map<String, Object> query, String dimension, int limit, int offset) {
    List<Object> page = list(limit, offset);
    String dialect = db.dialect();
    if (dimension.equals("ai_agent") || dimension.equals("ai_page")) {
      String col = dimension.equals("ai_agent") ? "e.name" : "e.path";
      List<Map<String, Object>> rows =
          db.all(
              "SELECT "
                  + col
                  + " AS value, COUNT(*) AS fetches FROM rl_events e\n         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'\n"
                  + "         GROUP BY "
                  + col
                  + " ORDER BY fetches DESC, "
                  + col
                  + textOrder()
                  + " LIMIT ? OFFSET ?",
              concat(list(site(query), from(query), to(query)), page));
      return map(
          rows,
          row ->
              Json.object(
                  "value",
                  text(row.get("value")),
                  "visitors",
                  0L,
                  "fetches",
                  num(row.get("fetches"))));
    }

    List<Map<String, Object>> rolled = rolledBreakdown(query, dimension, limit, offset);
    if (rolled != null) {
      return rolled;
    }

    // Filtered or not, the visits are those that started in the range (see visitScope).
    Sql.Piece scope = Sql.visitScope(filters(query), site(query), from(query), to(query), dialect);
    if (Query.isSessionDimension(dimension)) {
      Sql.Piece pv = Sql.pageviewsOf(filters(query), site(query), from(query), to(query), dialect);
      String col = "s." + Query.SESSION_DIMENSIONS.get(dimension);
      boolean entryExit = dimension.equals("entry") || dimension.equals("exit");
      List<Map<String, Object>> rows =
          db.all(
              "SELECT "
                  + col
                  + " AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM("
                  + (pv != null ? "COALESCE(pv.n, 0)" : "s.pageviews")
                  + ") AS pageviews,\n"
                  + "           SUM(CASE WHEN "
                  + Sql.BOUNCE
                  + " THEN 1 ELSE 0 END) AS bounced, SUM("
                  + Sql.DURATION
                  + ") AS duration\n"
                  + "         FROM rl_sessions s "
                  + (pv != null ? "LEFT JOIN " + pv.sql() + " pv ON pv.session = s.id" : "")
                  + "\n"
                  + "         WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND "
                  + Sql.IS_VISIT
                  + scope.sql()
                  + " AND "
                  + col
                  + " <> ''\n"
                  + "         GROUP BY "
                  + col
                  + " ORDER BY "
                  + (entryExit ? "visits DESC" : "visitors DESC, visits DESC")
                  + ", "
                  + col
                  + textOrder()
                  + " LIMIT ? OFFSET ?",
              concat(
                  pv != null ? pv.params() : List.of(),
                  list(site(query), from(query), to(query)),
                  scope.params(),
                  page));
      return map(
          rows,
          row -> {
            double visits = dnum(row.get("visits"));
            Map<String, Object> out =
                Json.object(
                    "value", text(row.get("value")),
                    "visitors", num(row.get("visitors")),
                    "visits", Js.num(visits),
                    "bounceRate", visits > 0 ? whole(dnum(row.get("bounced")) / visits) : 0L);
            if (!entryExit) {
              out.put("pageviews", num(row.get("pageviews")));
              out.put(
                  "visitDuration",
                  visits > 0 ? whole(Js.round(dnum(row.get("duration")) / visits)) : 0L);
            }
            return out;
          });
    }

    // Rows from the visits that started in the range and that the filters pick, narrowed by any
    // filter on the same kind of row ("page is /pricing" on pages), as the rollups count them.
    Function<List<String>, Object[]> within =
        dimensions -> {
          Sql.Piece rows = Sql.rowScope(filters(query), dimensions, dialect);
          return new Object[] {
            " AND e.session IN (SELECT s.id FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND "
                + Sql.IS_VISIT
                + scope.sql()
                + ")"
                + rows.sql(),
            concat(list(site(query), from(query), to(query)), scope.params(), rows.params()),
            to(query) + Sql.EVENT_TAIL_MS
          };
        };

    if (dimension.equals("page") || dimension.equals("hostname")) {
      String col = "e." + Query.EVENT_DIMENSIONS.get(dimension);
      Object[] w = within.apply(List.of("page", "hostname"));
      @SuppressWarnings("unchecked")
      List<Object> wParams = (List<Object>) w[1];
      List<Map<String, Object>> rows =
          db.all(
              "SELECT "
                  + col
                  + " AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews, "
                  + Sql.LIVE_VIEWS
                  + " AS views\n"
                  + "         FROM rl_events e\n         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'"
                  + w[0]
                  + "\n"
                  + "         GROUP BY "
                  + col
                  + " ORDER BY visitors DESC, pageviews DESC, "
                  + col
                  + textOrder()
                  + " LIMIT ? OFFSET ?",
              concat(list(site(query), from(query), w[2]), wParams, page));
      List<Map<String, Object>> out =
          map(
              rows,
              row ->
                  Json.object(
                      "value",
                      text(row.get("value")),
                      "visitors",
                      num(row.get("visitors")),
                      "pageviews",
                      num(row.get("pageviews"))));
      Map<String, Double> live = new HashMap<>();
      for (Map<String, Object> row : rows) {
        live.put(text(row.get("value")), dnum(row.get("views")));
      }
      if (dimension.equals("page") && !out.isEmpty()) {
        // Each pageview's engaged time added up and its deepest scroll, then the mean over
        // pageviews. Filters add values of their own, so fewer paths go in each statement.
        int size = Math.max(1, Math.min(Sql.VALUES_PER_QUERY, Sql.MAX_PARAMS - 3 - wParams.size()));
        List<Map<String, Object>> times =
            Sql.inPieces(
                out,
                size,
                piece -> {
                  List<Object> values = new ArrayList<>();
                  for (Map<String, Object> r : piece) {
                    values.add(r.get("value"));
                  }
                  return db.all(
                      "SELECT value, SUM(total) AS total, COUNT(*) AS views, AVG(deepest) AS scroll FROM (\n"
                          + "               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest\n"
                          + "               FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'"
                          + w[0]
                          + "\n"
                          + "               AND e.path IN ("
                          + String.join(", ", Collections.nCopies(piece.size(), "?"))
                          + ") GROUP BY e.path, e.pageview) t GROUP BY value",
                      concat(list(site(query), from(query), w[2]), wParams, values));
                });
        Map<String, Map<String, Object>> byPath = new HashMap<>();
        for (Map<String, Object> t : times) {
          byPath.put(text(t.get("value")), t);
        }
        for (Map<String, Object> row : out) {
          Map<String, Object> time = byPath.get((String) row.get("value"));
          double views = live.getOrDefault((String) row.get("value"), 0.0);
          row.put(
              "timeOnPage",
              time != null && views != 0 ? whole(Js.round(dnum(time.get("total")) / views)) : 0L);
          row.put(
              "scrollDepth",
              time == null || time.get("scroll") == null
                  ? 0L
                  : whole(Js.round(dnum(time.get("scroll")))));
        }
      }
      return out;
    }

    if (dimension.equals("event")) {
      Object[] w = within.apply(List.of("event"));
      @SuppressWarnings("unchecked")
      List<Object> wParams = (List<Object>) w[1];
      List<Map<String, Object>> rows =
          db.all(
              "SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events\n         FROM rl_events e\n"
                  + "         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'"
                  + w[0]
                  + "\n"
                  + "         GROUP BY e.name ORDER BY visitors DESC, events DESC, e.name"
                  + textOrder()
                  + " LIMIT ? OFFSET ?",
              concat(list(site(query), from(query), w[2]), wParams, page));
      return map(
          rows,
          row ->
              Json.object(
                  "value",
                  text(row.get("value")),
                  "visitors",
                  num(row.get("visitors")),
                  "events",
                  num(row.get("events"))));
    }

    return new ArrayList<>();
  }

  /**
   * Visits by quarter hour since the epoch, which the caller folds into local weekdays and hours,
   * keeping time zones (DST included) out of SQL: quarter, visits, visitors, pageviews, bounced.
   */
  public List<Map<String, Object>> hourly(Map<String, Object> query) {
    String dialect = db.dialect();
    Plan plan = rollupPlan(query, from(query), to(query));
    if (plan != null) {
      Map<String, Map<String, Object>> sums = new LinkedHashMap<>();
      java.util.function.BiConsumer<Object, Map<String, Object>> bump =
          (quarter, row) -> {
            String key = text(quarter);
            Map<String, Object> into =
                sums.computeIfAbsent(
                    key,
                    k ->
                        Json.object(
                            "quarter",
                            quarter,
                            "visits",
                            0L,
                            "visitors",
                            0L,
                            "pageviews",
                            0L,
                            "bounced",
                            0L));
            for (String k : List.of("visits", "visitors", "pageviews", "bounced")) {
              into.put(k, Js.num(dnum(into.get(k)) + dnum(row.get(k))));
            }
          };
      List<Map<String, Object>> rolled =
          db.all(
              "SELECT value, visits, visitors, pageviews, bounced FROM rl_rollups WHERE site = ? AND dim = 'quarter' AND day IN ("
                  + Sql.BUILT_DAYS
                  + ")",
              list(site(query), site(query), from(query), to(query)));
      for (Map<String, Object> row : rolled) {
        bump.accept(Js.num(Js.toNumber(text(row.get("value")))), row);
      }
      Sql.Piece w = within(plan.rest());
      List<Map<String, Object>> raw =
          db.all(
              "SELECT "
                  + Sql.div(dialect, "s.started_at", 900000)
                  + " AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,\n"
                  + "           SUM(s.pageviews) AS pageviews, SUM(CASE WHEN "
                  + Sql.BOUNCE
                  + " THEN 1 ELSE 0 END) AS bounced\n"
                  + "         FROM rl_sessions s WHERE s.site = ? AND "
                  + w.sql()
                  + " AND "
                  + Sql.IS_VISIT
                  + " GROUP BY 1",
              concat(List.of(site(query)), w.params()));
      for (Map<String, Object> row : raw) {
        bump.accept(whole(Math.floor(dnum(row.get("quarter")))), row);
      }
      return new ArrayList<>(sums.values());
    }
    Sql.Piece matching =
        Sql.visitScope(filters(query), site(query), from(query), to(query), dialect);
    // A page filter counts that page's views as pageviews here too, as the cards do.
    Sql.Piece pv = Sql.pageviewsOf(filters(query), site(query), from(query), to(query), dialect);
    List<Map<String, Object>> rows =
        db.all(
            "SELECT "
                + Sql.div(dialect, "s.started_at", 900000)
                + " AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,\n"
                + "         SUM("
                + (pv != null ? "COALESCE(pv.n, 0)" : "s.pageviews")
                + ") AS pageviews, SUM(CASE WHEN "
                + Sql.BOUNCE
                + " THEN 1 ELSE 0 END) AS bounced\n"
                + "       FROM rl_sessions s "
                + (pv != null ? "LEFT JOIN " + pv.sql() + " pv ON pv.session = s.id" : "")
                + "\n"
                + "       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND "
                + Sql.IS_VISIT
                + matching.sql()
                + "\n       GROUP BY 1",
            concat(
                pv != null ? pv.params() : List.of(),
                list(site(query), from(query), to(query)),
                matching.params()));
    return map(
        rows,
        row ->
            Json.object(
                "quarter", whole(Math.floor(dnum(row.get("quarter")))),
                "visits", num(row.get("visits")),
                "visitors", num(row.get("visitors")),
                "pageviews", num(row.get("pageviews")),
                "bounced", num(row.get("bounced"))));
  }

  /** The last few minutes: visitors, pages, sources, countries, minutes, and recent rows. */
  public Map<String, Object> realtime(String site, long now) {
    long since = now - 5 * 60_000;
    Map<String, Object> active =
        first(
            db.all(
                "SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')",
                list(site, since)));
    List<Map<String, Object>> pages =
        db.all(
            "SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events\n       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, path"
                + textOrder()
                + " LIMIT 10",
            list(site, since));
    List<Map<String, Object>> sources =
        db.all(
            "SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n"
                + "       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''\n"
                + "       GROUP BY s.source ORDER BY visitors DESC, s.source"
                + textOrder()
                + " LIMIT 10",
            list(site, since));
    long start = Math.floorDiv(now, 60_000L) * 60_000 - 29 * 60_000;
    List<Map<String, Object>> perMinute =
        db.all(
            "SELECT "
                + Sql.div(db.dialect(), "(ts - ?)", 60000)
                + " AS m, COUNT(*) AS n FROM rl_events\n       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1",
            list(start, site, start));
    long[] minutes = new long[30];
    for (Map<String, Object> row : perMinute) {
      int index = (int) Math.floor(dnum(row.get("m")));
      if (index >= 0 && index < 30) {
        minutes[index] += (long) dnum(row.get("n"));
      }
    }
    List<Map<String, Object>> countries =
        db.all(
            "SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n"
                + "       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''\n"
                + "       GROUP BY s.country ORDER BY visitors DESC, s.country"
                + textOrder()
                + " LIMIT 10",
            list(site, since));
    List<Map<String, Object>> recent =
        db.all(
            "SELECT e.ts AS ts, e.kind AS kind, e.path AS path, e.name AS name, s.country AS country, s.city AS city, s.source AS source, s.device AS device FROM rl_events e JOIN rl_sessions s ON s.id = e.session\n"
                + "       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC, e.id DESC LIMIT 20",
            list(site, start));
    Function<List<Map<String, Object>>, List<Map<String, Object>>> pairs =
        rows ->
            map(
                rows,
                row ->
                    Json.object(
                        "value", text(row.get("value")), "visitors", num(row.get("visitors"))));
    List<Object> minuteList = new ArrayList<>();
    for (long m : minutes) {
      minuteList.add(m);
    }
    return Json.object(
        "visitors", num(at(active, "n")),
        "pages", pairs.apply(pages),
        "sources", pairs.apply(sources),
        "countries", pairs.apply(countries),
        "minutes", minuteList,
        "recent",
            map(
                recent,
                r ->
                    Json.object(
                        "ts", num(r.get("ts")),
                        "kind", text(r.get("kind")),
                        "path", text(r.get("path")),
                        "name", text(r.get("name")),
                        "country", text(r.get("country")),
                        "city", text(r.get("city")),
                        "source", text(r.get("source")),
                        "device", text(r.get("device")))));
  }

  /**
   * String(value), or "" for null, as PHP's string cast and the TypeScript's {@code ?? ""} read
   * rows.
   */
  static String text(Object value) {
    return value == null ? "" : Js.string(value);
  }

  private static List<Map<String, Object>> map(
      List<Map<String, Object>> rows, Function<Map<String, Object>, Map<String, Object>> fn) {
    List<Map<String, Object>> out = new ArrayList<>(rows.size());
    for (Map<String, Object> row : rows) {
      out.add(fn.apply(row));
    }
    return out;
  }

  /** The SQL Runlight sends MySQL for a statement written for SQLite and Postgres. */
  public static String mysqlText(String sql) {
    return JdbcDb.mysqlText(sql);
  }
}
