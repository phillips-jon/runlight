# frozen_string_literal: true

require "test_helper"

# The SQL store.ts builds, and how the MySQL driver rewrites it (mysql.test.ts).
class StoreSqlTest < Minitest::Test
  Sql = Runlight::Store::Sql
  Database = Runlight::Db::Database

  def test_values_fill_placeholders_outside_quotes_only_names_are_quoted_with_backticks_and_backslashes_stay_literal
    escape = ->(value) { value.is_a?(String) ? "'#{value}'" : (value.nil? ? "null" : value.to_s) }
    assert_equal "SELECT `key`, 'x' FROM t WHERE a = '?' AND b LIKE 2 ESCAPE '\\\\' AND c = null",
                 Database.mysql_text("SELECT \"key\", ? FROM t WHERE a = '?' AND b LIKE ? ESCAPE '\\' AND c = ?", ["x", 2, nil], &escape)
    assert_equal "SELECT 'it\\'s', NULL, 1.5, 'a\\\\b'", Database.mysql_text("SELECT ?, ?, ?, ?", ["it's", nil, 1.5, "a\\b"]), "mysql2's own escaping"
    assert_equal "SELECT `a``b`", Database.mysql_text('SELECT "a`b"')
    error = assert_raises(ArgumentError) { Database.mysql_text("SELECT ?, ?", [1]) }
    assert_includes error.message, "more placeholders"
    error = assert_raises(ArgumentError) { Database.mysql_text("SELECT ?", [1, 2]) }
    assert_includes error.message, "more values"
  end

  def test_patterns
    assert_equal "/blog/*/[[]x[?]]", Sql.glob_pattern("/blog/*/[x?]")
    assert_equal "/blog/%/50\\%\\_\\\\", Sql.like_pattern("/blog/*/50%_\\")
    assert_equal "*[üÜ][bB][eE][rR] [[][*][?]1ß*", Sql.any_case("Über [*?1ß")
    assert_equal "*\u{1F600}[éÉ]*", Sql.any_case("\u{1F600}é")
  end

  def test_upserts_are_written_each_databases_way
    assert_equal "INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON CONFLICT (day) DO NOTHING", Sql.upsert("sqlite", "rl_salts", %w[day salt], ["day"], [])
    assert_equal "INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON DUPLICATE KEY UPDATE day = day", Sql.upsert("mysql", "rl_salts", %w[day salt], ["day"], [])
    assert_equal 'INSERT INTO rl_meta ("key", value) VALUES (?, ?) ON CONFLICT ("key") DO UPDATE SET value = excluded.value', Sql.upsert("postgres", "rl_meta", ['"key"', "value"], ['"key"'], ["value"])
    assert_equal 'INSERT INTO rl_meta ("key", value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)', Sql.upsert("mysql", "rl_meta", ['"key"', "value"], ['"key"'], ["value"])
    assert_equal "(s.started_at DIV 900000)", Sql.div("mysql", "s.started_at", 900_000)
    assert_equal "(s.started_at / 900000)", Sql.div("postgres", "s.started_at", 900_000)
    assert_equal "CAST(? AS CHAR)", Sql.as_text("mysql", "?")
    buckets = [{ "start" => 0, "end" => 1 }, { "start" => 1, "end" => 2 }]
    assert_equal "VALUES (CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT)), (?, ?, ?)", Sql.bucket_table("postgres", buckets)
    assert_equal "SELECT ? AS i, ? AS bs, ? AS be UNION ALL SELECT ?, ?, ?", Sql.bucket_table("mysql", buckets)
  end

  def test_filters_become_conditions
    f = ->(d, op, v) { { "dimension" => d, "op" => op, "value" => v } }
    assert_equal({ "sql" => "e.path = ?", "params" => ["/caf%C3%A9"] }, Sql.condition(f.("page", "is", "/café"), "sqlite"))
    assert_equal({ "sql" => "s.entry_path = ?", "params" => ["/x"] }, Sql.condition(f.("entry", "not", "/x"), "sqlite", true))
    assert_equal({ "sql" => "s.country <> ?", "params" => ["GB"] }, Sql.condition(f.("country", "not", "GB"), "postgres"))
    assert_equal({ "sql" => "s.source GLOB ?", "params" => ["*[gG][oO]*"] }, Sql.condition(f.("source", "contains", "go"), "sqlite"))
    assert_equal({ "sql" => "LOWER(s.source) LIKE ? ESCAPE '\\'", "params" => ["%g\\_o%"] }, Sql.condition(f.("source", "contains", "G_o"), "mysql"))
    # A path in its given, lower, upper, and title case, each encoded.
    assert_equal(
      { "sql" => "(e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\')",
        "params" => ["%\\%C3\\%BCBER-uns%", "%\\%C3\\%BCber-uns%", "%\\%C3\\%9CBER-UNS%", "%\\%C3\\%9Cber-Uns%"] },
      Sql.condition(f.("page", "contains", "üBER-uns"), "sqlite"),
    )
    scope = Sql.visit_scope([f.("event", "not", "Signup"), f.("country", "is", "GB")], "default", 10, 20, "postgres")
    assert_equal " AND NOT EXISTS (SELECT 1 FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event' AND e.name = ? AND e.session = s.id) AND s.country = ?", scope["sql"]
    assert_equal ["default", 10, 20 + Sql::EVENT_TAIL_MS, "Signup", "GB"], scope["params"]
    assert_nil Sql.pageviews_of([f.("country", "is", "GB"), f.("page", "not", "/x")], "default", 0, 1, "sqlite")
    assert_equal ["default", 0, 1 + Sql::EVENT_TAIL_MS, "/a", "/b", "h"],
                 Sql.pageviews_of([f.("page", "is", "/a"), f.("page", "is", "/b"), f.("hostname", "is", "h")], "default", 0, 1, "sqlite")["params"]
  end

  def test_text_is_ordered_by_code_point
    values = ["b", "a ", "A", "\u{FFFD}", "\u{1F600}", "a", "é"]
    assert_equal ["A", "a", "a ", "b", "é", "\u{FFFD}", "\u{1F600}"], values.sort { |a, b| Sql.code_order(a, b) },
                 "an emoji after U+FFFD, as code points order them and UTF-16 units do not"
  end
end
