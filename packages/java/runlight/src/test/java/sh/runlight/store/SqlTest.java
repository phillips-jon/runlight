package sh.runlight.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.Json;

/** The SQL store.ts builds, and how the MySQL driver rewrites it (mysql.test.ts). */
class SqlTest {
  /**
   * The Java store binds every value through JDBC, so the PHP test's values written into the text
   * (and its errors for too few or too many) have nothing to check here: names and quoted text are
   * what is rewritten.
   */
  @Test
  void onlyNamesAreQuotedWithBackticksAndBackslashesStayLiteral() {
    assertEquals(
        "SELECT `key`, ? FROM t WHERE a = '?' AND b LIKE ? ESCAPE '\\\\' AND c = ?",
        SqlStore.mysqlText(
            "SELECT \"key\", ? FROM t WHERE a = '?' AND b LIKE ? ESCAPE '\\' AND c = ?"));
    assertEquals("SELECT 'a\\\\b'", SqlStore.mysqlText("SELECT 'a\\b'"));
    assertEquals("SELECT `a``b`", SqlStore.mysqlText("SELECT \"a`b\""));
  }

  @Test
  void patterns() {
    assertEquals("/blog/*/[[]x[?]]", Sql.globPattern("/blog/*/[x?]"));
    assertEquals("/blog/%/50\\%\\_\\\\", Sql.likePattern("/blog/*/50%_\\"));
    assertEquals("*[üÜ][bB][eE][rR] [[][*][?]1ß*", Sql.anyCase("Über [*?1ß"));
    assertEquals("*😀[éÉ]*", Sql.anyCase("😀é"));
  }

  @Test
  void upsertsAreWrittenEachDatabasesWay() {
    assertEquals(
        "INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON CONFLICT (day) DO NOTHING",
        Sql.upsert("sqlite", "rl_salts", List.of("day", "salt"), List.of("day"), List.of()));
    assertEquals(
        "INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON DUPLICATE KEY UPDATE day = day",
        Sql.upsert("mysql", "rl_salts", List.of("day", "salt"), List.of("day"), List.of()));
    assertEquals(
        "INSERT INTO rl_meta (\"key\", value) VALUES (?, ?) ON CONFLICT (\"key\") DO UPDATE SET value = excluded.value",
        Sql.upsert(
            "postgres",
            "rl_meta",
            List.of("\"key\"", "value"),
            List.of("\"key\""),
            List.of("value")));
    assertEquals(
        "INSERT INTO rl_meta (\"key\", value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)",
        Sql.upsert(
            "mysql", "rl_meta", List.of("\"key\"", "value"), List.of("\"key\""), List.of("value")));
    assertEquals("(s.started_at DIV 900000)", Sql.div("mysql", "s.started_at", 900000));
    assertEquals("(s.started_at / 900000)", Sql.div("postgres", "s.started_at", 900000));
    assertEquals("CAST(? AS CHAR)", Sql.asText("mysql", "?"));
    assertEquals(
        "VALUES (CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT)), (?, ?, ?)",
        Sql.bucketTable("postgres", 2));
    assertEquals(
        "SELECT ? AS i, ? AS bs, ? AS be UNION ALL SELECT ?, ?, ?", Sql.bucketTable("mysql", 2));
  }

  private static Map<String, Object> f(String d, String op, String v) {
    return Json.object("dimension", d, "op", op, "value", v);
  }

  private static void assertPiece(String sql, List<Object> params, Sql.Piece piece) {
    assertEquals(sql, piece.sql());
    assertEquals(Json.stringify(params), Json.stringify(piece.params()));
  }

  @Test
  void filtersBecomeConditions() {
    assertPiece(
        "e.path = ?", List.of("/caf%C3%A9"), Sql.condition(f("page", "is", "/café"), "sqlite"));
    assertPiece(
        "s.entry_path = ?", List.of("/x"), Sql.condition(f("entry", "not", "/x"), "sqlite", true));
    assertPiece(
        "s.country <> ?", List.of("GB"), Sql.condition(f("country", "not", "GB"), "postgres"));
    assertPiece(
        "s.source GLOB ?",
        List.of("*[gG][oO]*"),
        Sql.condition(f("source", "contains", "go"), "sqlite"));
    assertPiece(
        "LOWER(s.source) LIKE ? ESCAPE '\\'",
        List.of("%g\\_o%"),
        Sql.condition(f("source", "contains", "G_o"), "mysql"));
    // A path in its given, lower, upper, and title case, each encoded.
    assertPiece(
        "(e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\')",
        List.of(
            "%\\%C3\\%BCBER-uns%",
            "%\\%C3\\%BCber-uns%", "%\\%C3\\%9CBER-UNS%", "%\\%C3\\%9Cber-Uns%"),
        Sql.condition(f("page", "contains", "üBER-uns"), "sqlite"));
    Sql.Piece scope =
        Sql.visitScope(
            List.of(f("event", "not", "Signup"), f("country", "is", "GB")),
            "default",
            10,
            20,
            "postgres");
    assertPiece(
        " AND NOT EXISTS (SELECT 1 FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event' AND e.name = ? AND e.session = s.id) AND s.country = ?",
        List.of("default", 10L, 20 + Sql.EVENT_TAIL_MS, "Signup", "GB"),
        scope);
    assertNull(
        Sql.pageviewsOf(
            List.of(f("country", "is", "GB"), f("page", "not", "/x")), "default", 0, 1, "sqlite"));
    assertEquals(
        Json.stringify(List.of("default", 0L, 1 + Sql.EVENT_TAIL_MS, "/a", "/b", "h")),
        Json.stringify(
            Sql.pageviewsOf(
                    List.of(f("page", "is", "/a"), f("page", "is", "/b"), f("hostname", "is", "h")),
                    "default",
                    0,
                    1,
                    "sqlite")
                .params()));
  }

  @Test
  void textIsOrderedByCodePoint() {
    List<String> values = new ArrayList<>(List.of("b", "a ", "A", "�", "😀", "a", "é"));
    values.sort(Sql::codeOrder);
    assertEquals(
        List.of("A", "a", "a ", "b", "é", "�", "😀"),
        values,
        "an emoji after U+FFFD, as code points order them and UTF-16 units do not");
  }
}
