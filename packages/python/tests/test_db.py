"""The Db drivers: placeholders, values, transactions, and the lock, on every database."""

from __future__ import annotations

import pytest

from runlight import db as dbs
from support.databases import kinds


@pytest.mark.parametrize("kind", kinds())
def test_round_trip(databases, kind: str) -> None:
    db = databases.db(kind)
    text = "VARCHAR(50)" if kind.startswith("mysql") or kind == "mariadb" else "TEXT"
    db.run(f"CREATE TABLE rl_t (id {text} PRIMARY KEY, n BIGINT, x REAL, note {text})")
    db.run("INSERT INTO rl_t (id, n, x, note) VALUES (?, ?, ?, ?)", ["a", 5, 1.5, "it's a \\ back?"])
    db.run("INSERT INTO rl_t (id, n, x, note) VALUES (?, ?, ?, ?)", ["b", 2**40, 2.0, None])
    rows = db.all("SELECT id, n, x, note FROM rl_t WHERE n > ? ORDER BY id", [1])
    assert [r["id"] for r in rows] == ["a", "b"]
    assert rows[0]["note"] == "it's a \\ back?"
    assert int(rows[1]["n"]) == 2**40
    assert float(rows[0]["x"]) == 1.5
    total = db.all("SELECT SUM(n) AS s FROM rl_t")[0]["s"]
    assert int(total) == 2**40 + 5

    def fail(d):
        d.run("DELETE FROM rl_t")
        raise RuntimeError("no")

    with pytest.raises(RuntimeError):
        db.transaction(fail)
    assert len(db.all("SELECT id FROM rl_t")) == 2
    db.transaction(lambda d: d.run("DELETE FROM rl_t WHERE id = ?", ["a"]))
    assert len(db.all("SELECT id FROM rl_t")) == 1
    assert db.exclusive(lambda d: 7) == 7


def test_mysql_text() -> None:
    assert dbs.mysql_text('SELECT "a" FROM t WHERE x = ? AND y = \'\\\'', ["it's"]) == (
        "SELECT `a` FROM t WHERE x = 'it\\'s' AND y = '\\\\'".replace("x = 'it\\'s'", "x = 'it\\'s'")
    )
    assert dbs.number_placeholders("a = ? AND b = '?' AND c = ?") == "a = $1 AND b = '?' AND c = $2"
