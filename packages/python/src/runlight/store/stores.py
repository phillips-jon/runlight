"""The stores stores/sqlite.ts, stores/postgres.ts, and stores/mysql.ts make. Tables are prefixed `rl_`, so the
database can be the app's own, and a database made by the TypeScript SDK opens here."""

from __future__ import annotations

from typing import Any

from .. import db as dbs
from .sql_store import SqlStore


class _RawConnection:
    """A psycopg connection the app already has, as the store reads it: each cursor a RawCursor, so statements take
    `$1, $2, ...` placeholders whatever the connection's own cursor factory is. Everything else is the app's."""

    def __init__(self, conn: Any) -> None:
        self._conn = conn

    def cursor(self) -> Any:
        import psycopg

        return psycopg.RawCursor(self._conn)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._conn, name)


class Stores:
    @staticmethod
    def sqlite(path: str) -> SqlStore:
        """Runlight's tables in a SQLite file (or ":memory:"), in WAL mode, as better-sqlite3 opens it there."""
        return SqlStore(dbs.sqlite(path))

    @staticmethod
    def postgres(url: Any, statement_timeout: int = 120_000, schema: str | None = None) -> SqlStore:
        """Runlight's tables in Postgres, from a connection string, or a psycopg connection the app already has, in
        autocommit mode (Runlight never closes a connection it did not open). `statement_timeout` is the longest one
        statement may run on a connection Runlight opens, in milliseconds (0 for no limit), and `schema` the search
        path for one it opens."""
        if not isinstance(url, str):
            return SqlStore(dbs.PostgresDb(conn=_RawConnection(url)))
        if url == "":
            raise ValueError("Runlight: postgres() needs a url or a pool")
        return SqlStore(dbs.postgres(url, statement_timeout, schema))

    @staticmethod
    def mysql(url: Any, statement_timeout: int = 120_000) -> SqlStore:
        """Runlight's tables in MySQL 8.4 or MariaDB 11.4 and later, from a mysql:// or mariadb:// URL, or a PyMySQL
        connection the app already has, in autocommit mode. Text is utf8mb4 with a binary collation, so it compares
        and sorts by code point, case and trailing spaces included, as SQLite and Postgres do. `statement_timeout`,
        in milliseconds (0 for no limit), is applied by MySQL to reads only and by MariaDB to every statement."""
        if not isinstance(url, str):
            return SqlStore(dbs.MysqlDb(conn=url))
        if url == "":
            raise ValueError("Runlight: mysql() needs a url or a pool")
        return SqlStore(dbs.mysql(url, statement_timeout))

    @staticmethod
    def url(database_url: str) -> SqlStore:
        """The store a DATABASE_URL names, as the standalone server picks one: postgres:// or postgresql:// for
        Postgres, mysql:// or mariadb:// for MySQL, and sqlite: or file: followed by a path for SQLite."""
        return SqlStore(dbs.from_url(database_url))

    @staticmethod
    def from_db(db: Any) -> SqlStore:
        """A store over any Db."""
        return SqlStore(db)

    @staticmethod
    def mysql_text(sql: str, params: list[Any] | None = None, escape: Any = None) -> str:
        """SQL written for SQLite and Postgres as MySQL and MariaDB read it, with each `?` filled in by `escape`
        (mysql2's escaping by default)."""
        return dbs.mysql_text(sql, params if params is not None else [], escape)
