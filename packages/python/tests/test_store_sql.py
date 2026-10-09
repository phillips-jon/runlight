"""The SQL store.ts builds, and how the MySQL driver rewrites it (mysql.test.ts; PHP SqlTest)."""

from __future__ import annotations

from typing import Any

import pytest

from runlight.store import Stores, sql


def test_values_fill_placeholders_outside_quotes_only_names_are_quoted_with_backticks_and_backslashes_stay_literal() -> None:
    def escape(value: Any) -> str:
        return f"'{value}'" if isinstance(value, str) else "null" if value is None else str(value)

    assert (
        Stores.mysql_text("SELECT \"key\", ? FROM t WHERE a = '?' AND b LIKE ? ESCAPE '\\' AND c = ?", ["x", 2, None], escape)
        == "SELECT `key`, 'x' FROM t WHERE a = '?' AND b LIKE 2 ESCAPE '\\\\' AND c = null"
    )
    assert Stores.mysql_text("SELECT ?, ?, ?, ?", ["it's", None, 1.5, "a\\b"]) == "SELECT 'it\\'s', NULL, 1.5, 'a\\\\b'", "mysql2's own escaping"
    assert Stores.mysql_text('SELECT "a`b"') == "SELECT `a``b`"
    with pytest.raises(ValueError, match="more placeholders"):
        Stores.mysql_text("SELECT ?, ?", [1])
    with pytest.raises(ValueError, match="more values"):
        Stores.mysql_text("SELECT ?", [1, 2])


def test_patterns() -> None:
    assert sql.glob_pattern("/blog/*/[x?]") == "/blog/*/[[]x[?]]"
    assert sql.like_pattern("/blog/*/50%_\\") == "/blog/%/50\\%\\_\\\\"
    assert sql.any_case("Über [*?1ß") == "*[üÜ][bB][eE][rR] [[][*][?]1ß*"
    assert sql.any_case("😀é") == "*😀[éÉ]*"


def test_upserts_are_written_each_databases_way() -> None:
    assert sql.upsert("sqlite", "rl_salts", ["day", "salt"], ["day"], []) == "INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON CONFLICT (day) DO NOTHING"
    assert sql.upsert("mysql", "rl_salts", ["day", "salt"], ["day"], []) == "INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON DUPLICATE KEY UPDATE day = day"
    assert (
        sql.upsert("postgres", "rl_meta", ['"key"', "value"], ['"key"'], ["value"])
        == 'INSERT INTO rl_meta ("key", value) VALUES (?, ?) ON CONFLICT ("key") DO UPDATE SET value = excluded.value'
    )
    assert sql.upsert("mysql", "rl_meta", ['"key"', "value"], ['"key"'], ["value"]) == 'INSERT INTO rl_meta ("key", value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)'
    assert sql.div("mysql", "s.started_at", 900000) == "(s.started_at DIV 900000)"
    assert sql.div("postgres", "s.started_at", 900000) == "(s.started_at / 900000)"
    assert sql.as_text("mysql", "?") == "CAST(? AS CHAR)"
    buckets = [{"start": 0, "end": 1}, {"start": 1, "end": 2}]
    assert sql.bucket_table("postgres", buckets) == "VALUES (CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT)), (?, ?, ?)"
    assert sql.bucket_table("mysql", buckets) == "SELECT ? AS i, ? AS bs, ? AS be UNION ALL SELECT ?, ?, ?"


def test_filters_become_conditions() -> None:
    def f(d: str, op: str, v: str) -> dict[str, str]:
        return {"dimension": d, "op": op, "value": v}

    assert sql.condition(f("page", "is", "/café"), "sqlite") == {"sql": "e.path = ?", "params": ["/caf%C3%A9"]}
    assert sql.condition(f("entry", "not", "/x"), "sqlite", True) == {"sql": "s.entry_path = ?", "params": ["/x"]}
    assert sql.condition(f("country", "not", "GB"), "postgres") == {"sql": "s.country <> ?", "params": ["GB"]}
    assert sql.condition(f("source", "contains", "go"), "sqlite") == {"sql": "s.source GLOB ?", "params": ["*[gG][oO]*"]}
    assert sql.condition(f("source", "contains", "G_o"), "mysql") == {"sql": "LOWER(s.source) LIKE ? ESCAPE '\\'", "params": ["%g\\_o%"]}
    # A path in its given, lower, upper, and title case, each encoded.
    assert sql.condition(f("page", "contains", "üBER-uns"), "sqlite") == {
        "sql": "(e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\')",
        "params": ["%\\%C3\\%BCBER-uns%", "%\\%C3\\%BCber-uns%", "%\\%C3\\%9CBER-UNS%", "%\\%C3\\%9Cber-Uns%"],
    }
    scope = sql.visit_scope([f("event", "not", "Signup"), f("country", "is", "GB")], "default", 10, 20, "postgres")
    assert scope["sql"] == " AND NOT EXISTS (SELECT 1 FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event' AND e.name = ? AND e.session = s.id) AND s.country = ?"
    assert scope["params"] == ["default", 10, 20 + sql.EVENT_TAIL_MS, "Signup", "GB"]
    assert sql.pageviews_of([f("country", "is", "GB"), f("page", "not", "/x")], "default", 0, 1, "sqlite") is None
    pv = sql.pageviews_of([f("page", "is", "/a"), f("page", "is", "/b"), f("hostname", "is", "h")], "default", 0, 1, "sqlite")
    assert pv is not None and pv["params"] == ["default", 0, 1 + sql.EVENT_TAIL_MS, "/a", "/b", "h"]


def test_text_is_ordered_by_code_point() -> None:
    import functools

    values = ["b", "a ", "A", "�", "\U0001f600", "a", "é"]
    values.sort(key=functools.cmp_to_key(sql.code_order))
    assert values == ["A", "a", "a ", "b", "é", "�", "\U0001f600"], "an emoji after U+FFFD, as code points order them and UTF-16 units do not"
