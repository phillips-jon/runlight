"""The little a store needs from a database, for SQLite, Postgres, and MySQL or MariaDB.

SQL uses `?` placeholders on every dialect and is written for SQLite and Postgres. Each driver does per
connection what the TypeScript drivers do (stores/sqlite.ts, stores/postgres.ts, and stores/mysql.ts). A
connection is opened on first use, so a request that reads nothing never connects.

SQLite keeps one connection, shared by every thread under a lock, as better-sqlite3 has one. Postgres and
MySQL open one connection per thread, as a pool hands each request its own, so a WSGI server's threads never
wait on each other's statements.
"""

from __future__ import annotations

import decimal
import os
import re
import sys
import threading
import time
import urllib.parse
from collections.abc import Callable, Sequence
from typing import Any, Protocol, TypeVar

from . import _js

T = TypeVar("T")

# Arbitrary but fixed, so every Runlight process takes the same lock to create tables.
MIGRATION_LOCK = 7_331_906

# One lock per MySQL database, so installs sharing a server do not wait on each other. Lock names are 64
# characters at most.
_MYSQL_LOCK = "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))"


class Db(Protocol):
    """Rows come back as dicts keyed by column name. Numbers may arrive as text from some drivers, so the store
    casts what it reads, as the TypeScript store does."""

    def dialect(self) -> str:
        """"sqlite", "postgres", or "mysql"."""
        ...

    def all(self, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]: ...

    def run(self, sql: str, params: Sequence[Any] = ()) -> None: ...

    def transaction(self, fn: Callable[[Db], T]) -> T:
        """Runs `fn` in one transaction, committed when it returns and rolled back when it raises. A transaction
        already open is joined, not nested."""
        ...

    def exclusive(self, fn: Callable[[Db], T]) -> T:
        """Runs `fn` while holding a database-wide lock, so two processes starting at once do not race to create
        the same tables."""
        ...

    def close(self) -> None: ...


def _value(value: Any) -> Any:
    """A value read from a driver as the store reads it: a decimal as a number."""
    if isinstance(value, decimal.Decimal):
        if value == value.to_integral_value():
            return int(value)
        return float(value)
    if isinstance(value, memoryview):
        return bytes(value)
    return value


def _pg_param(value: Any) -> Any:
    """A value sent to Postgres as pg sends it: as text of no stated type, which the server reads as the column
    or operator needs."""
    if value is None or isinstance(value, bytes):
        return value
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return _js.number_text(value)
    return _js.well_formed(str(value))


def _param(value: Any) -> Any:
    """A value bound into a statement: a whole float as an int, so every database reads back the same number."""
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, float):
        return _js.whole(value)
    if isinstance(value, str):
        return _js.well_formed(value)
    return value


class _Local(threading.local):
    conn: Any = None
    depth: int = 0
    held: int = 0


class _BaseDb:
    _dialect = ""

    def __init__(self) -> None:
        self._lock = threading.RLock()

    def dialect(self) -> str:
        return self._dialect

    def affected(self, sql: str, params: Sequence[Any] = ()) -> int:
        """Runs an UPDATE or DELETE and says how many rows it matched. The store asks this of MySQL, which has
        no RETURNING."""
        raise NotImplementedError


class SqliteDb(_BaseDb):
    """SQLite through the standard library's sqlite3, with the pragmas stores/sqlite.ts sets: WAL, NORMAL
    synchronous, and a five second busy timeout."""

    _dialect = "sqlite"

    def __init__(self, path: str | Callable[[], Any], owned: bool = True) -> None:
        super().__init__()
        self._path = path
        self._conn: Any = None
        self._owned = owned
        self._depth = 0

    def connection(self) -> Any:
        if self._conn is None:
            import sqlite3

            if callable(self._path):
                conn = self._path()
            else:
                path = self._path
                # A file in a folder that is not there yet gets the folder, as a fresh app's data/ often is.
                if path not in ("", ":memory:") and not path.startswith("file:"):
                    folder = os.path.dirname(path)
                    if folder and not os.path.isdir(folder):
                        os.makedirs(folder, exist_ok=True)
                conn = sqlite3.connect(
                    path, timeout=5, isolation_level=None, check_same_thread=False, uri=path.startswith("file:")
                )
                conn.execute("PRAGMA journal_mode = WAL")
                conn.execute("PRAGMA synchronous = NORMAL")
                conn.execute("PRAGMA busy_timeout = 5000")
            conn.isolation_level = None
            self._conn = conn
        return self._conn

    def all(self, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        with self._lock:
            cursor = self.connection().execute(sql, [_param(p) for p in params])
            if cursor.description is None:
                return []
            names = [d[0] for d in cursor.description]
            return [dict(zip(names, row, strict=False)) for row in cursor.fetchall()]

    def run(self, sql: str, params: Sequence[Any] = ()) -> None:
        with self._lock:
            self.connection().execute(sql, [_param(p) for p in params])

    def affected(self, sql: str, params: Sequence[Any] = ()) -> int:
        with self._lock:
            return int(self.connection().execute(sql, [_param(p) for p in params]).rowcount)

    def transaction(self, fn: Callable[[Any], T]) -> T:
        with self._lock:
            if self._depth > 0:
                return fn(self)
            conn = self.connection()
            conn.execute("BEGIN IMMEDIATE")
            self._depth += 1
            try:
                result = fn(self)
            except BaseException:
                self._depth = 0
                try:
                    conn.execute("ROLLBACK")
                except Exception:
                    pass
                raise
            self._depth -= 1
            conn.execute("COMMIT")
            return result

    def exclusive(self, fn: Callable[[Any], T]) -> T:
        # SQLite's file lock already serialises its writers.
        with self._lock:
            return fn(self)

    def close(self) -> None:
        with self._lock:
            if self._conn is not None and self._owned:
                try:
                    self._conn.close()
                except Exception:
                    pass
                self._conn = None


def number_placeholders(sql: str) -> str:
    """`?` placeholders to `$1, $2, ...`, leaving quoted text alone."""
    out = []
    n = 0
    quote = None
    for ch in sql:
        if quote:
            if ch == quote:
                quote = None
            out.append(ch)
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        elif ch == "?":
            n += 1
            out.append(f"${n}")
        else:
            out.append(ch)
    return "".join(out)


def mysql_text(sql: str, params: Sequence[Any] | None = None, escape: Callable[[Any], str] | None = None) -> str:
    """SQL written for SQLite and Postgres, as MySQL and MariaDB read it: a "quoted" identifier is quoted with
    backticks, and a backslash inside 'text' is doubled. With `params`, each `?` outside quotes becomes its value
    through `escape`, as mysql2 fills them in; without, the placeholders stay."""
    out = []
    n = 0
    quote = None
    esc = escape or mysql_escape
    for ch in sql:
        if quote is not None:
            if ch == quote:
                quote = None
                out.append("`" if ch == '"' else ch)
            elif quote == "'" and ch == "\\":
                out.append("\\\\")
            elif quote == '"' and ch == "`":
                out.append("``")
            else:
                out.append(ch)
        elif ch in ("'", '"', "`"):
            quote = ch
            out.append("`" if ch == '"' else ch)
        elif ch == "?" and params is not None:
            if n >= len(params):
                raise ValueError("Runlight: a statement has more placeholders than values")
            out.append(esc(params[n]))
            n += 1
        else:
            out.append(ch)
    if params is not None and n != len(params):
        raise ValueError("Runlight: a statement has more values than placeholders")
    return "".join(out)


_MYSQL_ESCAPES = {"\0": "\\0", "\x08": "\\b", "\t": "\\t", "\x1a": "\\Z", "\n": "\\n", "\r": "\\r", '"': '\\"', "'": "\\'", "\\": "\\\\"}
_MYSQL_ESCAPE = re.compile("[\0\x08\t\x1a\n\r\"'\\\\]")


def mysql_escape(value: Any) -> str:
    """A value as a MySQL literal, as mysql2's escape() writes the values Runlight binds."""
    if value is None:
        return "NULL"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _js.number_text(value)
    if isinstance(value, bytes):
        return "X'" + value.hex() + "'"
    text = _js.well_formed(str(value))
    return "'" + _MYSQL_ESCAPE.sub(lambda m: _MYSQL_ESCAPES[m.group(0)], text) + "'"


def _lost(error: BaseException) -> bool:
    """Whether an error says the connection is gone, rather than that the statement failed."""
    state = str(getattr(getattr(error, "diag", None), "sqlstate", "") or getattr(error, "sqlstate", "") or "")
    code = error.args[0] if error.args and isinstance(error.args[0], int) else 0
    return (
        state.startswith("08")
        or state in ("57P01", "57P02", "57P03")
        or code in (2006, 2013, 4031)
        or bool(
            re.search(
                r"server has gone away|lost connection|server closed the connection|no connection to the server|"
                r"terminating connection|connection is closed|the connection is lost",
                str(error),
                re.I,
            )
        )
    )


class _NetworkDb(_BaseDb):
    """A connection per thread, for Postgres and MySQL."""

    def __init__(self, connect: Callable[[], Any] | None, conn: Any = None) -> None:
        super().__init__()
        self._connect = connect
        self._given = conn
        self._local = _Local()
        self._all_conns: list[Any] = []

    def connection(self) -> Any:
        if self._given is not None:
            return self._given
        local = self._local
        if local.conn is None:
            if self._connect is None:
                raise RuntimeError("Runlight: the database connection is closed")
            local.conn = self._connect()
            with self._lock:
                self._all_conns.append(local.conn)
        return local.conn

    def _discard(self) -> None:
        """Drops a connection left in a state it could not undo; the next statement opens a new one."""
        if self._given is not None:
            return
        conn = self._local.conn
        self._local.conn = None
        if conn is not None:
            with self._lock:
                if conn in self._all_conns:
                    self._all_conns.remove(conn)
            try:
                conn.close()
            except Exception:
                pass

    def _execute(self, sql: str, params: Sequence[Any], fetch: bool) -> Any:
        try:
            return self._attempt(sql, params, fetch)
        except Exception as error:
            # A connection the server dropped (a restart, a failover, an idle timeout) is replaced, as a pool
            # replaces it, and the statement sent again: it never reached the server. Not inside a transaction
            # or a lock, whose work went with the connection.
            local = self._local
            if local.depth > 0 or local.held > 0 or self._given is not None or not _lost(error):
                raise
            name = "MySQL" if self._dialect == "mysql" else "Postgres"
            print(f"Runlight: a {name} connection was lost; it reconnects on the next query. {error}", file=sys.stderr)
            self._discard()
            return self._attempt(sql, params, fetch)

    def _attempt(self, sql: str, params: Sequence[Any], fetch: bool) -> Any:
        raise NotImplementedError

    def all(self, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        return self._execute(sql, params, True)

    def run(self, sql: str, params: Sequence[Any] = ()) -> None:
        self._execute(sql, params, False)

    def affected(self, sql: str, params: Sequence[Any] = ()) -> int:
        return int(self._execute(sql, params, None))  # type: ignore[arg-type]

    def _begin(self, conn: Any) -> None:
        raise NotImplementedError

    def transaction(self, fn: Callable[[Any], T]) -> T:
        local = self._local
        if local.depth > 0:
            return fn(self)
        conn = self.connection()
        self._begin(conn)
        local.depth += 1
        try:
            result = fn(self)
        except BaseException:
            local.depth = 0
            try:
                self._raw(conn, "ROLLBACK")
            except Exception:
                # A connection still in its transaction must never be used again.
                self._discard()
            raise
        local.depth -= 1
        try:
            self._raw(conn, "COMMIT")
        except BaseException:
            try:
                self._raw(conn, "ROLLBACK")
            except Exception:
                self._discard()
            raise
        return result

    def _raw(self, conn: Any, sql: str) -> Any:
        raise NotImplementedError

    def exclusive(self, fn: Callable[[Any], T]) -> T:
        self._local.held += 1
        try:
            return self._locked(fn)
        finally:
            self._local.held -= 1

    def _locked(self, fn: Callable[[Any], T]) -> T:
        raise NotImplementedError

    def close(self) -> None:
        if self._given is not None:
            return
        with self._lock:
            conns, self._all_conns = self._all_conns, []
        for conn in conns:
            try:
                conn.close()
            except Exception:
                pass
        self._local = _Local()


class PostgresDb(_NetworkDb):
    """Postgres through psycopg 3, with `$n` placeholders as pg numbers them (stores/postgres.ts)."""

    _dialect = "postgres"

    def __init__(self, connect: Callable[[], Any] | None = None, conn: Any = None) -> None:
        super().__init__(connect, conn)
        self._texts: dict[str, str] = {}

    def _text(self, sql: str) -> str:
        text = self._texts.get(sql)
        if text is None:
            text = number_placeholders(sql)
            if len(self._texts) < 500:
                self._texts[sql] = text
        return text

    def _attempt(self, sql: str, params: Sequence[Any], fetch: bool | None) -> Any:
        conn = self.connection()
        with conn.cursor() as cursor:
            cursor.execute(self._text(sql), [_pg_param(p) for p in params])
            if fetch is None:
                return cursor.rowcount
            if not fetch or cursor.description is None:
                return None
            names = [d.name for d in cursor.description]
            return [{n: _value(v) for n, v in zip(names, row, strict=False)} for row in cursor.fetchall()]

    def _raw(self, conn: Any, sql: str) -> Any:
        with conn.cursor() as cursor:
            cursor.execute(sql)

    def _begin(self, conn: Any) -> None:
        self._raw(conn, "BEGIN")

    def _locked(self, fn: Callable[[Any], T]) -> T:
        # Asked for again and again rather than waited on: a waiting statement would hold up an index being
        # built CONCURRENTLY by whoever has the lock, and the two would wait on each other for good.
        while not (self.all("SELECT pg_try_advisory_lock(?) AS ok", [MIGRATION_LOCK])[0].get("ok")):
            time.sleep(0.1)
        try:
            return fn(self)
        finally:
            try:
                self.run("SELECT pg_advisory_unlock(?)", [MIGRATION_LOCK])
            except Exception:
                # A lost connection ends its session, and the lock with it.
                pass


class MysqlDb(_NetworkDb):
    """MySQL 8.4 or MariaDB 11.4 and later through PyMySQL. Each statement goes through mysql_text() first, with
    its values written in on the client, as mysql2 fills them in."""

    _dialect = "mysql"

    def __init__(self, connect: Callable[[], Any] | None = None, conn: Any = None, statement_timeout: int = 0) -> None:
        super().__init__(connect, conn)
        self._statement_timeout = statement_timeout
        self._mariadb: bool | None = None
        # An app's own connection too.
        if conn is not None:
            backslash_escapes_on(conn)

    def _attempt(self, sql: str, params: Sequence[Any], fetch: bool | None) -> Any:
        conn = self.connection()
        text = mysql_text(sql, [_param(p) for p in params])
        with conn.cursor() as cursor:
            count = cursor.execute(text)
            if fetch is None:
                return count
            if not fetch or cursor.description is None:
                return None
            names = [d[0] for d in cursor.description]
            return [{n: _value(v) for n, v in zip(names, row, strict=False)} for row in cursor.fetchall()]

    def _raw(self, conn: Any, sql: str) -> Any:
        with conn.cursor() as cursor:
            cursor.execute(sql)
            return cursor.fetchall()

    def _begin(self, conn: Any) -> None:
        # As Postgres does by default: each statement sees what was committed before it began, and InnoDB takes
        # no gap locks, so two writers to neighbouring rows do not deadlock.
        self._raw(conn, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
        self._raw(conn, "START TRANSACTION")

    def limit_statements(self, conn: Any, ms: int) -> None:
        """MySQL's statement timeout as a session setting, which MySQL and MariaDB name differently. MariaDB
        counts seconds and applies it to every statement; MySQL counts milliseconds and applies it to reads."""
        if self._mariadb is None:
            self._mariadb = is_mariadb(conn)
        _set_timeout(conn, ms, self._mariadb)

    def _locked(self, fn: Callable[[Any], T]) -> T:
        conn = self.connection()
        while True:
            rows = self._raw(conn, f"SELECT GET_LOCK({_MYSQL_LOCK}, 5) AS ok")
            ok = rows[0][0] if rows else None
            if ok is None:
                raise RuntimeError("Runlight: MySQL refused the lock for creating tables")
            if int(ok) == 1:
                break
            # Not got within 5 seconds: another process is creating the tables. Ask again.
        try:
            # An index on a big table takes a while to build, so the build may run past the statement timeout.
            if self._statement_timeout > 0:
                self.limit_statements(conn, 0)
            result = fn(self)
            if self._statement_timeout > 0:
                self.limit_statements(conn, self._statement_timeout)
            return result
        except BaseException:
            # The session may be left without its statement timeout, so the connection goes.
            try:
                self._raw(conn, f"DO RELEASE_LOCK({_MYSQL_LOCK})")
            except Exception:
                pass
            self._discard()
            raise
        finally:
            if self._local.conn is conn or self._given is conn:
                try:
                    # A lost connection ends its session, and the lock with it.
                    self._raw(conn, f"DO RELEASE_LOCK({_MYSQL_LOCK})")
                except Exception:
                    pass


# The session's sql_mode as it was, less NO_BACKSLASH_ESCAPES, wherever it sits in the list.
_NO_BACKSLASH_ESCAPES_OFF = (
    "SET SESSION sql_mode = TRIM(BOTH ',' FROM REPLACE(CONCAT(',', @@SESSION.sql_mode, ','), ',NO_BACKSLASH_ESCAPES,', ','))"
)


def backslash_escapes_on(conn: Any) -> None:
    """Values are written in with backslash escapes, which a server set to NO_BACKSLASH_ESCAPES reads as text, so a
    quote could end the value early. Every connection drops that one mode."""
    with conn.cursor() as cursor:
        cursor.execute(_NO_BACKSLASH_ESCAPES_OFF)


def is_mariadb(conn: Any) -> bool:
    with conn.cursor() as cursor:
        cursor.execute("SELECT VERSION() AS v")
        return "mariadb" in str(cursor.fetchone()[0]).lower()


def _set_timeout(conn: Any, ms: int, mariadb: bool) -> None:
    with conn.cursor() as cursor:
        if mariadb:
            cursor.execute(f"SET SESSION max_statement_time = {_js.number_text(ms / 1000)}")
        else:
            cursor.execute(f"SET SESSION max_execution_time = {int(ms)}")


# Opening connections


def _parts(url: str) -> dict[str, Any]:
    parsed = urllib.parse.urlsplit(url)
    if not parsed.hostname:
        raise ValueError("Runlight: the database URL could not be read")
    return {
        "host": parsed.hostname,
        "port": parsed.port or 0,
        "user": urllib.parse.unquote(parsed.username) if parsed.username is not None else None,
        "password": urllib.parse.unquote(parsed.password) if parsed.password is not None else None,
        "database": urllib.parse.unquote(parsed.path.lstrip("/")),
        "query": dict(urllib.parse.parse_qsl(parsed.query)),
    }


def _option(value: str) -> str:
    """A value inside libpq's `options`, where a space or backslash is escaped with a backslash."""
    return re.sub(r"([\\\s'])", r"\\\1", value)


def sqlite(path: str) -> SqliteDb:
    """A SQLite file, or ":memory:", with the pragmas stores/sqlite.ts sets."""
    return SqliteDb(path)


def postgres(url: str, statement_timeout: int = 120_000, schema: str | None = None) -> PostgresDb:
    """Postgres from a URL like postgres://user:pass@host:5432/db?sslmode=require. `statement_timeout` stops any
    one statement after that many milliseconds; 0 turns it off. `schema`, when given, is the search path."""
    try:
        import psycopg
    except ImportError:  # pragma: no cover
        raise ImportError('Runlight: the Postgres store needs psycopg 3. Install it with pip install "runlight[postgres]"') from None

    parts = _parts(url)

    def connect() -> Any:
        options = [parts["query"]["options"]] if "options" in parts["query"] else []
        if statement_timeout > 0:
            options.append(f"-c statement_timeout={statement_timeout}")
        if schema is not None:
            options.append(f"-c search_path={_option(schema)}")
        kwargs: dict[str, Any] = {
            "host": parts["host"],
            "port": parts["port"] or 5432,
            "dbname": parts["database"],
            "autocommit": True,
            "cursor_factory": psycopg.RawCursor,
            # A connection waits at most 10 seconds for the server, as the pool waits for a connection.
            "connect_timeout": 10,
        }
        if parts["user"] is not None:
            kwargs["user"] = parts["user"]
        if parts["password"] is not None:
            kwargs["password"] = parts["password"]
        if "sslmode" in parts["query"]:
            kwargs["sslmode"] = parts["query"]["sslmode"]
        if options:
            kwargs["options"] = " ".join(options)
        return psycopg.connect(**kwargs)

    return PostgresDb(connect)


def mysql(url: str, statement_timeout: int = 120_000) -> MysqlDb:
    """MySQL 8.4 or MariaDB 11.4 and later from a URL like mysql://user:pass@host:3306/db (or mariadb://). The
    session is utf8mb4, with IGNORE_SPACE added to the server's SQL mode as mysql2 asks for it. Runlight's tables
    carry their own binary collation, so text compares and sorts by code point."""
    try:
        import pymysql
    except ImportError:  # pragma: no cover
        raise ImportError('Runlight: the MySQL store needs PyMySQL. Install it with pip install "runlight[mysql]"') from None

    parts = _parts(re.sub(r"^mariadb:", "mysql:", url, flags=re.I))

    def connect() -> Any:
        conn = pymysql.connect(
            host=parts["host"],
            port=parts["port"] or 3306,
            user=parts["user"] or "",
            password=parts["password"] or "",
            database=parts["database"] or None,
            charset="utf8mb4",
            autocommit=True,
            connect_timeout=10,
            client_flag=pymysql.constants.CLIENT.IGNORE_SPACE,
        )
        try:
            backslash_escapes_on(conn)
        except BaseException:
            conn.close()
            raise
        if statement_timeout > 0:
            _set_timeout(conn, statement_timeout, is_mariadb(conn))
        return conn

    return MysqlDb(connect, statement_timeout=statement_timeout)


def from_url(url: str) -> SqliteDb | PostgresDb | MysqlDb:
    """Picks the database from a URL's scheme: sqlite:, file:, postgres:, postgresql:, mysql:, or mariadb:."""
    scheme = url.split(":", 1)[0].lower() if ":" in url else ""
    if scheme in ("postgres", "postgresql"):
        return postgres(url)
    if scheme in ("mysql", "mariadb"):
        return mysql(url)
    if scheme in ("sqlite", "file"):
        return sqlite(re.sub(r"^(sqlite|file):(//)?", "", url, flags=re.I))
    raise ValueError("Runlight: DATABASE_URL must start with postgres://, mysql://, mariadb://, or sqlite:")


def quote_name(name: str, quote: str) -> str:
    return quote + name.replace(quote, quote + quote) + quote
