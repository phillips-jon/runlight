"""One database, both implementations. packages/php/tests/fixtures/store.db was built by the TypeScript SDK and
store.json holds what its SqlStore reads answered (scripts/php-fixtures-store.mts); the Python store must answer the
same over a copy of that file, and over the same rows copied into Postgres and MySQL. Then the other way: Python
writes a database and the TypeScript store reads it, when node is at hand (PHP CrossImplementationTest)."""

from __future__ import annotations

import os
import shutil
from typing import Any

import pytest
from support import databases as dbkinds
from support import store as seed
from support.fixtures import PHP_FIXTURES, load

from runlight import _js
from runlight.store import SqlStore, Stores

TABLES = ["rl_meta", "rl_sites", "rl_salts", "rl_sessions", "rl_events", "rl_links", "rl_link_domains", "rl_shares", "rl_goals", "rl_settings", "rl_reports", "rl_tokens", "rl_funnels", "rl_rollup_days", "rl_rollups"]
SERVERS = [k for k in dbkinds.kinds() if k != "sqlite"]


def _copy(tmp_path: Any) -> str:
    file = str(tmp_path / "store.db")
    shutil.copy(PHP_FIXTURES / "store.db", file)
    return file


def _assert_answers(store: SqlStore, label: str) -> None:
    calls = load("store")["calls"]
    failures = []
    for i, call in enumerate(calls):
        expected = _js.dumps(call["result"])
        try:
            actual = _js.dumps(seed.answer(store, call))
        except Exception as error:  # noqa: BLE001
            actual = f"{type(error).__name__}: {error}"
        if actual != expected:
            failures.append(f"#{i} {call['method']}({_js.dumps(call['args'])[:300]})\n  expected {expected}\n  actual   {actual}")
    assert failures[:15] == [], f"{label}: {len(failures)} of {len(calls)} reads differ"


def test_the_fixture_covers_every_kind_of_read() -> None:
    calls = load("store")["calls"]
    methods = {c["method"] for c in calls}
    assert len(calls) > 1500
    for method in ("stats", "series", "hourly", "breakdown", "goalTotalsAll", "goalSeries", "funnelCounts", "journeyPages", "eventPropKeys", "eventPropValues", "links", "linkSeries", "realtime"):
        assert method in methods


def test_python_reads_a_database_the_typescript_sdk_wrote_and_answers_the_same(tmp_path: Any) -> None:
    store = Stores.sqlite(_copy(tmp_path))
    store.migrate()
    _assert_answers(store, "sqlite")
    # Opening it changed nothing a reader would see: the schema is the same version.
    assert store.db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'") == [{"value": "11"}]
    store.close()


@pytest.mark.skipif(not SERVERS, reason="Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL to compare Postgres and MySQL too.")
@pytest.mark.parametrize("kind", SERVERS)
def test_the_same_rows_in_postgres_and_mysql_answer_the_same(databases: Any, tmp_path: Any, kind: str) -> None:
    source = Stores.sqlite(_copy(tmp_path))
    target = Stores.from_db(databases.db(kind))
    target.migrate()

    def fill(into: SqlStore) -> None:
        for table in TABLES:
            into.db.run(f"DELETE FROM {table}")
            for row in source.db.all(f"SELECT * FROM {table}"):
                columns = ", ".join(f'"{c}"' for c in row)
                into.db.run(f"INSERT INTO {table} ({columns}) VALUES ({', '.join('?' for _ in row)})", list(row.values()))

    target.transaction(fill)
    _assert_answers(target, kind)
    source.close()


def test_the_typescript_sdk_reads_a_database_python_wrote_and_answers_the_same(tmp_path: Any) -> None:
    binary = seed.node()
    if binary is None:
        pytest.skip("node 22 or later, with the repository installed, reads the Python database; neither was found.")
    file = str(tmp_path / "python.db")
    store = Stores.sqlite(file)
    calls = seed.everything(store)
    mine = [seed.answer(store, call) for call in calls]
    store.db.run("PRAGMA journal_mode = DELETE")
    store.close()

    calls_file = tmp_path / "calls.json"
    calls_file.write_text(_js.dumps(calls), "utf-8")
    done = seed.node_store(binary, ["read", file, str(calls_file)])
    assert done.returncode == 0, done.stderr
    theirs = _js.loads(done.stdout)
    assert len(theirs) == len(calls)
    failures = []
    for i, call in enumerate(calls):
        a = _js.dumps(mine[i])
        b = _js.dumps(theirs[i])
        if a != b:
            failures.append(f"#{i} {call['method']}\n  py {a}\n  ts {b}")
    assert failures[:15] == [], f"{len(failures)} reads differ"
    assert len(calls) > 100
    assert os.path.exists(file)
