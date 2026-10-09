package sh.runlight.store;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.function.IntFunction;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Query;
import sh.runlight.Sources;

/**
 * The SQL that store.ts builds outside its class: the schema, filters as conditions, and the small
 * pieces every report shares. Each statement is the TypeScript one, for each dialect ("sqlite",
 * "postgres", "mysql"), so one database serves either implementation.
 *
 * <p>A filter is an object with dimension, op, and value.
 */
public final class Sql {
  private Sql() {}

  /** A piece of SQL with its values. */
  public record Piece(String sql, List<Object> params) {
    public static Piece of(String sql, Object... params) {
      return new Piece(sql, list(params));
    }
  }

  static List<Object> list(Object... items) {
    List<Object> out = new ArrayList<>(items.length);
    Collections.addAll(out, items);
    return out;
  }

  /** A session's bounce: one page, nothing clicked that was tracked, under ten seconds engaged. */
  public static final long BOUNCE_MS = 10_000;

  public static final String BOUNCE =
      "(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < 10000))";
  public static final String VISIT_KINDS = "e.kind IN ('pageview', 'event')";

  /**
   * Cloudflare D1 takes at most 100 bound parameters a statement, so lists that grow with the range
   * (chart buckets, values) go in pieces, and built days are chosen by their dates.
   */
  public static final int BUCKETS_PER_QUERY = 30;

  public static final int VALUES_PER_QUERY = 50;

  /** The most values one statement binds: D1's 100, less a little. */
  public static final int MAX_PARAMS = 96;

  /** The built days inside a range, as a subquery taking (site, from, to). */
  public static final String BUILT_DAYS =
      "SELECT day FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ?";

  /** The most visits journeys reads, newest first. */
  public static final int JOURNEY_VISITS = 20_000;

  /** How long after a visit starts its events are looked for: far past any real visit. */
  public static final long EVENT_TAIL_MS = 2 * 86_400_000L;

  public static final long PIECE_MS = 86_400_000L;

  /**
   * Pageviews that can report engaged time: the tracker's, which carry a pageview id. Imported
   * history has none, so time on page is the mean over these, counting a view that reported nothing
   * (under a second) as none.
   */
  public static final String LIVE_VIEWS = "SUM(CASE WHEN e.pageview <> '' THEN 1 ELSE 0 END)";

  /** A session that is a visit: a short link click alone opens one that is not. */
  public static final String IS_VISIT = "(s.pageviews > 0 OR s.events > 0)";

  /** Engaged time, or for imported visits with none, first to last request. */
  public static final String DURATION = "COALESCE(s.engaged_ms, s.last_at - s.started_at)";

  public static final int SCHEMA_VERSION = 11;

  /**
   * MySQL's text collation: UTF-8 compared and sorted by code point, case and trailing spaces
   * included, as SQLite and Postgres's "C" collation do. MariaDB has it too, from 11.4.
   */
  public static final String MYSQL_COLLATION = "utf8mb4_0900_bin";

  private static final List<String> PATH_DIMENSIONS = List.of("page", "entry", "exit");

  /**
   * Orders text by code point, as SQLite and Postgres's "C" collation do. JavaScript's {@code <}
   * compares UTF-16 units, which differs only past U+FFFF.
   */
  public static int codeOrder(String a, String b) {
    int i = 0;
    int j = 0;
    while (i < a.length() && j < b.length()) {
      int x = a.codePointAt(i);
      int y = b.codePointAt(j);
      if (x != y) {
        return x < y ? -1 : 1;
      }
      i += Character.charCount(x);
      j += Character.charCount(y);
    }
    return Integer.compare(a.length() - i, b.length() - j);
  }

  /** Runs a query over pieces of a list and joins the answers, in order. */
  public static <T, R> List<R> inPieces(List<T> items, int size, Function<List<T>, List<R>> run) {
    List<R> out = new ArrayList<>();
    for (int i = 0; i < items.size(); i += size) {
      out.addAll(run.apply(items.subList(i, Math.min(items.size(), i + size))));
    }
    return out;
  }

  public static List<String> schema(String dialect) {
    boolean my = dialect.equals("mysql");
    String id =
        dialect.equals("postgres")
            ? "BIGSERIAL PRIMARY KEY"
            : my ? "BIGINT AUTO_INCREMENT PRIMARY KEY" : "INTEGER PRIMARY KEY AUTOINCREMENT";
    // MySQL keys and indexes TEXT only by a prefix, so there a column that is keyed, indexed,
    // grouped, or sorted is VARCHAR, sized past anything Runlight writes to it.
    IntFunction<String> str = n -> my ? "VARCHAR(" + n + ")" : "TEXT";
    IntFunction<String> text = n -> str.apply(n) + " NOT NULL DEFAULT ''";
    // Free text that is never keyed. MySQL takes a default for it only as an expression.
    Function<String, String> lng =
        fallback ->
            my
                ? "MEDIUMTEXT NOT NULL DEFAULT ('" + fallback + "')"
                : "TEXT NOT NULL DEFAULT '" + fallback + "'";
    String table = my ? " DEFAULT CHARSET=utf8mb4 COLLATE=" + MYSQL_COLLATION : "";
    String site = str.apply(100);
    String key = str.apply(100);
    int path = 1000;
    String medium = my ? "MEDIUMTEXT" : "TEXT";
    return List.of(
        "CREATE TABLE IF NOT EXISTS rl_meta (\"key\" "
            + str.apply(100)
            + " PRIMARY KEY, value "
            + medium
            + " NOT NULL)"
            + table,
        "CREATE TABLE IF NOT EXISTS rl_sites (\n      id "
            + site
            + " PRIMARY KEY, name "
            + text.apply(200)
            + ", hostnames "
            + lng.apply("[]")
            + ",\n      timezone "
            + str.apply(64)
            + " NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL,\n      overrides "
            + lng.apply("{}")
            + ")"
            + table,
        "CREATE TABLE IF NOT EXISTS rl_salts (day "
            + str.apply(32)
            + " PRIMARY KEY, salt "
            + str.apply(255)
            + " NOT NULL)"
            + table,
        "CREATE TABLE IF NOT EXISTS rl_sessions (\n      id "
            + key
            + " PRIMARY KEY, site "
            + site
            + " NOT NULL, visitor "
            + key
            + " NOT NULL,\n      started_at BIGINT NOT NULL, last_at BIGINT NOT NULL,\n      entry_path "
            + text.apply(path)
            + ", exit_path "
            + text.apply(path)
            + ",\n      pageviews INTEGER NOT NULL DEFAULT 0, events INTEGER NOT NULL DEFAULT 0,\n      engaged_ms BIGINT, imported INTEGER NOT NULL DEFAULT 0,\n      hostname "
            + text.apply(255)
            + ", referrer_host "
            + text.apply(255)
            + ", referrer_path "
            + text.apply(500)
            + ",\n      source "
            + text.apply(200)
            + ", channel "
            + text.apply(100)
            + ",\n      utm_source "
            + text.apply(200)
            + ", utm_medium "
            + text.apply(200)
            + ", utm_campaign "
            + text.apply(200)
            + ", utm_term "
            + text.apply(200)
            + ", utm_content "
            + text.apply(200)
            + ",\n      country "
            + text.apply(16)
            + ", region "
            + text.apply(100)
            + ", city "
            + text.apply(100)
            + ",\n      browser "
            + text.apply(100)
            + ", browser_version "
            + text.apply(100)
            + ", os "
            + text.apply(100)
            + ", os_version "
            + text.apply(100)
            + ",\n      device "
            + text.apply(50)
            + ", screen "
            + text.apply(50)
            + ", language "
            + text.apply(50)
            + ")"
            + table,
        "CREATE INDEX IF NOT EXISTS rl_sessions_site_started ON rl_sessions (site, started_at)",
        // MySQL takes an index that leads with the site as a way to read all of a site's rows, so
        // there an index for looking a value up leads with that value.
        "CREATE INDEX IF NOT EXISTS rl_sessions_visitor ON rl_sessions ("
            + (my ? "visitor, site" : "site, visitor")
            + ", last_at)",
        "CREATE TABLE IF NOT EXISTS rl_events (\n      id "
            + id
            + ", site "
            + site
            + " NOT NULL, ts BIGINT NOT NULL, kind "
            + str.apply(20)
            + " NOT NULL,\n      visitor "
            + text.apply(100)
            + ", session "
            + text.apply(100)
            + ", pageview "
            + text.apply(100)
            + ",\n      path "
            + text.apply(path)
            + ", hostname "
            + text.apply(255)
            + ", title "
            + text.apply(500)
            + ", name "
            + text.apply(255)
            + ", props "
            + medium
            + ",\n      engaged_ms BIGINT NOT NULL DEFAULT 0, scroll INTEGER, link "
            + text.apply(100)
            + ")"
            + table,
        "CREATE INDEX IF NOT EXISTS rl_events_site_ts ON rl_events (site, ts)",
        // Goals and events read one kind of row in a range; created on start for older databases
        // too.
        "CREATE INDEX IF NOT EXISTS rl_events_site_kind_ts ON rl_events (site, kind, ts)",
        "CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events ("
            + (my ? "pageview, site" : "site, pageview")
            + ")",
        // Page and event filters find the visits they pick through these. MySQL indexes the first
        // 255 characters of a path, which is enough to find it.
        "CREATE INDEX IF NOT EXISTS rl_events_site_path ON rl_events ("
            + (my ? "path(255), site" : "site, path")
            + ", ts)",
        // MySQL has no partial index, so its index of event names holds the kind too.
        my
            ? "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (name, site, kind, ts)"
            : "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (site, name, ts) WHERE kind = 'event'",
        // Version 3: short links; "" is the app's own domain. Version 4: a slug is unique across
        // every domain. MySQL has no partial index, so there a generated column holds the slug of a
        // live link only, and is unique.
        "CREATE TABLE IF NOT EXISTS rl_links (\n      id "
            + key
            + " PRIMARY KEY, site "
            + site
            + " NOT NULL, domain "
            + text.apply(255)
            + ", slug "
            + str.apply(255)
            + " NOT NULL,\n      name "
            + text.apply(255)
            + ", url "
            + str.apply(4000)
            + " NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,\n      deleted_at BIGINT"
            + (my
                ? ", live_slug VARCHAR(255) AS (CASE WHEN deleted_at IS NULL THEN slug END) VIRTUAL"
                : "")
            + ")"
            + table,
        my
            ? "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (live_slug)"
            : "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (slug) WHERE deleted_at IS NULL",
        "CREATE INDEX IF NOT EXISTS rl_events_link ON rl_events (link, ts)",
        "CREATE TABLE IF NOT EXISTS rl_link_domains (domain "
            + str.apply(255)
            + " PRIMARY KEY, site "
            + site
            + " NOT NULL, created_at BIGINT NOT NULL)"
            + table,
        // Version 5: share links.
        "CREATE TABLE IF NOT EXISTS rl_shares (id "
            + key
            + " PRIMARY KEY, site "
            + site
            + " NOT NULL, name "
            + text.apply(255)
            + ", created_at BIGINT NOT NULL)"
            + table,
        // Version 6: goals.
        "CREATE TABLE IF NOT EXISTS rl_goals (\n      id "
            + key
            + " PRIMARY KEY, site "
            + site
            + " NOT NULL, name "
            + str.apply(255)
            + " NOT NULL, kind "
            + str.apply(20)
            + " NOT NULL, \"match\" "
            + str.apply(1000)
            + " NOT NULL,\n      click_by "
            + text.apply(20)
            + ", value_mode "
            + str.apply(20)
            + " NOT NULL DEFAULT 'none', value "
            + (my ? "DOUBLE" : "REAL")
            + " NOT NULL DEFAULT 0,\n      value_prop "
            + text.apply(255)
            + ", currency "
            + str.apply(10)
            + " NOT NULL DEFAULT 'USD', created_at BIGINT NOT NULL)"
            + table,
        // Version 7: install-wide settings (the mail service) and email report subscriptions.
        "CREATE TABLE IF NOT EXISTS rl_settings (\"key\" "
            + str.apply(255)
            + " PRIMARY KEY, value "
            + medium
            + " NOT NULL)"
            + table,
        "CREATE TABLE IF NOT EXISTS rl_reports (\n      id "
            + key
            + " PRIMARY KEY, site "
            + site
            + " NOT NULL, email "
            + str.apply(320)
            + " NOT NULL, frequency "
            + str.apply(20)
            + " NOT NULL,\n      lang "
            + str.apply(20)
            + " NOT NULL DEFAULT 'en', token "
            + str.apply(128)
            + " NOT NULL, origin "
            + text.apply(500)
            + ",\n      last_period "
            + text.apply(40)
            + ", last_sent_at BIGINT, created_at BIGINT NOT NULL)"
            + table,
        "CREATE UNIQUE INDEX IF NOT EXISTS rl_reports_token ON rl_reports (token)",
        // Version 8: read-only API tokens, for scripts and AI assistants over MCP.
        "CREATE TABLE IF NOT EXISTS rl_tokens (\n      id "
            + key
            + " PRIMARY KEY, name "
            + str.apply(255)
            + " NOT NULL, site "
            + text.apply(100)
            + ", hash "
            + str.apply(128)
            + " NOT NULL, hint "
            + text.apply(20)
            + ",\n      created_at BIGINT NOT NULL, last_used_at BIGINT, scope "
            + str.apply(20)
            + " NOT NULL DEFAULT 'read')"
            + table,
        "CREATE UNIQUE INDEX IF NOT EXISTS rl_tokens_hash ON rl_tokens (hash)",
        // Version 9: funnels.
        "CREATE TABLE IF NOT EXISTS rl_funnels (id "
            + key
            + " PRIMARY KEY, site "
            + site
            + " NOT NULL, name "
            + str.apply(255)
            + " NOT NULL, steps "
            + medium
            + " NOT NULL, created_at BIGINT NOT NULL)"
            + table,
        // Version 11: daily rollups. A day is the site's own local day; rl_rollup_days says which
        // days are built and where they begin and end.
        "CREATE TABLE IF NOT EXISTS rl_rollup_days (site "
            + site
            + " NOT NULL, day "
            + str.apply(32)
            + " NOT NULL, start_at BIGINT NOT NULL, end_at BIGINT NOT NULL, PRIMARY KEY (site, day))"
            + table,
        "CREATE INDEX IF NOT EXISTS rl_rollup_days_range ON rl_rollup_days (site, start_at)",
        // A value can be a whole path, longer than MySQL's keys allow, so there the rows of a day
        // are found by an index without it.
        "CREATE TABLE IF NOT EXISTS rl_rollups (\n      site "
            + site
            + " NOT NULL, day "
            + str.apply(32)
            + " NOT NULL, dim "
            + str.apply(32)
            + " NOT NULL, value "
            + text.apply(path)
            + ",\n      visitors BIGINT NOT NULL DEFAULT 0, visits BIGINT NOT NULL DEFAULT 0, pageviews BIGINT NOT NULL DEFAULT 0,\n      bounced BIGINT NOT NULL DEFAULT 0, duration BIGINT NOT NULL DEFAULT 0,\n      engaged BIGINT NOT NULL DEFAULT 0, views BIGINT NOT NULL DEFAULT 0, scroll_sum BIGINT NOT NULL DEFAULT 0, scroll_n BIGINT NOT NULL DEFAULT 0,\n      events BIGINT NOT NULL DEFAULT 0,\n      "
            + (my ? "KEY rl_rollups_day (site, dim, day)" : "PRIMARY KEY (site, dim, day, value)")
            + ")"
            + table);
  }

  /** A goal row read from rl_goals. */
  public static Map<String, Object> goalRow(Map<String, Object> r) {
    return Json.object(
        "id", Js.string(r.get("id")),
        "site", Js.string(r.get("site")),
        "name", Js.string(r.get("name")),
        "kind", Js.string(r.get("kind")),
        "match", Js.string(r.get("match")),
        "clickBy", str(r.get("click_by"), ""),
        "valueMode", Js.string(r.get("value_mode")),
        "value", Js.num(Js.toNumber(r.get("value") == null ? 0L : r.get("value"))),
        "valueProp", str(r.get("value_prop"), ""),
        "currency", str(r.get("currency"), "USD"),
        "createdAt", Js.num(Js.toNumber(r.get("created_at"))));
  }

  /** String(value ?? fallback). */
  static String str(Object value, String fallback) {
    return value == null ? fallback : Js.string(value);
  }

  private static final Pattern GLOB_SPECIAL = Pattern.compile("[\\[?]");

  /**
   * A {@code *} pattern as SQLite GLOB, everything else taken literally ([ and ? are GLOB's own).
   */
  public static String globPattern(String pattern) {
    List<String> parts = new ArrayList<>();
    for (String part : pattern.split("\\*", -1)) {
      parts.add(GLOB_SPECIAL.matcher(part).replaceAll("[$0]"));
    }
    return String.join("*", parts);
  }

  /** A {@code *} pattern as SQL LIKE, everything else taken literally. */
  public static String likePattern(String pattern) {
    List<String> parts = new ArrayList<>();
    for (String part : pattern.split("\\*", -1)) {
      parts.add(escapeLike(part));
    }
    return String.join("%", parts);
  }

  /**
   * An INSERT that updates the row already there with the same key, or with {@code update} empty
   * leaves it be. MySQL says it its own way.
   */
  public static String upsert(
      String dialect, String table, List<String> columns, List<String> key, List<String> update) {
    String insert =
        "INSERT INTO "
            + table
            + " ("
            + String.join(", ", columns)
            + ") VALUES ("
            + String.join(", ", Collections.nCopies(columns.size(), "?"))
            + ")";
    if (dialect.equals("mysql")) {
      List<String> set = new ArrayList<>();
      for (String c : update.isEmpty() ? List.of(key.get(0)) : update) {
        set.add(c + " = " + (update.isEmpty() ? c : "VALUES(" + c + ")"));
      }
      return insert + " ON DUPLICATE KEY UPDATE " + String.join(", ", set);
    }
    if (update.isEmpty()) {
      return insert + " ON CONFLICT (" + String.join(", ", key) + ") DO NOTHING";
    }
    List<String> set = new ArrayList<>();
    for (String c : update) {
      set.add(c + " = excluded." + c);
    }
    return insert
        + " ON CONFLICT ("
        + String.join(", ", key)
        + ") DO UPDATE SET "
        + String.join(", ", set);
  }

  /** Whole-number division, which MySQL's {@code /} is not. */
  public static String div(String dialect, String a, long b) {
    return dialect.equals("mysql") ? "(" + a + " DIV " + b + ")" : "(" + a + " / " + b + ")";
  }

  /** A value as text: MySQL casts to CHAR, and has no TEXT type to cast to. */
  public static String asText(String dialect, String value) {
    return "CAST(" + value + " AS " + (dialect.equals("mysql") ? "CHAR" : "TEXT") + ")";
  }

  /**
   * A table of buckets (i, bs, be) for a WITH clause. Postgres is told the first row's types; MySQL
   * and MariaDB write a table of values differently from each other, so they get a UNION of rows.
   */
  public static String bucketTable(String dialect, int count) {
    List<String> rows = new ArrayList<>();
    if (dialect.equals("mysql")) {
      for (int i = 0; i < count; i++) {
        rows.add(i == 0 ? "SELECT ? AS i, ? AS bs, ? AS be" : "SELECT ?, ?, ?");
      }
      return String.join(" UNION ALL ", rows);
    }
    boolean cast = dialect.equals("postgres");
    for (int i = 0; i < count; i++) {
      rows.add(
          cast && i == 0
              ? "(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))"
              : "(?, ?, ?)");
    }
    return "VALUES " + String.join(", ", rows);
  }

  /** A link row read from rl_links. */
  public static Map<String, Object> linkRow(Map<String, Object> row) {
    return Json.object(
        "id", Js.string(row.get("id")),
        "site", Js.string(row.get("site")),
        "domain", str(row.get("domain"), ""),
        "slug", Js.string(row.get("slug")),
        "name", str(row.get("name"), ""),
        "url", Js.string(row.get("url")),
        "createdAt", Js.num(Js.toNumber(row.get("created_at"))),
        "updatedAt", Js.num(Js.toNumber(row.get("updated_at"))));
  }

  /** Number(value ?? 0), or 0 when that is not finite, in the port's number form. */
  public static Object num(Object value) {
    double n = Js.toNumber(value == null ? 0L : value);
    if (Double.isNaN(n) || Double.isInfinite(n)) {
      return 0L;
    }
    return Js.num(n);
  }

  /** Number(value ?? 0) as a double, 0 when not finite. */
  public static double dnum(Object value) {
    double n = Js.toNumber(value == null ? 0L : value);
    return Double.isNaN(n) || Double.isInfinite(n) ? 0 : n;
  }

  private static final Pattern LIKE_SPECIAL = Pattern.compile("[\\\\%_]");

  public static String escapeLike(String value) {
    return LIKE_SPECIAL.matcher(value).replaceAll("\\\\$0");
  }

  public static String column(String dimension) {
    return Query.isSessionDimension(dimension)
        ? "s." + Query.SESSION_DIMENSIONS.get(dimension)
        : "e." + Query.EVENT_DIMENSIONS.get(dimension);
  }

  /**
   * Text in the form a recorded path holds it, percent-encoded, as part of a path or as a whole
   * one.
   */
  public static String asRecorded(String value, boolean whole) {
    String path = Sources.recordedPath(whole || value.startsWith("/") ? value : "/" + value);
    if (path == null) {
      return value;
    }
    return whole || value.startsWith("/") ? path : path.substring(1);
  }

  /** A GLOB pattern for text containing {@code value} in any mix of upper and lower case. */
  public static String anyCase(String value) {
    StringBuilder out = new StringBuilder("*");
    String text = Js.wellFormed(value);
    for (int i = 0; i < text.length(); ) {
      int cp = text.codePointAt(i);
      String ch = new String(Character.toChars(cp));
      i += ch.length();
      String lower = Js.lower(ch);
      String upper = Js.upper(ch);
      if (!lower.equals(upper)
          && lower.codePointCount(0, lower.length()) == 1
          && upper.codePointCount(0, upper.length()) == 1) {
        out.append('[').append(lower).append(upper).append(']');
      } else {
        out.append(ch.equals("*") || ch.equals("?") || ch.equals("[") ? "[" + ch + "]" : ch);
      }
    }
    return out.append('*').toString();
  }

  private static final Pattern TITLE = Pattern.compile("(^|[" + Js.SPACE + "\\-/_.])(\\p{L})");

  public static Piece condition(Map<String, Object> filter, String dialect) {
    return condition(filter, dialect, false);
  }

  /** One filter as a condition on its own column, with "is not" flipped to "is" when asked. */
  public static Piece condition(Map<String, Object> filter, String dialect, boolean positive) {
    String dimension = (String) filter.get("dimension");
    String col = column(dimension);
    String op = positive && "not".equals(filter.get("op")) ? "is" : (String) filter.get("op");
    // Paths are recorded percent-encoded, as the browser's URL parser writes them, so "/café" is
    // matched as "/caf%C3%A9", just as a goal for it is.
    boolean path = PATH_DIMENSIONS.contains(dimension);
    String value = (String) filter.get("value");
    if (op.equals("is") || op.equals("not")) {
      return Piece.of(
          col + " " + (op.equals("is") ? "=" : "<>") + " ?",
          path ? asRecorded(value, true) : value);
    }
    if (path) {
      // An encoded letter's case is in its bytes (%C3%9C is Ü, %C3%BC is ü), which no database
      // folds, so a path is also tried in lower, upper, and title case, encoded each way.
      Matcher m = TITLE.matcher(Js.lower(value));
      StringBuilder title = new StringBuilder();
      while (m.find()) {
        m.appendReplacement(title, Matcher.quoteReplacement(m.group(1) + Js.upper(m.group(2))));
      }
      m.appendTail(title);
      LinkedHashSet<String> forms = new LinkedHashSet<>();
      for (String f : List.of(value, Js.lower(value), Js.upper(value), title.toString())) {
        forms.add(asRecorded(f, false));
      }
      boolean lower = !dialect.equals("sqlite");
      String one = lower ? "LOWER(" + col + ") LIKE ? ESCAPE '\\'" : col + " LIKE ? ESCAPE '\\'";
      List<Object> params = new ArrayList<>();
      for (String f : forms) {
        params.add("%" + escapeLike(lower ? Js.lower(f) : f) + "%");
      }
      return new Piece(
          "(" + String.join(" OR ", Collections.nCopies(forms.size(), one)) + ")", params);
    }
    // Postgres and MySQL lower case any letter, so both sides lowered find any mix.
    if (!dialect.equals("sqlite")) {
      return Piece.of(
          "LOWER(" + col + ") LIKE ? ESCAPE '\\'", "%" + escapeLike(Js.lower(value)) + "%");
    }
    // SQLite's LIKE and LOWER ignore case for ASCII letters only, so GLOB with both cases of every
    // letter finds any mix, Unicode included.
    return Piece.of(col + " GLOB ?", anyCase(value));
  }

  /**
   * The visits a query's filters pick, as conditions on {@code s}. A filter on the visit applies to
   * it directly. A filter on a page, hostname, or event picks the visits that had a matching row,
   * or for "is not", that never had one. Rows count up to EVENT_TAIL_MS past the range.
   */
  public static Piece visitScope(
      List<Map<String, Object>> filters, String site, long from, long to, String dialect) {
    StringBuilder sql = new StringBuilder();
    List<Object> params = new ArrayList<>();
    for (Map<String, Object> filter : filters) {
      Piece c = condition(filter, dialect, true);
      String dimension = (String) filter.get("dimension");
      if (Query.isSessionDimension(dimension)) {
        Piece own = condition(filter, dialect);
        sql.append(" AND ").append(own.sql());
        params.addAll(own.params());
      } else {
        // An event filter reads events only, which lets it use the index of event names.
        String kinds = dimension.equals("event") ? "e.kind = 'event'" : VISIT_KINDS;
        String rows =
            "FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND "
                + kinds
                + " AND "
                + c.sql();
        // Postgres plans NOT IN over a big list badly, so it gets NOT EXISTS, an anti join.
        if ("not".equals(filter.get("op")) && dialect.equals("postgres")) {
          sql.append(" AND NOT EXISTS (SELECT 1 ").append(rows).append(" AND e.session = s.id)");
        } else {
          sql.append(" AND s.id ")
              .append("not".equals(filter.get("op")) ? "NOT IN" : "IN")
              .append(" (SELECT e.session ")
              .append(rows)
              .append(")");
        }
        params.add(site);
        params.add(from);
        params.add(to + EVENT_TAIL_MS);
        params.addAll(c.params());
      }
    }
    return new Piece(sql.toString(), params);
  }

  /**
   * Conditions on {@code e} from the filters on the given row dimensions that keep rows (is,
   * contains). A row counts when it matches any filter on each of its dimensions.
   */
  public static Piece rowScope(
      List<Map<String, Object>> filters, List<String> dimensions, String dialect) {
    StringBuilder sql = new StringBuilder();
    List<Object> params = new ArrayList<>();
    for (String dimension : dimensions) {
      List<Piece> kept = new ArrayList<>();
      for (Map<String, Object> f : filters) {
        if (dimension.equals(f.get("dimension")) && !"not".equals(f.get("op"))) {
          kept.add(condition(f, dialect));
        }
      }
      if (kept.isEmpty()) {
        continue;
      }
      List<String> parts = new ArrayList<>();
      for (Piece c : kept) {
        parts.add(c.sql());
      }
      sql.append(" AND (").append(String.join(" OR ", parts)).append(")");
      for (Piece c : kept) {
        params.addAll(c.params());
      }
    }
    return new Piece(sql.toString(), params);
  }

  /**
   * Pageviews for each visit a filter picks, as a table to LEFT JOIN on {@code pv.session = s.id},
   * when a page or hostname filter narrows what counts as a pageview. Null when every pageview of a
   * visit counts.
   */
  public static Piece pageviewsOf(
      List<Map<String, Object>> filters, String site, long from, long to, String dialect) {
    Piece rows = rowScope(filters, List.of("page", "hostname"), dialect);
    if (rows.sql().isEmpty()) {
      return null;
    }
    List<Object> params = list(site, from, to + EVENT_TAIL_MS);
    params.addAll(rows.params());
    return new Piece(
        "(SELECT e.session AS session, COUNT(*) AS n FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'"
            + rows.sql()
            + " GROUP BY e.session)",
        params);
  }

  /**
   * The rows of the visits a query picks: a FROM list and conditions over {@code e} and {@code s}.
   */
  public record VisitRows(String from, String sql, List<Object> params) {}

  /**
   * For reports that count rows (goals, event properties, funnels): the rows of the visits a query
   * picks. A visit belongs to the range it started in, and its rows count up to EVENT_TAIL_MS past
   * the range. Written as a CROSS JOIN so SQLite reads the events through their (site, kind, ts)
   * index and looks each visit up by its id.
   */
  public static VisitRows visitRows(
      List<Map<String, Object>> filters, String site, long from, long to, String dialect) {
    Piece scope = visitScope(filters, site, from, to, dialect);
    List<Object> params = list(site, from, to + EVENT_TAIL_MS, site, from, to);
    params.addAll(scope.params());
    return new VisitRows(
        "rl_events e CROSS JOIN rl_sessions s",
        "e.site = ? AND e.ts >= ? AND e.ts < ? AND s.id = e.session AND s.site = ? AND s.started_at >= ? AND s.started_at < ? AND "
            + IS_VISIT
            + scope.sql(),
        params);
  }
}
