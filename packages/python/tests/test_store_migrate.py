"""Creating and upgrading the tables, and what each connection is set up to do: storage.test.ts, postgres.test.ts,
and mysql.test.ts, with the tables compared against the ones the TypeScript SDK makes (PHP MigrateTest).

As in the PHP port, a store takes a database at the current schema version on trust, and migrate(True), which the
scheduled check and the migrate command call, goes over every table and index."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import pytest
from support import databases as dbkinds
from support import store as seed
from support.databases import pg_url
from support.fixtures import PHP_FIXTURES

from runlight import db as dbs
from runlight.store import MYSQL_COLLATION, SCHEMA_VERSION, SqlStore, Stores

KINDS = dbkinds.kinds()
SERVERS = [k for k in KINDS if k != "sqlite"]
needs_server = pytest.mark.skipif(not SERVERS, reason="Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL.")


def _tables(db: Any) -> int:
    dialect = db.dialect()
    if dialect == "sqlite":
        sql = "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name LIKE 'rl\\_%' ESCAPE '\\'"
    elif dialect == "postgres":
        sql = "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = current_schema()"
    else:
        sql = "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE()"
    return int(db.all(sql)[0]["n"])


def _where(databases: Any, kind: str, tmp_path: Path) -> str:
    """A database of the kind that more than one store can open: a file, or a URL."""
    if kind == "sqlite":
        return str(tmp_path / "shared.db")
    return databases.url(kind)


def _open(kind: str, where: str) -> SqlStore:
    return Stores.sqlite(where) if kind == "sqlite" else Stores.postgres(where) if kind == "postgres" else Stores.mysql(where)


@pytest.mark.parametrize("kind", KINDS)
def test_migrating_is_safe_any_number_of_times_and_records_the_schema_version(databases: Any, kind: str) -> None:
    s = Stores.from_db(databases.db(kind))
    s.migrate()
    s.migrate()
    SqlStore(s.db).migrate()
    assert _tables(s.db) == 15
    assert s.db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'") == [{"value": "11"}]


@pytest.mark.parametrize("kind", KINDS)
def test_an_upgrade_that_stopped_after_adding_a_column_but_before_recording_its_version_starts_the_next_time(databases: Any, kind: str, tmp_path: Path) -> None:
    if kind.startswith("mysql") or kind == "mariadb":
        # MySQL refuses the version 10 upgrade's TEXT column with a default, in TypeScript too; no MySQL database was
        # ever at version 9, since MySQL support came with version 11.
        pytest.skip("MySQL tables start at version 11")
    where = _where(databases, kind, tmp_path)
    s = _open(kind, where)
    s.migrate()
    # As an upgrade from version 9 leaves things when it stops between its two steps.
    s.db.run("UPDATE rl_meta SET value = '9' WHERE \"key\" = 'schema'")
    s.close()
    nxt = _open(kind, where)
    nxt.migrate()
    assert nxt.db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'") == [{"value": "11"}]
    nxt.close()


def test_a_database_that_can_only_be_read_still_answers_reports(tmp_path: Path) -> None:
    file = str(tmp_path / "read-only.db")
    first = Stores.sqlite(file)
    first.migrate()
    site = {"id": "default", "name": "Example", "hostnames": ["example.com"], "timezone": "UTC"}
    first.upsert_site(site, 1)
    first.close()
    os.chmod(file, stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
    try:
        s = Stores.sqlite(file)
        s.migrate()
        s.upsert_site(site, 2)
        assert s.stats({"site": "default", "from": 0, "to": 1, "filters": []})["visits"] == 0
        s.close()
    finally:
        os.chmod(file, stat.S_IRUSR | stat.S_IWUSR)


def test_a_store_takes_a_current_schema_on_trust_and_the_full_pass_adds_what_is_missing(tmp_path: Path) -> None:
    file = str(tmp_path / "trust.db")
    Stores.sqlite(file).migrate()
    Stores.sqlite(file).db.run("DROP INDEX rl_events_link")

    def index(s: SqlStore) -> list[dict[str, Any]]:
        return s.db.all("SELECT name FROM sqlite_master WHERE name = 'rl_events_link'")

    request = Stores.sqlite(file)
    request.migrate()
    assert index(request) == [], "a store at the current version does not go over every index"
    cron = Stores.sqlite(file)
    cron.migrate(True)
    assert index(cron) == [{"name": "rl_events_link"}], "the full pass builds it again"


@needs_server
@pytest.mark.parametrize("kind", SERVERS)
def test_processes_starting_at_once_create_the_tables_once(databases: Any, kind: str, tmp_path: Path) -> None:
    where = _where(databases, kind, tmp_path)
    script = Path(__file__).parent / "support" / "migrate.py"
    env = {**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "src")}
    processes = [subprocess.Popen([sys.executable, str(script), kind, where], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env) for _ in range(4)]
    for process in processes:
        out, err = process.communicate(timeout=120)
        assert process.returncode == 0, f"{out} {err}"
        assert out == "ok\n"
    s = _open(kind, where)
    assert _tables(s.db) == 15
    s.close()


def test_the_tables_are_the_ones_the_typescript_sdk_makes_on_sqlite() -> None:
    theirs = Stores.sqlite(f"file:{PHP_FIXTURES / 'store.db'}?mode=ro")
    mine = Stores.sqlite(":memory:")
    mine.migrate()

    def schema(s: SqlStore) -> list[dict[str, Any]]:
        return s.db.all("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")

    assert schema(mine) == schema(theirs)
    theirs.close()


def _describe(s: SqlStore) -> list[Any]:
    if s.db.dialect() == "postgres":
        columns = s.db.all(
            "SELECT table_name, column_name, ordinal_position, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() ORDER BY table_name, ordinal_position"
        )
        indexes = s.db.all("SELECT tablename, indexname, regexp_replace(indexdef, ' ON [a-z0-9_]+\\.', ' ON ') AS def FROM pg_indexes WHERE schemaname = current_schema() ORDER BY indexname")
        return [columns, indexes]
    columns = s.db.all(
        "SELECT table_name, column_name, ordinal_position, column_type, is_nullable, column_default, collation_name, extra, generation_expression FROM information_schema.columns WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position"
    )
    indexes = s.db.all("SELECT table_name, index_name, non_unique, seq_in_index, column_name, sub_part FROM information_schema.statistics WHERE table_schema = DATABASE() ORDER BY table_name, index_name, seq_in_index")
    tables = s.db.all("SELECT table_name, table_collation, engine FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name")
    return [columns, indexes, tables]


@needs_server
@pytest.mark.parametrize("kind", SERVERS)
def test_the_tables_are_the_ones_the_typescript_sdk_makes_on_postgres_and_mysql(databases: Any, kind: str) -> None:
    binary = seed.node()
    if binary is None:
        pytest.skip("node 22 or later, with the repository installed, makes the TypeScript tables; neither was found.")
    if kind == "postgres":
        theirs_url = databases.url(kind)
        done = seed.node_store(binary, ["migrate", theirs_url])
        assert done.returncode == 0, done.stderr
        theirs = Stores.postgres(theirs_url)
        expected = _describe(theirs)
        theirs.close()
        mine = Stores.from_db(databases.db(kind))
        mine.migrate()
        actual = _describe(mine)
    else:
        # MySQL tests share one database, so TypeScript's tables are read, then dropped, then this port's made.
        url = databases.url(kind)
        done = seed.node_store(binary, ["migrate", url])
        assert done.returncode == 0, done.stderr
        theirs = Stores.mysql(url)
        expected = _describe(theirs)
        theirs.close()
        mine = Stores.from_db(databases.db(kind))
        mine.migrate()
        actual = _describe(mine)
    names = {r.get("table_name", r.get("TABLE_NAME")) for r in expected[0]}
    assert len(names) == 15
    assert actual == expected


def test_postgres_keeps_its_statement_timeout_after_building_tables_and_drops_an_index_a_build_left_unusable(databases: Any) -> None:
    if pg_url() is None:
        pytest.skip("RUNLIGHT_TEST_PG is not set")
    s = Stores.postgres(databases.url("postgres"))
    assert s.db.all("SHOW statement_timeout")[0]["statement_timeout"] == "2min"
    s.migrate()
    assert s.db.all("SHOW statement_timeout")[0]["statement_timeout"] == "2min", "RESET comes back to the timeout the connection started with"
    try:
        s.db.run("UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'rl_events_link'::regclass")
    except Exception:
        s.close()
        pytest.skip("marking an index unusable needs a superuser")
    assert s.db.all("SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass") == [{"valid": False}]
    SqlStore(s.db).migrate(True)
    assert s.db.all("SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass") == [{"valid": True}], "dropped, and built again"
    s.close()
    none = Stores.postgres(pg_url() or "", statement_timeout=0)
    assert none.db.all("SHOW statement_timeout")[0]["statement_timeout"] == "0"
    none.close()


@needs_server
@pytest.mark.parametrize("kind", SERVERS)
def test_a_mysql_session_is_the_one_mysql2_opens(databases: Any, kind: str) -> None:
    if kind == "postgres":
        pytest.skip("MySQL only")
    s = Stores.from_db(databases.db(kind))
    row = s.db.all("SELECT @@sql_mode AS mode, @@character_set_client AS charset, VERSION() AS version")[0]
    modes = str(row["mode"]).split(",")
    assert "IGNORE_SPACE" in modes, "mysql2 asks for it when it connects"
    assert "ANSI_QUOTES" not in modes
    assert "NO_BACKSLASH_ESCAPES" not in modes
    assert row["charset"] == "utf8mb4"
    mariadb = "mariadb" in str(row["version"]).lower()
    timeout = "SELECT @@max_statement_time AS t" if mariadb else "SELECT @@max_execution_time AS t"
    assert s.db.all(timeout)[0]["t"] == (120 if mariadb else 120_000)

    # Names in double quotes are names, and a backslash in quoted text is a backslash.
    s.migrate()
    s.set_setting("a\\b", "c\\d")
    assert s.db.all("SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE 'a\\b' ESCAPE '|'") == [{"key": "a\\b", "value": "c\\d"}]
    assert s.db.all("SELECT '\\' AS b") == [{"b": "\\"}]

    # One lock per database while the tables are made, with the statement timeout lifted meanwhile.
    lock = "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))"
    seen = s.db.exclusive(lambda db: db.all(f"SELECT IS_USED_LOCK({lock}) IS NOT NULL AS held, {'@@max_statement_time' if mariadb else '@@max_execution_time'} AS t")[0])
    assert int(seen["held"]) == 1
    assert seen["t"] == 0
    assert s.db.all(timeout)[0]["t"] == (120 if mariadb else 120_000), "and put back after"
    assert s.db.all(f"SELECT IS_USED_LOCK({lock}) AS id")[0]["id"] is None

    # Sums arrive as numbers the store can read, and a transaction reads what was committed before each statement.
    assert str(s.db.all("SELECT SUM(x) AS s FROM (SELECT 1 AS x UNION ALL SELECT 2) t")[0]["s"]) == "3"
    level = s.db.transaction(lambda db: db.all("SELECT @@transaction_isolation AS level")[0]["level"])
    assert level in ("READ-COMMITTED", "REPEATABLE-READ")


@needs_server
@pytest.mark.parametrize("kind", SERVERS)
def test_a_connection_the_server_drops_is_replaced_and_the_process_carries_on(databases: Any, kind: str, capsys: Any) -> None:
    s = Stores.from_db(databases.db(kind))
    s.migrate()
    if kind == "postgres":
        id = s.db.all("SELECT pg_backend_pid() AS id")[0]["id"]
        admin = dbs.postgres(pg_url() or "")
        admin.all("SELECT pg_terminate_backend(?)", [int(id)])
    else:
        id = s.db.all("SELECT CONNECTION_ID() AS id")[0]["id"]
        admin = dbs.mysql(dbkinds.mysql_urls()[kind])
        admin.run(f"KILL {int(id)}")
    admin.close()
    time.sleep(0.2)
    assert s.sites() == []
    assert "connection was lost" in capsys.readouterr().err, "the lost connection was reported"
    again = s.db.all("SELECT pg_backend_pid() AS id" if kind == "postgres" else "SELECT CONNECTION_ID() AS id")[0]["id"]
    assert again != id


def test_the_schema_version_is_the_typescript_one() -> None:
    assert SCHEMA_VERSION == 11
    assert MYSQL_COLLATION == "utf8mb4_0900_bin"
