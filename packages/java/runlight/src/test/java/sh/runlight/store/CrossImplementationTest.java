package sh.runlight.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * One database, both implementations. The PHP port's tests/fixtures/store.db was built by the
 * TypeScript SDK, and store.json holds what its SqlStore reads answered; the Java store must answer
 * the same over a copy of that file, and over the same rows copied into Postgres and MySQL.
 */
class CrossImplementationTest {
  private final List<Path> files = new ArrayList<>();

  @AfterEach
  void tearDown() throws IOException {
    Databases.cleanup();
    for (Path file : files) {
      Files.deleteIfExists(file);
    }
  }

  private Path copy() throws IOException {
    Path file = Files.createTempFile("rl-store-", ".db");
    Files.copy(
        Fixtures.repo().resolve("packages/php/tests/fixtures/store.db"),
        file,
        java.nio.file.StandardCopyOption.REPLACE_EXISTING);
    files.add(file);
    files.add(Path.of(file + "-wal"));
    files.add(Path.of(file + "-shm"));
    return file;
  }

  @SuppressWarnings("unchecked")
  private static List<Map<String, Object>> maps(Object value) {
    return (List<Map<String, Object>>) (List<?>) Js.list(value);
  }

  private static String s(Object value) {
    return (String) value;
  }

  private static int i(Object value) {
    return (int) Js.asLong(value);
  }

  private static long l(Object value) {
    return Js.asLong(value);
  }

  /** A read's answer in JSON's terms, as the script writes it. */
  static Object answer(SqlStore store, String method, List<Object> a) {
    return switch (method) {
      case "sites" -> store.sites();
      case "siteOverrides" -> store.siteOverrides();
      case "rollupDays" -> {
        List<String> days = new ArrayList<>(store.rollupDays(s(a.get(0))));
        Collections.sort(days);
        yield days;
      }
      case "stats" -> store.stats(Js.map(a.get(0)));
      case "visitors" -> store.visitors(Js.map(a.get(0)));
      case "hourly" -> store.hourly(Js.map(a.get(0)));
      case "breakdown" -> store.breakdown(Js.map(a.get(0)), s(a.get(1)), i(a.get(2)), i(a.get(3)));
      case "goalTotalsAll" -> store.goalTotalsAll(Js.map(a.get(0)), maps(a.get(1)));
      case "goalTotals" -> store.goalTotals(Js.map(a.get(0)), Js.map(a.get(1)));
      case "goalBreakdown" ->
          store.goalBreakdown(
              Js.map(a.get(0)), Js.map(a.get(1)), s(a.get(2)), a.size() > 3 ? i(a.get(3)) : 10);
      case "goalSeries" -> store.goalSeries(Js.map(a.get(0)), Js.map(a.get(1)), maps(a.get(2)));
      case "funnelCounts" -> store.funnelCounts(Js.map(a.get(0)), Js.map(a.get(1)));
      case "journeyPages" -> store.journeyPages(Js.map(a.get(0)), i(a.get(1)));
      case "eventPropKeys" -> store.eventPropKeys(Js.map(a.get(0)), s(a.get(1)));
      case "eventPropValues" ->
          store.eventPropValues(Js.map(a.get(0)), s(a.get(1)), s(a.get(2)), i(a.get(3)));
      case "links" -> store.links(s(a.get(0)), l(a.get(1)), l(a.get(2)));
      case "linkSeries" -> store.linkSeries(s(a.get(0)), s(a.get(1)), maps(a.get(2)));
      case "linkBreakdown" ->
          store.linkBreakdown(
              s(a.get(0)), s(a.get(1)), l(a.get(2)), l(a.get(3)), s(a.get(4)), i(a.get(5)));
      case "series" -> store.series(Js.map(a.get(0)), maps(a.get(1)));
      case "realtime" -> store.realtime(s(a.get(0)), l(a.get(1)));
      case "lastSeen" -> store.lastSeen(s(a.get(0)));
      case "firstSeen" -> store.firstSeen(s(a.get(0)));
      case "firstOwnVisit" -> store.firstOwnVisit(s(a.get(0)));
      case "goals" -> store.goals(a.isEmpty() ? null : s(a.get(0)));
      case "goalById" -> store.goalById(s(a.get(0)));
      case "funnels" -> store.funnels(s(a.get(0)));
      case "linkBySlug" -> store.linkBySlug(s(a.get(0)));
      case "linkById" -> store.linkById(s(a.get(0)));
      case "linkDomains" -> store.linkDomains();
      case "shares" -> store.shares(s(a.get(0)));
      case "shareById" -> store.shareById(s(a.get(0)));
      case "tokens" -> store.tokens();
      case "tokenByHash" -> store.tokenByHash(s(a.get(0)));
      case "reports" -> store.reports(a.isEmpty() ? null : s(a.get(0)));
      case "reportBy" -> store.reportBy(s(a.get(0)), s(a.get(1)));
      case "setting" -> store.setting(s(a.get(0)));
      case "settingsStartingWith" -> store.settingsStartingWith(s(a.get(0)));
      case "saltIfExists" -> store.saltIfExists(s(a.get(0)));
      case "pageview" -> store.pageview(s(a.get(0)), s(a.get(1)));
      case "openSession" -> {
        List<String> visitors = new ArrayList<>();
        for (Object v : Js.list(a.get(1))) {
          visitors.add((String) v);
        }
        yield store.openSession(s(a.get(0)), visitors, l(a.get(2)));
      }
      default -> throw new IllegalArgumentException("no such read " + method);
    };
  }

  private static void assertAnswers(SqlStore store, String label) {
    List<Map<String, Object>> calls = Fixtures.cases(Fixtures.load("store"), "calls");
    List<String> failures = new ArrayList<>();
    for (int n = 0; n < calls.size(); n++) {
      Map<String, Object> call = calls.get(n);
      String expected = Json.stringify(call.get("result"));
      String actual;
      try {
        actual =
            Json.stringify(
                Fixtures.stored(
                    answer(store, (String) call.get("method"), Js.list(call.get("args")))));
      } catch (RuntimeException e) {
        actual = e.getClass().getSimpleName() + ": " + e.getMessage();
      }
      if (!actual.equals(expected)) {
        String args = Json.stringify(call.get("args"));
        failures.add(
            "#"
                + n
                + " "
                + call.get("method")
                + "("
                + args.substring(0, Math.min(300, args.length()))
                + ")\n  expected "
                + expected
                + "\n  actual   "
                + actual);
      }
    }
    assertEquals(
        List.of(),
        failures.subList(0, Math.min(15, failures.size())),
        label + ": " + failures.size() + " of " + calls.size() + " reads differ");
  }

  @Test
  void theFixtureCoversEveryKindOfRead() {
    Set<String> methods = new TreeSet<>();
    for (Map<String, Object> call : Fixtures.cases(Fixtures.load("store"), "calls")) {
      methods.add((String) call.get("method"));
    }
    for (String method :
        List.of(
            "stats",
            "series",
            "hourly",
            "breakdown",
            "goalTotalsAll",
            "goalSeries",
            "funnelCounts",
            "journeyPages",
            "eventPropKeys",
            "eventPropValues",
            "links",
            "linkSeries",
            "realtime")) {
      assertTrue(methods.contains(method), method);
    }
  }

  @Test
  void javaReadsADatabaseTheTypeScriptSdkWroteAndAnswersTheSame() throws IOException {
    SqlStore store = Stores.sqlite(copy().toString());
    store.migrate();
    assertAnswers(store, "sqlite");
    // Opening it changed nothing a reader would see: the schema is the same version.
    Fixtures.assertJson(
        List.of(Map.of("value", "11")),
        store.db().all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'"));
    store.close();
  }

  private static final List<String> TABLES =
      List.of(
          "rl_meta",
          "rl_sites",
          "rl_salts",
          "rl_sessions",
          "rl_events",
          "rl_links",
          "rl_link_domains",
          "rl_shares",
          "rl_goals",
          "rl_settings",
          "rl_reports",
          "rl_tokens",
          "rl_funnels",
          "rl_rollup_days",
          "rl_rollups");

  @Test
  void theSameRowsInPostgresAndMysqlAnswerTheSame() throws IOException {
    for (String kind : Databases.servers()) {
      SqlStore source = Stores.sqlite(copy().toString());
      SqlStore target = Databases.fresh(kind);
      target.migrate();
      target.transaction(
          into -> {
            for (String table : TABLES) {
              into.db().run("DELETE FROM " + table);
              for (Map<String, Object> row : source.db().all("SELECT * FROM " + table)) {
                List<String> columns = new ArrayList<>();
                for (String c : row.keySet()) {
                  columns.add("\"" + c + "\"");
                }
                into.db()
                    .run(
                        "INSERT INTO "
                            + table
                            + " ("
                            + String.join(", ", columns)
                            + ") VALUES ("
                            + String.join(", ", Collections.nCopies(row.size(), "?"))
                            + ")",
                        new ArrayList<>(row.values()));
              }
            }
            return null;
          });
      assertAnswers(target, kind);
      source.close();
      Databases.cleanup();
    }
  }
}
