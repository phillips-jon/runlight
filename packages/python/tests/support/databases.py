"""The databases the store and conformance tests run on. See conftest.py."""

from __future__ import annotations

import fcntl
import os
import re
import secrets
import sys
import tempfile
from collections.abc import Callable
from typing import Any

from runlight import db as dbs

PG_URL = "postgres://joncphillips@127.0.0.1:5432/runlight_test_python"
MYSQL_URLS = {
    "mysql": "mysql://root:runlight@127.0.0.1:33084/runlight_test_python",
    "mariadb": "mysql://root:runlight@127.0.0.1:33114/runlight_test_python",
}


def _env(name: str) -> str | None:
    value = os.environ.get(name, "").strip()
    return value or None


def pg_url() -> str | None:
    value = _env("RUNLIGHT_TEST_PG")
    if value is None:
        return None
    return value if "://" in value else PG_URL


def mysql_urls() -> dict[str, str]:
    value = _env("RUNLIGHT_TEST_MYSQL")
    if value is None:
        return {}
    urls = [u for u in re.split(r"[\s,]+", value) if "://" in u]
    if not urls:
        return dict(MYSQL_URLS)
    return {("mysql" if i == 0 else f"mysql{i}"): url for i, url in enumerate(urls)}


def kinds() -> list[str]:
    """The kinds of database to run on: sqlite always, postgres and the MySQL servers when asked for."""
    out = ["sqlite"]
    if pg_url() is not None:
        out.append("postgres")
    out.extend(mysql_urls())
    return out


def _empty_mysql(db: Any) -> None:
    """Drops every table in the test database, so a test starts from nothing."""
    rows = db.all("SELECT table_name AS name FROM information_schema.tables WHERE table_schema = DATABASE()")
    if rows:
        db.run("SET FOREIGN_KEY_CHECKS = 0")
        for row in rows:
            name = row.get("name") or row.get("NAME") or row.get("TABLE_NAME")
            db.run(f"DROP TABLE IF EXISTS {dbs.quote_name(str(name), '`')}")
        db.run("SET FOREIGN_KEY_CHECKS = 1")


class Databases:
    """Fresh, empty databases, dropped (or emptied) by cleanup()."""

    def __init__(self) -> None:
        self._cleanups: list[Callable[[], None]] = []
        self._lock_file: Any = None

    def db(self, kind: str) -> Any:
        """A fresh Db of this kind."""
        if kind == "sqlite":
            return dbs.sqlite(":memory:")
        if kind == "postgres":
            url = pg_url()
            assert url is not None
            name = "rl_test_" + secrets.token_hex(5)
            admin = dbs.postgres(url)
            admin.run(f'CREATE SCHEMA "{name}"')
            db = dbs.postgres(url, schema=name)

            def drop() -> None:
                db.close()
                admin.run(f'DROP SCHEMA IF EXISTS "{name}" CASCADE')
                admin.close()

            self._cleanups.append(drop)
            return db
        url = mysql_urls()[kind]
        self._hold_mysql()
        db = dbs.mysql(url)
        _empty_mysql(db)

        def empty() -> None:
            db.close()

        self._cleanups.append(empty)
        return db

    def url(self, kind: str) -> str:
        """The connection URL for a database of this kind (for a test that opens its own connections). For
        Postgres the schema comes in the URL's options."""
        if kind == "postgres":
            url = pg_url()
            assert url is not None
            name = "rl_test_" + secrets.token_hex(5)
            admin = dbs.postgres(url)
            admin.run(f'CREATE SCHEMA "{name}"')

            def drop() -> None:
                admin.run(f'DROP SCHEMA IF EXISTS "{name}" CASCADE')
                admin.close()

            self._cleanups.append(drop)
            sep = "&" if "?" in url else "?"
            return f"{url}{sep}options=-c%20search_path%3D{name}"
        url = mysql_urls()[kind]
        self._hold_mysql()
        admin = dbs.mysql(url)
        _empty_mysql(admin)
        admin.close()
        return url

    def _hold_mysql(self) -> None:
        """MySQL tests share one database, so one test at a time holds it, across every process running tests."""
        if self._lock_file is not None:
            return
        path = os.path.join(tempfile.gettempdir(), "runlight-python-mysql.lock")
        self._lock_file = open(path, "w")  # noqa: SIM115
        fcntl.flock(self._lock_file, fcntl.LOCK_EX)

    def cleanup(self) -> None:
        while self._cleanups:
            fn = self._cleanups.pop()
            try:
                fn()
            except Exception as error:  # pragma: no cover
                print(f"cleanup: {error}", file=sys.stderr)
        if self._lock_file is not None:
            fcntl.flock(self._lock_file, fcntl.LOCK_UN)
            self._lock_file.close()
            self._lock_file = None
