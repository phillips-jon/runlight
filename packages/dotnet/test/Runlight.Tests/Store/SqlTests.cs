using System;
using System.Collections.Generic;
using Runlight.Store;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Store;

/// <summary>The SQL store.ts builds, and how the MySQL driver rewrites it (mysql.test.ts).</summary>
public sealed class SqlTests
{
    private static JsObject F(string d, string op, string v) => new() { ["dimension"] = d, ["op"] = op, ["value"] = v };

    [Fact]
    public void Values_fill_placeholders_outside_quotes_only_names_are_quoted_with_backticks_and_backslashes_stay_literal()
    {
        static string Escape(object? value) => value is string s ? "'" + s + "'" : value == null ? "null" : Js.String(value);
        Assert.Equal(
            @"SELECT `key`, 'x' FROM t WHERE a = '?' AND b LIKE 2 ESCAPE '\\' AND c = null",
            Stores.MysqlText(@"SELECT ""key"", ? FROM t WHERE a = '?' AND b LIKE ? ESCAPE '\' AND c = ?", ["x", 2L, null], Escape));
        // mysql2's own escaping.
        Assert.Equal(@"SELECT 'it\'s', NULL, 1.5, 'a\\b'", Stores.MysqlText("SELECT ?, ?, ?, ?", ["it's", null, 1.5, @"a\b"]));
        Assert.Equal("SELECT `a``b`", Stores.MysqlText("SELECT \"a`b\""));
        var more = Assert.Throws<ArgumentException>(() => Stores.MysqlText("SELECT ?, ?", [1L]));
        Assert.Contains("more placeholders", more.Message, StringComparison.Ordinal);
        var fewer = Assert.Throws<ArgumentException>(() => Stores.MysqlText("SELECT ?", [1L, 2L]));
        Assert.Contains("more values", fewer.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Patterns()
    {
        Assert.Equal("/blog/*/[[]x[?]]", Sql.GlobPattern("/blog/*/[x?]"));
        Assert.Equal(@"/blog/%/50\%\_\\", Sql.LikePattern(@"/blog/*/50%_\"));
        Assert.Equal("*[üÜ][bB][eE][rR] [[][*][?]1ß*", Sql.AnyCase("Über [*?1ß"));
        Assert.Equal("*😀[éÉ]*", Sql.AnyCase("😀é"));
    }

    [Fact]
    public void Upserts_are_written_each_databases_way()
    {
        Assert.Equal("INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON CONFLICT (day) DO NOTHING", Sql.Upsert("sqlite", "rl_salts", ["day", "salt"], ["day"], []));
        Assert.Equal("INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON DUPLICATE KEY UPDATE day = day", Sql.Upsert("mysql", "rl_salts", ["day", "salt"], ["day"], []));
        Assert.Equal("INSERT INTO rl_meta (\"key\", value) VALUES (?, ?) ON CONFLICT (\"key\") DO UPDATE SET value = excluded.value", Sql.Upsert("postgres", "rl_meta", ["\"key\"", "value"], ["\"key\""], ["value"]));
        Assert.Equal("INSERT INTO rl_meta (\"key\", value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)", Sql.Upsert("mysql", "rl_meta", ["\"key\"", "value"], ["\"key\""], ["value"]));
        Assert.Equal("(s.started_at DIV 900000)", Sql.Div("mysql", "s.started_at", 900000));
        Assert.Equal("(s.started_at / 900000)", Sql.Div("postgres", "s.started_at", 900000));
        Assert.Equal("CAST(? AS CHAR)", Sql.AsText("mysql", "?"));
        Assert.Equal("VALUES (CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT)), (?, ?, ?)", Sql.BucketTable("postgres", 2));
        Assert.Equal("SELECT ? AS i, ? AS bs, ? AS be UNION ALL SELECT ?, ?, ?", Sql.BucketTable("mysql", 2));
    }

    private static string Part(SqlPart part) => J(new JsObject { ["sql"] = part.Sql, ["params"] = part.Params });

    [Fact]
    public void Filters_become_conditions()
    {
        Assert.Equal(J(new JsObject { ["sql"] = "e.path = ?", ["params"] = new List<object?> { "/caf%C3%A9" } }), Part(Sql.Condition(F("page", "is", "/café"), "sqlite")));
        Assert.Equal(J(new JsObject { ["sql"] = "s.entry_path = ?", ["params"] = new List<object?> { "/x" } }), Part(Sql.Condition(F("entry", "not", "/x"), "sqlite", true)));
        Assert.Equal(J(new JsObject { ["sql"] = "s.country <> ?", ["params"] = new List<object?> { "GB" } }), Part(Sql.Condition(F("country", "not", "GB"), "postgres")));
        Assert.Equal(J(new JsObject { ["sql"] = "s.source GLOB ?", ["params"] = new List<object?> { "*[gG][oO]*" } }), Part(Sql.Condition(F("source", "contains", "go"), "sqlite")));
        Assert.Equal(J(new JsObject { ["sql"] = @"LOWER(s.source) LIKE ? ESCAPE '\'", ["params"] = new List<object?> { @"%g\_o%" } }), Part(Sql.Condition(F("source", "contains", "G_o"), "mysql")));
        // A path in its given, lower, upper, and title case, each encoded.
        Assert.Equal(
            J(new JsObject
            {
                ["sql"] = @"(e.path LIKE ? ESCAPE '\' OR e.path LIKE ? ESCAPE '\' OR e.path LIKE ? ESCAPE '\' OR e.path LIKE ? ESCAPE '\')",
                ["params"] = new List<object?> { @"%\%C3\%BCBER-uns%", @"%\%C3\%BCber-uns%", @"%\%C3\%9CBER-UNS%", @"%\%C3\%9Cber-Uns%" },
            }),
            Part(Sql.Condition(F("page", "contains", "üBER-uns"), "sqlite")));
        var scope = Sql.VisitScope([F("event", "not", "Signup"), F("country", "is", "GB")], "default", 10, 20, "postgres");
        Assert.Equal(" AND NOT EXISTS (SELECT 1 FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event' AND e.name = ? AND e.session = s.id) AND s.country = ?", scope.Sql);
        Assert.Equal(J(new List<object?> { "default", 10L, 20 + Sql.EventTailMs, "Signup", "GB" }), J(scope.Params));
        Assert.Null(Sql.PageviewsOf([F("country", "is", "GB"), F("page", "not", "/x")], "default", 0, 1, "sqlite"));
        Assert.Equal(J(new List<object?> { "default", 0L, 1 + Sql.EventTailMs, "/a", "/b", "h" }), J(Sql.PageviewsOf([F("page", "is", "/a"), F("page", "is", "/b"), F("hostname", "is", "h")], "default", 0, 1, "sqlite")!.Params));
    }

    private static readonly string Replacement = ((char)0xFFFD).ToString();

    [Fact]
    public void Text_is_ordered_by_code_point()
    {
        var values = new List<string> { "b", "a ", "A", Replacement, char.ConvertFromUtf32(0x1F600), "a", "é" };
        values.Sort(Sql.CodeOrder);
        // An emoji after U+FFFD, as code points order them and UTF-16 units do not.
        Assert.Equal(["A", "a", "a ", "b", "é", Replacement, char.ConvertFromUtf32(0x1F600)], values);
    }
}
