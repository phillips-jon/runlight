package sh.runlight.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;
import static sh.runlight.Fixtures.assertJson;

import java.io.IOException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.function.Supplier;
import java.util.logging.Handler;
import java.util.logging.LogRecord;
import java.util.logging.Logger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Fixtures;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.db.Connect;
import sh.runlight.db.Db;

/**
 * Creating and upgrading the tables, and what each connection is set up to do: storage.test.ts,
 * postgres.test.ts, and mysql.test.ts, with the tables compared against the ones the TypeScript SDK
 * makes.
 */
class MigrateTest {
  private final List<Path> files = new ArrayList<>();
  private final List<Runnable> drops = new ArrayList<>();

  @AfterEach
  void tearDown() throws IOException {
    Databases.cleanup();
    while (!drops.isEmpty()) {
      try {
        drops.remove(drops.size() - 1).run();
      } catch (RuntimeException e) {
        System.err.println("cleanup: " + e.getMessage());
      }
    }
    for (Path file : files) {
      if (Files.exists(file)) {
        file.toFile().setWritable(true);
        Files.deleteIfExists(file);
      }
    }
  }

  static List<String> kinds() {
    return Databases.kinds();
  }

  static List<String> servers() {
    List<String> kinds = Databases.servers();
    return kinds.isEmpty() ? List.of("none") : kinds;
  }

  private Path file() throws IOException {
    Path file = Files.createTempFile("rl-migrate-", ".db");
    Files.delete(file);
    files.add(file);
    files.add(Path.of(file + "-wal"));
    files.add(Path.of(file + "-shm"));
    return file;
  }

  private static String name() {
    return "rl_test_" + HexFormat.of().formatHex(Hash.randomBytes(5));
  }

  /** A database of its own on a MySQL server, dropped after the test, and its URL. */
  private String mysqlDatabase(String url) {
    String name = name();
    Db admin = Connect.mysql(url, 0);
    admin.run("CREATE DATABASE " + name);
    drops.add(
        () -> {
          admin.run("DROP DATABASE IF EXISTS " + name);
          admin.close();
        });
    return url.replaceFirst("/[^/?]*(\\?|$)", "/" + name + "$1");
  }

  /**
   * A store on a database of the kind, a function that opens another store on the same one, and the
   * arguments for MigrateProcess.
   */
  private record Shared(SqlStore store, Supplier<SqlStore> again, List<String> args) {}

  private Shared shared(String kind) throws IOException {
    if (kind.equals("sqlite")) {
      String file = file().toString();
      return new Shared(Stores.sqlite(file), () -> Stores.sqlite(file), List.of("sqlite", file));
    }
    if (kind.equals("postgres")) {
      String schema = Databases.pgSchema();
      String url = Databases.pgUrl();
      return new Shared(
          Stores.postgres(url, 120_000, schema),
          () -> Stores.postgres(url, 120_000, schema),
          List.of("postgres", url, schema));
    }
    String url = mysqlDatabase(Databases.mysqlUrls().get(kind));
    return new Shared(Stores.mysql(url), () -> Stores.mysql(url), List.of("mysql", url));
  }

  private static long tables(Db db) {
    String sql =
        switch (db.dialect()) {
          case "sqlite" ->
              "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name LIKE 'rl\\_%' ESCAPE '\\'";
          case "postgres" ->
              "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = current_schema()";
          default ->
              "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE()";
        };
    return Js.asLong(db.all(sql).get(0).get("n"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void migratingIsSafeAnyNumberOfTimesAndRecordsTheSchemaVersion(String kind) {
    SqlStore store = Databases.fresh(kind);
    store.migrate();
    store.migrate();
    new SqlStore(store.db()).migrate();
    assertEquals(15, tables(store.db()));
    assertJson(
        List.of(Json.object("value", "11")),
        store.db().all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void anUpgradeThatStoppedAfterAddingAColumnButBeforeRecordingItsVersionStartsTheNextTime(
      String kind) throws IOException {
    // MySQL 8.4 refuses the version 10 upgrade's TEXT column with a default, in TypeScript too; no
    // MySQL database was ever at version 9, since MySQL support came with version 11.
    assumeTrue(!kind.equals("mysql"), "MySQL tables start at version 11");
    Shared shared = shared(kind);
    SqlStore store = shared.store();
    store.migrate();
    // As an upgrade from version 9 leaves things when it stops between its two steps.
    store.db().run("UPDATE rl_meta SET value = '9' WHERE \"key\" = 'schema'");
    store.close();
    SqlStore next = shared.again().get();
    next.migrate();
    assertJson(
        List.of(Json.object("value", "11")),
        next.db().all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'"));
    next.close();
  }

  @Test
  void aRequestTakesACurrentSchemaOnTrustAndTheFullPassAddsWhatIsMissing() throws IOException {
    String file = file().toString();
    SqlStore first = Stores.sqlite(file);
    first.migrate();
    first.close();
    SqlStore dropper = Stores.sqlite(file);
    dropper.db().run("DROP INDEX rl_events_link");
    dropper.close();
    Function<SqlStore, List<Map<String, Object>>> index =
        store -> store.db().all("SELECT name FROM sqlite_master WHERE name = 'rl_events_link'");
    SqlStore request = Stores.sqlite(file);
    request.migrate();
    assertJson(
        List.of(),
        index.apply(request),
        "a request at the current version does not go over every index");
    request.close();
    SqlStore cron = Stores.sqlite(file);
    cron.migrate(true);
    assertJson(
        List.of(Json.object("name", "rl_events_link")),
        index.apply(cron),
        "the full pass builds it again");
    cron.close();
  }

  @Test
  void aDatabaseThatCanOnlyBeReadStillAnswersReports() throws IOException {
    Path file = file();
    SqlStore first = Stores.sqlite(file.toString());
    first.migrate();
    Map<String, Object> site =
        Json.object(
            "id", "default",
            "name", "Example",
            "hostnames", List.of("example.com"),
            "timezone", "UTC");
    first.upsertSite(site, 1);
    first.close();
    Files.setPosixFilePermissions(file, PosixFilePermissions.fromString("r--r--r--"));
    SqlStore store = Stores.sqlite(file.toString());
    store.migrate();
    store.upsertSite(site, 2);
    assertJson(
        0,
        store
            .stats(Json.object("site", "default", "from", 0L, "to", 1L, "filters", List.of()))
            .get("visits"));
    store.close();
  }

  @ParameterizedTest
  @MethodSource("servers")
  void processesStartingAtOnceCreateTheTablesOnce(String kind) throws Exception {
    assumeTrue(!kind.equals("none"), "Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL.");
    Shared shared = shared(kind);
    String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
    List<Process> processes = new ArrayList<>();
    for (int i = 0; i < 4; i++) {
      List<String> command =
          new ArrayList<>(
              List.of(
                  java,
                  "-cp",
                  System.getProperty("java.class.path"),
                  MigrateProcess.class.getName()));
      command.addAll(shared.args());
      processes.add(new ProcessBuilder(command).redirectErrorStream(true).start());
    }
    for (Process process : processes) {
      String out = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
      assertEquals(0, process.waitFor(), out);
      assertTrue(out.endsWith("ok\n"), out);
    }
    assertEquals(15, tables(shared.store().db()));
    shared.store().close();
  }

  private static List<Map<String, Object>> sqliteSchema(SqlStore s) {
    return s.db()
        .all(
            "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name");
  }

  @Test
  void theTablesAreTheOnesTheTypeScriptSdkMakesOnSqlite() throws IOException {
    // A copy, so opening it leaves the fixture as it is.
    Path copy = file();
    Files.copy(
        Fixtures.repo().resolve("packages/php/tests/fixtures/store.db"),
        copy,
        StandardCopyOption.REPLACE_EXISTING);
    SqlStore theirs = Stores.sqlite(copy.toString());
    SqlStore mine = Stores.sqlite(":memory:");
    mine.migrate();
    assertJson(sqliteSchema(theirs), sqliteSchema(mine));
    theirs.close();
    mine.close();
  }

  private static List<Object> describe(SqlStore store) {
    Db db = store.db();
    if (db.dialect().equals("postgres")) {
      return List.of(
          db.all(
              "SELECT table_name, column_name, ordinal_position, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() ORDER BY table_name, ordinal_position"),
          db.all(
              "SELECT tablename, indexname, regexp_replace(indexdef, ' ON [a-z0-9_]+\\.', ' ON ') AS def FROM pg_indexes WHERE schemaname = current_schema() ORDER BY indexname"));
    }
    return List.of(
        db.all(
            "SELECT table_name, column_name, ordinal_position, column_type, is_nullable, column_default, collation_name, extra, generation_expression FROM information_schema.columns WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position"),
        db.all(
            "SELECT table_name, index_name, non_unique, seq_in_index, column_name, sub_part FROM information_schema.statistics WHERE table_schema = DATABASE() ORDER BY table_name, index_name, seq_in_index"),
        db.all(
            "SELECT table_name, table_collation, engine FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name"));
  }

  @ParameterizedTest
  @MethodSource("servers")
  void theTablesAreTheOnesTheTypeScriptSdkMakesOnPostgresAndMysql(String kind) throws IOException {
    assumeTrue(
        !kind.equals("none"),
        "Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL to compare the tables there too.");
    String node = Node.binary();
    assumeTrue(
        node != null,
        "node 22 or later, with the repository installed, makes the TypeScript tables; neither was found.");
    SqlStore mine = shared(kind).store();
    mine.migrate();
    String theirsUrl;
    SqlStore theirs;
    if (kind.equals("postgres")) {
      String schema = Databases.pgSchema();
      String url = Databases.pgUrl();
      theirsUrl =
          url
              + (url.contains("?") ? "&" : "?")
              + "options="
              + URLEncoder.encode("-c search_path=" + schema, StandardCharsets.UTF_8)
                  .replace("+", "%20");
      theirs = Stores.postgres(url, 120_000, schema);
    } else {
      theirsUrl = mysqlDatabase(Databases.mysqlUrls().get(kind));
      theirs = Stores.mysql(theirsUrl);
    }
    Node.Result result = Node.store(node, "migrate", theirsUrl);
    assertEquals(0, result.status(), result.err());
    List<Object> expected = describe(theirs);
    @SuppressWarnings("unchecked")
    List<Map<String, Object>> columns = (List<Map<String, Object>>) expected.get(0);
    LinkedHashSet<Object> names = new LinkedHashSet<>();
    for (Map<String, Object> c : columns) {
      names.add(c.containsKey("table_name") ? c.get("table_name") : c.get("TABLE_NAME"));
    }
    assertEquals(15, names.size());
    assertEquals(Json.stringify(expected), Json.stringify(describe(mine)));
    theirs.close();
    mine.close();
  }

  @Test
  void postgresKeepsItsStatementTimeoutAfterBuildingTablesAndDropsAnIndexABuildLeftUnusable() {
    assumeTrue(Databases.pgUrl() != null, "RUNLIGHT_TEST_PG is not set");
    SqlStore store = Databases.fresh("postgres");
    assertEquals("2min", store.db().all("SHOW statement_timeout").get(0).get("statement_timeout"));
    store.migrate();
    assertEquals(
        "2min",
        store.db().all("SHOW statement_timeout").get(0).get("statement_timeout"),
        "RESET comes back to the timeout the connection started with");
    try {
      store
          .db()
          .run(
              "UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'rl_events_link'::regclass");
    } catch (RuntimeException e) {
      assumeTrue(false, "marking an index unusable needs a superuser");
    }
    assertJson(
        List.of(Json.object("valid", false)),
        store
            .db()
            .all(
                "SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass"));
    new SqlStore(store.db()).migrate(true);
    assertJson(
        List.of(Json.object("valid", true)),
        store
            .db()
            .all(
                "SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass"),
        "dropped, and built again");
    SqlStore none = Stores.postgres(Databases.pgUrl(), 0, null);
    assertEquals("0", none.db().all("SHOW statement_timeout").get(0).get("statement_timeout"));
    none.close();
  }

  private static String lockHeld(boolean mariadb) {
    return "SELECT IS_USED_LOCK(CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))) IS NOT NULL AS held, "
        + (mariadb ? "@@max_statement_time" : "@@max_execution_time")
        + " AS t";
  }

  @ParameterizedTest
  @MethodSource("servers")
  void aMysqlSessionIsTheOneMysql2Opens(String kind) {
    assumeTrue(!kind.equals("none") && !kind.equals("postgres"), "MySQL only");
    SqlStore store = Databases.fresh(kind);
    Map<String, Object> row =
        store
            .db()
            .all(
                "SELECT @@sql_mode AS mode, @@character_set_client AS charset, VERSION() AS version")
            .get(0);
    List<String> modes = List.of(Js.string(row.get("mode")).split(","));
    assertTrue(modes.contains("IGNORE_SPACE"), "mysql2 asks for it when it connects");
    assertFalse(modes.contains("ANSI_QUOTES"));
    assertFalse(modes.contains("NO_BACKSLASH_ESCAPES"));
    assertEquals("utf8mb4", row.get("charset"));
    boolean mariadb = Js.lower(Js.string(row.get("version"))).contains("mariadb");
    String limit =
        mariadb ? "SELECT @@max_statement_time AS t" : "SELECT @@max_execution_time AS t";
    assertEquals(mariadb ? 120.0 : 120_000.0, Js.toNumber(store.db().all(limit).get(0).get("t")));

    // Names in double quotes are names, and a backslash in quoted text is a backslash.
    store.migrate();
    store.setSetting("a\\b", "c\\d");
    assertJson(
        List.of(Json.object("key", "a\\b", "value", "c\\d")),
        store
            .db()
            .all("SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE 'a\\b' ESCAPE '|'"));
    assertJson(List.of(Json.object("b", "\\")), store.db().all("SELECT '\\' AS b"));

    // One lock per database while the tables are made, with the statement timeout lifted
    // meanwhile.
    Map<String, Object> seen = store.db().exclusive(db -> db.all(lockHeld(mariadb)).get(0));
    assertEquals(1, Js.asLong(seen.get("held")));
    assertEquals(0.0, Js.toNumber(seen.get("t")));
    assertEquals(
        mariadb ? 120.0 : 120_000.0,
        Js.toNumber(store.db().all(limit).get(0).get("t")),
        "and put back after");
    assertNull(
        store
            .db()
            .all(
                "SELECT IS_USED_LOCK(CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))) AS id")
            .get(0)
            .get("id"));

    // Sums arrive as numbers the store can read, and a transaction reads what was committed before
    // each statement.
    assertEquals(
        "3",
        Js.string(
            store
                .db()
                .all("SELECT SUM(x) AS s FROM (SELECT 1 AS x UNION ALL SELECT 2) t")
                .get(0)
                .get("s")));
    Object level =
        store
            .db()
            .transaction(
                db -> db.all("SELECT @@transaction_isolation AS level").get(0).get("level"));
    assertTrue(List.of("READ-COMMITTED", "REPEATABLE-READ").contains(level), String.valueOf(level));
  }

  @ParameterizedTest
  @MethodSource("servers")
  void aConnectionTheServerDropsIsReplacedAndTheProcessCarriesOn(String kind)
      throws InterruptedException {
    assumeTrue(!kind.equals("none"), "Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL.");
    SqlStore store = Databases.fresh(kind);
    store.migrate();
    String idSql =
        kind.equals("postgres") ? "SELECT pg_backend_pid() AS id" : "SELECT CONNECTION_ID() AS id";
    long id = Js.asLong(store.db().all(idSql).get(0).get("id"));
    Db admin;
    if (kind.equals("postgres")) {
      admin = Connect.postgres(Databases.pgUrl(), 0, null);
      // JDBC sends a whole number as a bigint, which pg_terminate_backend does not take.
      admin.all("SELECT pg_terminate_backend(CAST(? AS INTEGER))", List.of(id));
    } else {
      admin = Connect.mysql(Databases.mysqlUrls().get(kind), 0);
      admin.run("KILL " + id);
    }
    admin.close();
    Thread.sleep(200);
    List<String> logged = new ArrayList<>();
    Handler handler =
        new Handler() {
          @Override
          public void publish(LogRecord record) {
            logged.add(String.valueOf(record.getMessage()));
          }

          @Override
          public void flush() {}

          @Override
          public void close() {}
        };
    Logger logger = Logger.getLogger("sh.runlight");
    logger.addHandler(handler);
    List<Map<String, Object>> sites;
    try {
      sites = store.sites();
    } finally {
      logger.removeHandler(handler);
    }
    assertJson(List.of(), sites);
    assertTrue(
        String.join("\n", logged).contains("connection was lost"),
        "the lost connection was reported");
    assertNotEquals(id, Js.asLong(store.db().all(idSql).get(0).get("id")));
  }

  @Test
  void theSchemaVersionIsTheTypeScriptOne() {
    assertEquals(11, Sql.SCHEMA_VERSION);
    assertEquals("utf8mb4_0900_bin", SqlStore.MYSQL_COLLATION);
  }
}
