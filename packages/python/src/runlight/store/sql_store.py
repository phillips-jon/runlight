"""Runlight's tables, read and written with the same SQL as store.ts's SqlStore for each dialect, so a database made
by either implementation opens in the other. Rows are the TypeScript interfaces as dicts with the same camelCase
keys, in the same order:

- SiteRow: {id, name, hostnames: list[str], timezone}
- GoalRow: {id, site, name, kind: "event" | "page" | "click", match, clickBy: "selector" | "link" | "", valueMode:
  "none" | "fixed" | "prop", value, valueProp, currency, createdAt}
- ReportRow: {id, site, email, frequency: "weekly" | "monthly", lang, token, origin, lastPeriod, lastSentAt, createdAt}
- ShareRow: {id, site, name, createdAt}
- FunnelRow: {id, site, name, steps: [{kind: "page" | "event", match}], createdAt}
- TokenRow: {id, name, site, scope: "read" | "manage", hash, hint, createdAt, lastUsedAt}
- LinkRow: {id, site, domain, slug, name, url, createdAt, updatedAt}
- SessionRow: {id, site, visitor, startedAt, hostname, referrerHost, referrerPath, source, channel, utmSource,
  utmMedium, utmCampaign, utmTerm, utmContent, country, region, city, browser, browserVersion, os, osVersion,
  device, screen, language}
- EventRow: {site, ts, kind: "pageview" | "event" | "engagement" | "click" | "fetch", visitor, session, pageview,
  path, hostname, title, name, props: dict | None, engagedMs, scroll, link}
- Query: {site, from, to, filters: [{dimension, op, value}]}
- Bucket: {start, end}

TS's Map and Set answers are a dict and a set.
"""

from __future__ import annotations

import functools
import re
from collections.abc import Callable
from typing import Any, TypeVar

from .. import _js
from ..query import EVENT_DIMENSIONS, SESSION_DIMENSIONS, is_session_dimension
from .sql import (
    BOUNCE,
    BOUNCE_MS,
    BUCKETS_PER_QUERY,
    BUILT_DAYS,
    DURATION,
    EVENT_TAIL_MS,
    IS_VISIT,
    JOURNEY_VISITS,
    LIVE_VIEWS,
    MAX_PARAMS,
    MYSQL_COLLATION,
    PIECE_MS,
    SCHEMA_VERSION,
    VALUES_PER_QUERY,
    as_text,
    bucket_table,
    code_order,
    div,
    escape_like,
    glob_pattern,
    goal_row,
    in_pieces,
    like_pattern,
    link_row,
    num,
    pageviews_of,
    row_scope,
    schema,
    upsert,
    visit_rows,
    visit_scope,
)

T = TypeVar("T")

__all__ = ["BOUNCE_MS", "EVENT_TAIL_MS", "JOURNEY_VISITS", "MYSQL_COLLATION", "SCHEMA_VERSION", "SqlStore"]

_INDEX = re.compile(r"^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\w+) ON (\w+)")
_ROLLUP_SUMS = ("visitors", "visits", "pageviews", "bounced", "duration", "engaged", "views", "scroll_sum", "scroll_n", "events")


def _string(value: Any) -> str:
    return _js.string(value)


def _or(value: Any, fallback: Any) -> Any:
    """value ?? fallback."""
    return fallback if value is None else value


def _round2(value: int | float) -> int | float:
    """Math.round(x * 100) / 100."""
    return _js.whole(_js.js_round(value * 100) / 100)


def _time(row: dict[str, Any] | None, key: str = "t") -> int | float | None:
    """A MIN or MAX of a time, or None when there were no rows."""
    if row is None or row.get(key) is None:
        return None
    return num(row[key])


class SqlStore:
    def __init__(self, db: Any) -> None:
        self.db = db
        self._ready = False
        # Whether a full migrate went over every table and index in this process.
        self._checked_all = False

    def migrate(self, full: bool = False) -> None:
        """Creates the tables on first use. Safe to call any number of times. A database already at the current
        schema version is taken on trust; `full` (the scheduled check, the migrate command) goes over every table
        and index once a process."""
        if self._checked_all or (self._ready and not full):
            return
        if not full and not self._ready:
            try:
                rows = self.db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'")
                if rows and str(rows[0]["value"]) == str(SCHEMA_VERSION):
                    self._ready = True
                    return
            except Exception:
                # No rl_meta yet: a new database, made below.
                pass

        def create(db: Any) -> None:
            # On Postgres an index on a big table takes a while to build, so the build may run past the statement
            # timeout, and goes CONCURRENTLY, so another process still serving keeps writing meanwhile.
            postgres = db.dialect() == "postgres"
            if postgres:
                db.run("SET statement_timeout = 0")
            try:
                self._upgrade(db, postgres)
            finally:
                if postgres:
                    try:
                        db.run("RESET statement_timeout")
                    except Exception:
                        pass

        self.db.exclusive(create)
        self._ready = True
        self._checked_all = True

    @staticmethod
    def _upgrade(db: Any, postgres: bool) -> None:
        dialect = db.dialect()
        statements = schema(dialect)
        db.run(statements[0])
        rows = db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'")
        found = rows[0] if rows else None
        from_ = _js.number(found["value"]) if found else SCHEMA_VERSION
        if postgres:
            # A concurrent build that was stopped leaves its index unusable; it goes, and is built again below.
            broken = db.all(
                """SELECT c.relname AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
           WHERE NOT i.indisvalid AND c.relname LIKE 'rl\\_%' AND c.relnamespace = current_schema()::regnamespace"""
            )
            for row in broken:
                db.run(f'DROP INDEX IF EXISTS "{_string(row["name"]).replace(chr(34), "")}"')
        for statement in statements:
            index = _INDEX.match(statement)
            if index and dialect == "mysql":
                # MySQL has no CREATE INDEX IF NOT EXISTS, so it is looked for first.
                unique, name, table = index.group(1), index.group(2), index.group(3)
                there = db.all(
                    "SELECT 1 AS there FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1",
                    [table, name],
                )
                if not there:
                    db.run(_INDEX_HEAD.sub(f"CREATE {unique or ''}INDEX", statement, count=1))
            else:
                db.run(_INDEX_HEAD.sub(lambda m: f"CREATE {m.group(1) or ''}INDEX CONCURRENTLY IF NOT EXISTS", statement, count=1) if postgres else statement)

        # A column added by an upgrade that stopped before it recorded the new version is already there.
        def add_column(sql: str) -> None:
            try:
                db.run(sql)
            except Exception as error:
                if not re.search(r"duplicate column|already exists", str(error), re.I):
                    raise

        # Version 2: settings changed in the dashboard, kept apart from the ones in code.
        if from_ < 2:
            add_column("ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'")
        if from_ < 4:
            db.run("DROP INDEX IF EXISTS rl_links_slug")
        # Version 10: tokens that may change one site's settings, for a hub.
        if 8 <= from_ < 10:
            add_column("ALTER TABLE rl_tokens ADD COLUMN scope TEXT NOT NULL DEFAULT 'read'")
        # Written only when it changes, so a database opened read-only can still be read.
        if not found or _string(found["value"]) != str(SCHEMA_VERSION):
            db.run(upsert(dialect, "rl_meta", ['"key"', "value"], ['"key"'], ["value"]), ["schema", str(SCHEMA_VERSION)])

    def optimize(self, only_when_missing: bool = False) -> None:
        """Keeps SQLite's planner statistics current, which it never gathers by itself. Without them it can choose a
        plan that reads a table once for every row of another. A sample of each index is enough, so this takes
        milliseconds even on a large database. Postgres gathers its own."""
        if self.db.dialect() != "sqlite":
            return
        try:
            if only_when_missing and self.db.all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'"):
                return
            self.db.run("PRAGMA analysis_limit = 1000")
            self.db.run("ANALYZE")
        except Exception:
            # Some hosted SQLite services refuse these, and gather statistics themselves.
            pass

    def close(self) -> None:
        self.db.close()

    def _metered(self) -> bool:
        """True for a database reached one statement at a time with a cap on statements per request (Cloudflare
        D1), so long jobs send fewer, larger pieces."""
        return bool(getattr(self.db, "metered", False))

    def _changed(self, sql: str, params: list[Any]) -> int:
        """How many rows an UPDATE or DELETE of rows with an id matched. MySQL has no RETURNING, so its driver
        counts them."""
        if self.db.dialect() == "mysql":
            return self.db.affected(sql, params)
        return len(self.db.all(f"{sql} RETURNING id", params))

    def transaction(self, fn: Callable[[SqlStore], T]) -> T:
        """Runs `fn` with a store whose every query is in one transaction."""
        return self.db.transaction(lambda db: fn(SqlStore(db)))

    # Sites

    def upsert_site(self, site: dict[str, Any], now: int) -> None:
        # Unchanged sites are left alone, so starting needs no write and a read-only database still opens.
        hostnames = _js.dumps(list(site["hostnames"]))
        rows = self.db.all("SELECT name, hostnames, timezone FROM rl_sites WHERE id = ?", [site["id"]])
        row = rows[0] if rows else None
        if row and row["name"] == site["name"] and row["hostnames"] == hostnames and row["timezone"] == site["timezone"]:
            return
        self.db.run(
            upsert(self.db.dialect(), "rl_sites", ["id", "name", "hostnames", "timezone", "created_at"], ["id"], ["name", "hostnames", "timezone"]),
            [site["id"], site["name"], hostnames, site["timezone"], now],
        )

    def site_overrides(self) -> dict[str, dict[str, Any]]:
        """Settings changed in the dashboard, by site. They win over the ones in code."""
        out: dict[str, dict[str, Any]] = {}
        for row in self.db.all("SELECT id, overrides FROM rl_sites"):
            try:
                value = _js.loads(row["overrides"])
            except (ValueError, TypeError):
                value = {}
            out[row["id"]] = value
        return out

    def delete_site(self, id: str) -> None:
        """Deletes a site and everything recorded for it. Used by the standalone server's "Delete site". Its events
        and visits go a day at a time first, so a big site does not hold the database (on SQLite, the whole server)
        for minutes, and what is left goes in one transaction."""
        piece = 30 * PIECE_MS if self._metered() else PIECE_MS
        for table, col in (("rl_events", "ts"), ("rl_sessions", "started_at")):
            # A piece at a time from the oldest row, skipping straight over stretches with none.
            from_ = self._oldest(table, col, id, None)
            while from_ is not None:
                self.db.run(f"DELETE FROM {table} WHERE site = ? AND {col} < ?", [id, from_ + piece])
                from_ = self._oldest(table, col, id, from_ + piece)

        def rest(store: SqlStore) -> None:
            for table in ("rl_events", "rl_sessions", "rl_links", "rl_link_domains", "rl_shares", "rl_goals", "rl_funnels", "rl_reports", "rl_tokens", "rl_rollups", "rl_rollup_days", "rl_sites"):
                store.db.run(f"DELETE FROM {table} WHERE {'id' if table == 'rl_sites' else 'site'} = ?", [id])

        self.transaction(rest)

    def _oldest(self, table: str, col: str, site: str, from_: int | float | None) -> int | float | None:
        """When a site's oldest row at or after `from_` is (None for no lower bound), or None when there is none."""
        rows = self.db.all(
            f"SELECT MIN({col}) AS t FROM {table} WHERE site = ?{'' if from_ is None else f' AND {col} >= ?'}",
            [site] if from_ is None else [site, from_],
        )
        return _time(rows[0] if rows else None)

    def drop_before(self, site: str, ts: int) -> None:
        """Deletes a site's visits and events from before a time, for its retention setting."""
        # A day at a time from the oldest, each its own short transaction, so a long history goes without holding
        # the database (on SQLite, the whole server) for minutes. Stretches with nothing in them are skipped, so
        # one stray old row does not cost a piece for every day since.
        piece = 30 * PIECE_MS if self._metered() else PIECE_MS

        def next_(at: int | float | None) -> int | float | None:
            found = [t for t in (self._oldest("rl_sessions", "started_at", site, at), self._oldest("rl_events", "ts", site, at)) if t is not None]
            if not found:
                return None
            return min(found) if at is None else max(at, min(found))

        from_ = next_(None)
        while from_ is not None and from_ < ts:
            to = min(from_ + piece, ts)

            def drop(store: SqlStore, from_: int | float = from_, to: int | float = to) -> None:
                # A visit's events go with it, even ones after the cutoff, so nothing is left without its visit.
                # They come after it starts and within EVENT_TAIL_MS, so the time bounds let the (site, ts) index
                # find them.
                store.db.run(
                    "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND started_at >= ? AND started_at < ?)",
                    [site, from_, to + EVENT_TAIL_MS, site, from_, to],
                )
                store.db.run("DELETE FROM rl_events WHERE site = ? AND ts < ?", [site, to])
                store.db.run("DELETE FROM rl_sessions WHERE site = ? AND started_at < ?", [site, to])

            self.transaction(drop)
            from_ = next_(min(from_ + piece, ts))
        # A day that lost any of its visits is built again later, from what is left.
        self.clear_rollups(site, {"before": ts})

    def drop_orphans(self, site: str, from_: int, until: int) -> None:
        """Deletes a site's events from `from_` on whose visit no longer exists, a day at a time."""
        piece = 30 * PIECE_MS if self._metered() else PIECE_MS
        at = self._oldest("rl_events", "ts", site, from_)
        while at is not None and at < until:
            self.db.run(
                "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session <> '' AND NOT EXISTS (SELECT 1 FROM rl_sessions s WHERE s.id = rl_events.session)",
                [site, at, at + piece],
            )
            at = self._oldest("rl_events", "ts", site, at + piece)

    # Daily rollups

    def build_rollup_day(self, site: str, day: str, start: int, end: int) -> None:
        """Adds up one local day of a site: totals, each visit dimension, and pages. A visit belongs to the day it
        started. Visitor ids change every day, so the days of a range add up to exactly what counting the range
        would give."""
        # A day with no visits still gets its row of zeros, so it counts as built.
        sums = f"COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END), 0), COALESCE(SUM({DURATION}), 0)"
        cols = "(site, day, dim, value, visitors, visits, pageviews, bounced, duration)"
        # Each piece names its own site and day, as text, so Postgres knows their type inside a UNION.
        dialect = self.db.dialect()
        head = f"{as_text(dialect, '?')}, {as_text(dialect, '?')}"
        quarter = div(dialect, "s.started_at", 900000)
        # The day's totals, each visit dimension, and the heatmap's quarter hours (counted as hourly() counts them:
        # every visit that started), in one statement over the day's visits, since a Cloudflare D1 check may only
        # send so many.
        pieces = [
            f"SELECT {head}, '', '', {sums} FROM v s",
            *(f"SELECT {head}, '{dim}', s.{col}, {sums} FROM v s WHERE s.{col} <> '' GROUP BY s.{col}" for dim, col in SESSION_DIMENSIONS.items()),
            f"SELECT {head}, 'quarter', {as_text(dialect, quarter)}, COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END), 0), 0 FROM v s GROUP BY {as_text(dialect, quarter)}",
        ]

        # Pages and events, from the rows of the day's visits. The time bounds let the (site, kind, ts) index find
        # them; a visit's last row comes at most EVENT_TAIL_MS after it starts.
        def of_day(kind: str) -> str:
            return f"""FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.kind = '{kind}' AND e.ts >= ? AND e.ts < ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}"""

        window = [site, start, end + EVENT_TAIL_MS, start, end]

        def build(store: SqlStore) -> None:
            db = store.db
            db.run("DELETE FROM rl_rollups WHERE site = ? AND day = ?", [site, day])
            # The WITH goes after INSERT INTO, the one place every database takes it.
            params: list[Any] = [site, start, end]
            for _ in pieces:
                params.extend([site, day])
            db.run(
                f"""INSERT INTO rl_rollups {cols}
         WITH v AS (SELECT * FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT})
         {" UNION ALL ".join(pieces)}""",
                params,
            )
            # A page's engaged time and scroll come per pageview first (its time added up, its deepest scroll), as
            # the raw report counts them.
            db.run(
                f"""INSERT INTO rl_rollups (site, day, dim, value, visitors, visits, pageviews, views, engaged, scroll_sum, scroll_n)
         SELECT ?, ?, 'page', p.value, p.visitors, p.visits, p.pageviews, p.views, COALESCE(t.engaged, 0), COALESCE(t.scroll_sum, 0), COALESCE(t.scroll_n, 0)
         FROM (SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, {LIVE_VIEWS} AS views
               {of_day("pageview")} GROUP BY e.path) p
         LEFT JOIN (SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest {of_day("engagement")} GROUP BY e.path, e.pageview) x
               GROUP BY value) t ON t.value = p.value""",
                [site, day, *window, *window],
            )
            db.run(
                f"""INSERT INTO rl_rollups (site, day, dim, value, visitors, events)
         SELECT ?, ?, 'event', e.name, COUNT(DISTINCT e.visitor), COUNT(*) {of_day("event")} GROUP BY e.name""",
                [site, day, *window],
            )
            db.run("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", [site, day])
            db.run("INSERT INTO rl_rollup_days (site, day, start_at, end_at) VALUES (?, ?, ?, ?)", [site, day, start, end])

        self.transaction(build)

    def rollup_days(self, site: str) -> set[str]:
        """The days of a site already built."""
        return {_string(r["day"]) for r in self.db.all("SELECT day FROM rl_rollup_days WHERE site = ?", [site])}

    def clear_rollups(self, site: str, range: dict[str, Any] | None = None) -> None:
        """Forgets built days, all of a site's or those touching a stretch of time, so they are built again. `range`
        is {"before"} or {"from", "to"}."""
        range = range or {}
        where = "site = ?"
        params: list[Any] = [site]
        if range.get("before") is not None:
            where += " AND start_at < ?"
            params.append(range["before"])
        elif range.get("from") is not None and range.get("to") is not None:
            where += " AND start_at < ? AND end_at > ?"
            params.extend([range["to"], range["from"]])
        days = [_string(r["day"]) for r in self.db.all(f"SELECT day FROM rl_rollup_days WHERE {where}", params)]
        # The days stop counting as built first, so if this stops part way, no day is left marked built without its
        # rows. Rows of a day not built are never read, and building it replaces them. Another process may build a
        # day between the two deletes, so its mark goes again after its rows: the day is then simply built once
        # more.
        self.db.run(f"DELETE FROM rl_rollup_days WHERE {where}", params)
        for day in days:
            self.db.run("DELETE FROM rl_rollups WHERE site = ? AND day = ?", [site, day])
            self.db.run("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", [site, day])

    def _rollup_plan(self, query: dict[str, Any], from_: int, to: int) -> dict[str, Any] | None:
        """How to answer a range from rollups: the built days that lie wholly inside it, and the stretches left over,
        which are read from the visits as usual. None when no built day helps."""
        if query["filters"]:
            return None
        rows = self.db.all(
            "SELECT day, start_at, end_at FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ? ORDER BY start_at",
            [query["site"], from_, to],
        )
        if not rows:
            return None
        days = [{"day": _string(r["day"]), "start": num(r["start_at"]), "end": num(r["end_at"])} for r in rows]
        rest: list[tuple[int | float, int | float]] = []
        at = from_
        for d in days:
            if d["start"] > at:
                rest.append((at, d["start"]))
            at = max(at, d["end"])
        if at < to:
            rest.append((at, to))
        return {"days": days, "rest": rest}

    @staticmethod
    def _within(rest: list[tuple[int | float, int | float]]) -> dict[str, Any]:
        """SQL for "a visit that started in one of these stretches"."""
        if not rest:
            return {"sql": "1 = 0", "params": []}
        return {
            "sql": f"({' OR '.join('(s.started_at >= ? AND s.started_at < ?)' for _ in rest)})",
            "params": [x for pair in rest for x in pair],
        }

    def _rolled_breakdown(self, query: dict[str, Any], dimension: str, limit: int, offset: int) -> list[dict[str, Any]] | None:
        """A breakdown of a visit dimension or of pages from rollups and the visits left over, merged, then sorted and
        cut to the page asked for."""
        page = dimension == "page"
        event = dimension == "event"
        if not page and not event and not is_session_dimension(dimension):
            return None
        if query["filters"]:
            return None
        # Pages and events always go this way without filters, so a range gives the same answer whether its days
        # are built or not.
        plan = self._rollup_plan(query, query["from"], query["to"])
        if plan is None and (page or event):
            plan = {"days": [], "rest": [(query["from"], query["to"])]}
        if plan is None:
            return None
        sums: dict[str, dict[str, int | float]] = {}

        def bump(row: dict[str, Any]) -> None:
            key = _string(row["value"])
            into = sums.get(key)
            if into is None:
                into = {k: 0 for k in _ROLLUP_SUMS}
                sums[key] = into
            for k in _ROLLUP_SUMS:
                into[k] += num(row.get(k))

        if plan["days"]:
            rolled = self.db.all(
                f"""SELECT value, SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration,
           SUM(engaged) AS engaged, SUM(views) AS views, SUM(scroll_sum) AS scroll_sum, SUM(scroll_n) AS scroll_n, SUM(events) AS events
         FROM rl_rollups WHERE site = ? AND dim = ? AND day IN ({BUILT_DAYS}) GROUP BY value""",
                [query["site"], dimension, query["site"], query["from"], query["to"]],
            )
            for row in rolled:
                bump(row)
        w = SqlStore._within(plan["rest"])
        if (page or event) and plan["rest"]:
            # A visit's pageviews and events belong to the day it started, as in the rollups. Bounded by time as
            # well, so the events index finds them (see build_rollup_day).
            lo = min(a for a, _ in plan["rest"])
            hi = max(b for _, b in plan["rest"]) + EVENT_TAIL_MS

            def of_rest(kind: str) -> str:
                return f"FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.kind = '{kind}' AND e.ts >= ? AND e.ts < ? AND {IS_VISIT} AND {w['sql']}"

            at = [query["site"], lo, hi, *w["params"]]
            if page:
                for row in self.db.all(
                    f"SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, {LIVE_VIEWS} AS views {of_rest('pageview')} GROUP BY e.path",
                    at,
                ):
                    bump(row)
                for row in self.db.all(
                    f"""SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
             SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest {of_rest('engagement')} GROUP BY e.path, e.pageview) t GROUP BY value""",
                    at,
                ):
                    bump(row)
            else:
                for row in self.db.all(f"SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events {of_rest('event')} GROUP BY e.name", at):
                    bump(row)
        elif page or event:
            # Every day of the range is built.
            pass
        else:
            col = f"s.{SESSION_DIMENSIONS[dimension]}"
            for row in self.db.all(
                f"""SELECT {col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
           SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
         FROM rl_sessions s WHERE s.site = ? AND {IS_VISIT} AND {w['sql']} AND {col} <> '' GROUP BY {col}""",
                [query["site"], *w["params"]],
            ):
                bump(row)
        entry_exit = dimension in ("entry", "exit")
        rows = [
            (value, x)
            for value, x in sums.items()
            if (event or value != "") and (x["pageviews"] > 0 if page else x["events"] > 0 if event else x["visits"] > 0)
        ]

        def order(a: tuple[str, dict[str, Any]], b: tuple[str, dict[str, Any]]) -> int | float:
            (av, x), (bv, y) = a, b
            if entry_exit:
                return y["visits"] - x["visits"] or code_order(av, bv)
            if event:
                return y["visitors"] - x["visitors"] or y["events"] - x["events"] or code_order(av, bv)
            if page:
                return y["visitors"] - x["visitors"] or y["pageviews"] - x["pageviews"] or code_order(av, bv)
            return y["visitors"] - x["visitors"] or y["visits"] - x["visits"] or code_order(av, bv)

        rows.sort(key=functools.cmp_to_key(lambda a, b: _sign(order(a, b))))
        out: list[dict[str, Any]] = []
        for value, x in rows[offset : offset + limit]:
            if event:
                out.append({"value": value, "visitors": x["visitors"], "events": x["events"]})
            elif page:
                out.append(
                    {
                        "value": value,
                        "visitors": x["visitors"],
                        "pageviews": x["pageviews"],
                        # Over every pageview that could report its time, counting those that sent none (under a
                        # second) as none.
                        "timeOnPage": _js.js_round(x["engaged"] / x["views"]) if x["views"] > 0 else 0,
                        "scrollDepth": _js.js_round(x["scroll_sum"] / x["scroll_n"]) if x["scroll_n"] > 0 else 0,
                    }
                )
            else:
                row: dict[str, Any] = {"value": value, "visitors": x["visitors"], "visits": x["visits"], "bounceRate": x["bounced"] / x["visits"] if x["visits"] > 0 else 0}
                if not entry_exit:
                    row["pageviews"] = x["pageviews"]
                    row["visitDuration"] = _js.js_round(x["duration"] / x["visits"]) if x["visits"] > 0 else 0
                out.append(row)
        return out

    def _rolled_stats(self, query: dict[str, Any]) -> dict[str, Any] | None:
        plan = self._rollup_plan(query, query["from"], query["to"])
        if plan is None:
            return None
        rows = self.db.all(
            f"""SELECT SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration
       FROM rl_rollups WHERE site = ? AND dim = '' AND day IN ({BUILT_DAYS})""",
            [query["site"], query["site"], query["from"], query["to"]],
        )
        rolled = rows[0] if rows else {}
        w = SqlStore._within(plan["rest"])
        rows = self.db.all(
            f"""SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
         SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
       FROM rl_sessions s WHERE s.site = ? AND {IS_VISIT} AND {w['sql']}""",
            [query["site"], *w["params"]],
        )
        raw = rows[0] if rows else {}

        def add(k: str) -> int | float:
            return num(rolled.get(k)) + num(raw.get(k))

        visits = add("visits")
        pageviews = add("pageviews")
        return {
            "visitors": add("visitors"),
            "visits": visits,
            "pageviews": pageviews,
            "viewsPerVisit": _round2(pageviews / visits) if visits > 0 else 0,
            "bounceRate": add("bounced") / visits if visits > 0 else 0,
            "visitDuration": _js.js_round(add("duration") / visits) if visits > 0 else 0,
        }

    def set_site_overrides(self, id: str, overrides: dict[str, Any]) -> None:
        self.db.run("UPDATE rl_sites SET overrides = ? WHERE id = ?", [_js.dumps(overrides), id])

    def last_seen(self, site: str) -> int | float | None:
        """When the site last recorded a visit, or None if it never has."""
        rows = self.db.all("SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')", [site])
        return _time(rows[0] if rows else None)

    def sites(self) -> list[dict[str, Any]]:
        rows = self.db.all("SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id")
        return [{"id": row["id"], "name": row["name"], "hostnames": _js.loads(row["hostnames"]), "timezone": row["timezone"]} for row in rows]

    # Salts

    def salt(self, day: str, fresh: str) -> str:
        """The salt for a day, made on first ask. Two racing callers agree on one."""
        self.db.run(upsert(self.db.dialect(), "rl_salts", ["day", "salt"], ["day"], []), [day, fresh])
        rows = self.db.all("SELECT salt FROM rl_salts WHERE day = ?", [day])
        return _or(rows[0]["salt"], fresh) if rows else fresh

    def salt_if_exists(self, day: str) -> str | None:
        rows = self.db.all("SELECT salt FROM rl_salts WHERE day = ?", [day])
        return rows[0]["salt"] if rows else None

    def drop_salts_before(self, day: str) -> None:
        """Deletes every salt older than `day`, so old hashes can never be recomputed."""
        self.db.run("DELETE FROM rl_salts WHERE day < ?", [day])

    # Ingest

    def open_session(self, site: str, visitors: list[str], since: int) -> dict[str, str] | None:
        """The visitor's open session: any of their hashes, active since `since`."""
        if not visitors:
            return None
        rows = self.db.all(
            f"""SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN ({', '.join('?' for _ in visitors)}) AND last_at >= ?
       ORDER BY last_at DESC, id LIMIT 1""",
            [site, *visitors, since],
        )
        return {"id": rows[0]["id"], "visitor": rows[0]["visitor"]} if rows else None

    def insert_session(self, row: dict[str, Any]) -> None:
        self.db.run(
            """INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,
        source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,
        browser, browser_version, os, os_version, device, screen, language)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                row["id"], row["site"], row["visitor"], row["startedAt"], row["startedAt"], row["hostname"], row["referrerHost"], row["referrerPath"],
                row["source"], row["channel"], row["utmSource"], row["utmMedium"], row["utmCampaign"], row["utmTerm"], row["utmContent"],
                row["country"], row["region"], row["city"], row["browser"], row["browserVersion"], row["os"], row["osVersion"], row["device"],
                row["screen"], row["language"],
            ],
        )

    def touch_session(self, id: str, ts: int, kind: str, path: str, reopen: bool = True) -> None:
        """Counts a row into its session. An event with `reopen` false, one that joins a visit already ended, counts
        without moving the session's last activity."""
        if kind == "click":
            self.db.run("UPDATE rl_sessions SET last_at = ? WHERE id = ?", [ts, id])
        elif kind == "pageview":
            self.db.run(
                """UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,
           entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?""",
                [ts, path, path, id],
            )
        elif reopen:
            self.db.run("UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?", [ts, id])
        else:
            self.db.run("UPDATE rl_sessions SET events = events + 1 WHERE id = ?", [id])

    def add_engagement(self, id: str, ms: int) -> None:
        self.db.run("UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?", [ms, id])

    def pageview(self, site: str, pageview: str) -> dict[str, Any] | None:
        """The pageview an engagement ping or event belongs to, with when its visit started and was last active."""
        rows = self.db.all(
            """SELECT e.session AS session, e.visitor AS visitor, e.path AS path, e.hostname AS hostname, e.ts AS ts, s.started_at AS started_at, s.last_at AS last_at
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.pageview = ? AND e.kind = 'pageview' LIMIT 1""",
            [site, pageview],
        )
        if not rows:
            return None
        row = rows[0]
        return {
            "session": _string(row["session"]),
            "visitor": _string(row["visitor"]),
            "path": _string(row["path"]),
            "hostname": _string(row["hostname"]),
            "ts": num(row["ts"]),
            "startedAt": num(row["started_at"]),
            "lastAt": num(row["last_at"]),
        }

    def touched_old_visit(self, site: str, started: int, before: int) -> None:
        """After a late event or engagement ping joins an old visit (a tab left open overnight), the day that visit
        started may already be added up. Forget that day so the next check builds it again."""
        if started < before:
            self.clear_rollups(site, {"from": started, "to": started + 1})

    def insert_event(self, row: dict[str, Any]) -> None:
        self.db.run(
            """INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                row["site"], row["ts"], row["kind"], row["visitor"], row["session"], row["pageview"], row["path"], row["hostname"], row["title"],
                row["name"], _js.dumps(row["props"]) if row.get("props") else None, row["engagedMs"], row.get("scroll"), row["link"],
            ],
        )

    # Links

    def link_by_slug(self, slug: str) -> dict[str, Any] | None:
        """The live link with a slug. Slugs are unique across every domain."""
        rows = self.db.all("SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1", [slug])
        return link_row(rows[0]) if rows else None

    def link_by_id(self, id: str) -> dict[str, Any] | None:
        rows = self.db.all("SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1", [id])
        return link_row(rows[0]) if rows else None

    def insert_link(self, link: dict[str, Any]) -> None:
        self.db.run(
            "INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [link["id"], link["site"], link["domain"], link["slug"], link["name"], link["url"], link["createdAt"], link["updatedAt"]],
        )

    def update_link(self, link: dict[str, Any]) -> None:
        self.db.run(
            "UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?",
            [link["domain"], link["slug"], link["name"], link["url"], link["updatedAt"], link["id"]],
        )

    def delete_link(self, id: str, now: int) -> None:
        """Hides a link and frees its slug; its clicks stay in the history."""
        self.db.run("UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", [now, id])

    # Shares

    @staticmethod
    def _share_row(r: dict[str, Any]) -> dict[str, Any]:
        return {"id": _string(r["id"]), "site": _string(r["site"]), "name": _string(_or(r.get("name"), "")), "createdAt": _js.number(r["created_at"])}

    def shares(self, site: str) -> list[dict[str, Any]]:
        rows = self.db.all("SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC, id", [site])
        return [self._share_row(r) for r in rows]

    def share_by_id(self, id: str) -> dict[str, Any] | None:
        rows = self.db.all("SELECT id, site, name, created_at FROM rl_shares WHERE id = ?", [id])
        return self._share_row(rows[0]) if rows else None

    def insert_share(self, share: dict[str, Any]) -> None:
        self.db.run("INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)", [share["id"], share["site"], share["name"], share["createdAt"]])

    def rename_share(self, id: str, name: str) -> None:
        self.db.run("UPDATE rl_shares SET name = ? WHERE id = ?", [name, id])

    def delete_share(self, id: str) -> None:
        """Deleting a share is how it is revoked: the link stops working at once."""
        self.db.run("DELETE FROM rl_shares WHERE id = ?", [id])

    # Funnels

    def funnels(self, site: str) -> list[dict[str, Any]]:
        rows = self.db.all("SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at, id", [site])
        return [
            {"id": _string(r["id"]), "site": _string(r["site"]), "name": _string(r["name"]), "steps": _js.loads(_string(r["steps"])), "createdAt": _js.number(r["created_at"])}
            for r in rows
        ]

    def save_funnel(self, f: dict[str, Any]) -> None:
        self.db.run(
            upsert(self.db.dialect(), "rl_funnels", ["id", "site", "name", "steps", "created_at"], ["id"], ["name", "steps"]),
            [f["id"], f["site"], f["name"], _js.dumps(f["steps"]), f["createdAt"]],
        )

    def delete_funnel(self, id: str) -> None:
        self.db.run("DELETE FROM rl_funnels WHERE id = ?", [id])

    def funnel_counts(self, query: dict[str, Any], funnel: dict[str, Any]) -> list[int]:
        """How many visits reached each step, in order, within the same visit. Step one is the first matching row in
        the range; each later step must come after the step before it. Filters choose which visits enter the
        funnel."""
        # The rows of the picked visits that match any step, in order, read once and walked here: a join from each
        # step to the next is planned badly by Postgres, which cannot guess how many visits go on.
        v = visit_rows(query["filters"], query["site"], query["from"], query["to"], self.db.dialect())
        scopes = [self._goal_scope({"kind": step["kind"], "match": step["match"], "name": step["match"]}) for step in funnel["steps"]]
        cases = ", ".join(f"CASE WHEN {scope['sql']} THEN 1 ELSE 0 END AS m{i}" for i, scope in enumerate(scopes))
        anys = " OR ".join(f"({scope['sql']})" for scope in scopes)
        scope_params = [p for scope in scopes for p in scope["params"]]
        rows = self.db.all(
            f"""SELECT e.session AS session, {cases}
       FROM {v['from']} WHERE {v['sql']} AND ({anys})
       ORDER BY e.session, e.ts, e.id""",
            [*scope_params, *v["params"], *scope_params],
        )
        counts = [0 for _ in funnel["steps"]]
        session: Any = _js.UNDEFINED
        reached = 0

        def close() -> None:
            for i in range(reached):
                counts[i] += 1

        for row in rows:
            if row["session"] != session:
                close()
                session = row["session"]
                reached = 0
            # Each step is the first matching row after the step before, so two steps in the same millisecond both
            # count, and one row never counts as two steps.
            if reached < len(counts) and num(row[f"m{reached}"]) == 1:
                reached += 1
        close()
        return counts

    def journey_pages(self, query: dict[str, Any], per_visit: int) -> dict[str, Any]:
        """Each visit's pageviews in order, at most `per_visit` of them, for journeys. A window function keeps the
        first ones of each visit, so a long visit cannot crowd the rest out. Visits belong to the range they started
        in."""
        dialect = self.db.dialect()
        scope = visit_scope(query["filters"], query["site"], query["from"], query["to"], dialect)

        # The newest visits the filters pick, JOURNEY_VISITS at most, so a long range stays quick and small in
        # memory.
        def newest(columns: str, limit: int) -> str:
            return f"""SELECT {columns} FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{scope['sql']}
         ORDER BY s.started_at DESC, s.id LIMIT {limit}"""

        visit_params = [query["site"], query["from"], query["to"], *scope["params"]]
        # How many there are, one past the cap telling whether it was reached, and when the oldest of them began, so
        # the rows are read from there on rather than from the start of a long range.
        rows = self.db.all(f"SELECT COUNT(*) AS n, MIN(started_at) AS t FROM ({newest('s.started_at AS started_at', JOURNEY_VISITS + 1)}) x", visit_params)
        first = rows[0] if rows else {}
        if not num(first.get("n")):
            return {"rows": [], "sampled": False}
        from_ = max(query["from"], num(first.get("t")))
        # MySQL takes no LIMIT in an IN list, but does in a table inside one.
        visits = f"SELECT id FROM ({newest('s.id AS id', JOURNEY_VISITS)}) x" if dialect == "mysql" else newest("s.id", JOURNEY_VISITS)
        rows = self.db.all(
            # The visits are read as an IN list, which every database probes from the events side, so the plan does
            # not depend on the planner's statistics. Refreshes (the same page twice in a row) are dropped before
            # counting, so they never use up the steps.
            f"""WITH raw AS (
         SELECT e.session AS session, e.path AS path, e.ts AS ts, e.id AS id,
           LAG(e.path) OVER (PARTITION BY e.session ORDER BY e.ts, e.id) AS prev
         FROM rl_events e
         WHERE e.site = ? AND e.kind = 'pageview' AND e.ts >= ? AND e.ts < ? AND e.session IN ({visits})),
       v AS (
         SELECT session, path, ROW_NUMBER() OVER (PARTITION BY session ORDER BY ts, id) AS n
         FROM raw WHERE prev IS NULL OR prev <> path)
       SELECT session, path FROM v WHERE n <= ? ORDER BY session, n""",
            [query["site"], from_, query["to"] + EVENT_TAIL_MS, *visit_params, per_visit],
        )
        return {"rows": [{"session": _string(r["session"]), "path": _string(r["path"])} for r in rows], "sampled": num(first.get("n")) > JOURNEY_VISITS}

    # API tokens

    @staticmethod
    def _token_row(r: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": _string(r["id"]),
            "name": _string(r["name"]),
            "site": _string(_or(r.get("site"), "")),
            "scope": "manage" if r.get("scope") == "manage" else "read",
            "hash": _string(r["hash"]),
            "hint": _string(_or(r.get("hint"), "")),
            "createdAt": _js.number(r["created_at"]),
            "lastUsedAt": None if r.get("last_used_at") is None else _js.number(r["last_used_at"]),
        }

    def tokens(self) -> list[dict[str, Any]]:
        return [self._token_row(r) for r in self.db.all("SELECT * FROM rl_tokens ORDER BY created_at DESC, id")]

    def token_by_hash(self, hash: str) -> dict[str, Any] | None:
        rows = self.db.all("SELECT * FROM rl_tokens WHERE hash = ?", [hash])
        return self._token_row(rows[0]) if rows else None

    def insert_token(self, t: dict[str, Any]) -> None:
        self.db.run(
            "INSERT INTO rl_tokens (id, name, site, scope, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [t["id"], t["name"], t["site"], t["scope"], t["hash"], t["hint"], t["createdAt"], t["lastUsedAt"]],
        )

    def touch_token(self, id: str, now: int) -> None:
        self.db.run("UPDATE rl_tokens SET last_used_at = ? WHERE id = ?", [now, id])

    def delete_token(self, id: str) -> bool:
        """Deleting a token is how it is revoked: it stops working at once."""
        return self._changed("DELETE FROM rl_tokens WHERE id = ?", [id]) == 1

    # Settings

    def setting(self, key: str) -> str | None:
        rows = self.db.all('SELECT value FROM rl_settings WHERE "key" = ?', [key])
        return _string(rows[0]["value"]) if rows else None

    def settings_starting_with(self, prefix: str) -> list[dict[str, str]]:
        """Every setting whose key starts with a prefix, such as each connected install's."""
        rows = self.db.all("SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE ? ESCAPE '\\'", [f"{escape_like(prefix)}%"])
        return [{"key": _string(r["key"]), "value": _string(r["value"])} for r in rows]

    def set_setting(self, key: str, value: str | None) -> None:
        if value is None:
            self.db.run('DELETE FROM rl_settings WHERE "key" = ?', [key])
        else:
            self.db.run(upsert(self.db.dialect(), "rl_settings", ['"key"', "value"], ['"key"'], ["value"]), [key, value])

    # Email reports

    @staticmethod
    def _report_row(r: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": _string(r["id"]),
            "site": _string(r["site"]),
            "email": _string(r["email"]),
            "frequency": _string(r["frequency"]),
            "lang": _string(_or(r.get("lang"), "en")),
            "token": _string(r["token"]),
            "origin": _string(_or(r.get("origin"), "")),
            "lastPeriod": _string(_or(r.get("last_period"), "")),
            "lastSentAt": None if r.get("last_sent_at") is None else _js.number(r["last_sent_at"]),
            "createdAt": _js.number(r["created_at"]),
        }

    def reports(self, site: str | None = None) -> list[dict[str, Any]]:
        rows = (
            self.db.all("SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at, id", [site])
            if site
            else self.db.all("SELECT * FROM rl_reports ORDER BY created_at, id")
        )
        return [self._report_row(r) for r in rows]

    def report_by(self, field: str, value: str) -> dict[str, Any] | None:
        rows = self.db.all(f"SELECT * FROM rl_reports WHERE {'id' if field == 'id' else 'token'} = ?", [value])
        return self._report_row(rows[0]) if rows else None

    def insert_report(self, r: dict[str, Any]) -> None:
        self.db.run(
            "INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [r["id"], r["site"], r["email"], r["frequency"], r["lang"], r["token"], r["origin"], r["lastPeriod"], r["lastSentAt"], r["createdAt"]],
        )

    def claim_report(self, id: str, period: str, now: int) -> bool:
        """Records a period as sent. Only one caller wins, so two cron runs at once cannot both send it."""
        # One statement, so of two cron runs at once only one gets the row back.
        return self._changed("UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ?", [period, now, id, period]) == 1

    def release_report(self, id: str, period: str, previous: str) -> None:
        """Puts a period back when its email failed, so the next run tries again."""
        self.db.run("UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?", [previous, id, period])

    def delete_report(self, id: str) -> None:
        self.db.run("DELETE FROM rl_reports WHERE id = ?", [id])

    # Goals

    def goals(self, site: str | None = None) -> list[dict[str, Any]]:
        rows = (
            self.db.all("SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at, id", [site])
            if site
            else self.db.all("SELECT * FROM rl_goals ORDER BY created_at, id")
        )
        return [goal_row(r) for r in rows]

    def goal_by_id(self, id: str) -> dict[str, Any] | None:
        rows = self.db.all("SELECT * FROM rl_goals WHERE id = ?", [id])
        return goal_row(rows[0]) if rows else None

    def save_goal(self, g: dict[str, Any], before: dict[str, Any] | None = None) -> None:
        # A click goal is counted by its name, which the tracker sends as the event name. Renaming one renames its
        # past clicks too, so its history stays.
        if before is not None and before["kind"] == "click" and g["kind"] == "click" and before["name"] != g["name"]:
            self.db.run("UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?", [g["name"], g["site"], before["name"]])
        self.db.run(
            upsert(
                self.db.dialect(),
                "rl_goals",
                ["id", "site", "name", "kind", '"match"', "click_by", "value_mode", "value", "value_prop", "currency", "created_at"],
                ["id"],
                ["name", "kind", '"match"', "click_by", "value_mode", "value", "value_prop", "currency"],
            ),
            [g["id"], g["site"], g["name"], g["kind"], g["match"], g["clickBy"], g["valueMode"], g["value"], g["valueProp"], g["currency"], g["createdAt"]],
        )

    def delete_goal(self, id: str) -> None:
        self.db.run("DELETE FROM rl_goals WHERE id = ?", [id])

    def _goal_scope(self, goal: dict[str, Any]) -> dict[str, Any]:
        """The events a goal counts, as a WHERE fragment over rl_events e."""
        if goal["kind"] == "page":
            if "*" in goal["match"]:
                if self.db.dialect() != "sqlite":
                    # Postgres's LIKE heeds case, and so does MySQL's under Runlight's binary collation.
                    return {"sql": "e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\\'", "params": [like_pattern(goal["match"])]}
                # SQLite's LIKE ignores case; GLOB does not, so every database agrees with the others and with exact
                # matches.
                return {"sql": "e.kind = 'pageview' AND e.path GLOB ?", "params": [glob_pattern(goal["match"])]}
            return {"sql": "e.kind = 'pageview' AND e.path = ?", "params": [goal["match"]]}
        # Event goals count the named event; click goals count the event the tracker sends for them.
        return {"sql": "e.kind = 'event' AND e.name = ?", "params": [goal["name"] if goal["kind"] == "click" else goal["match"]]}

    def _prop_value(self, prop: str) -> dict[str, Any]:
        """A numeric event property for one row, as SQL (0 when it is not a number). Property names are checked
        before they get here."""
        dialect = self.db.dialect()
        if dialect == "postgres":
            return {
                "sql": "(CASE WHEN (e.props::jsonb ->> ?) ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)",
                "params": [prop, prop],
            }
        path = f'$."{prop}"'
        if dialect == "mysql":
            # As SQLite: a JSON number as it is, or text of digits with an optional sign and one decimal point.
            value = "JSON_EXTRACT(e.props, ?)"
            return {
                "sql": f"""(CASE
          WHEN JSON_TYPE({value}) IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN CAST({value} AS DOUBLE)
          WHEN JSON_TYPE({value}) = 'STRING' AND JSON_UNQUOTE({value}) REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN CAST(JSON_UNQUOTE({value}) AS DOUBLE)
          ELSE 0 END)""",
                "params": [path] * 5,
            }
        # As Postgres's pattern: a JSON number, or text of digits with an optional sign and one decimal point.
        text = "CAST(json_extract(e.props, ?) AS TEXT)"
        return {
            "sql": f"""(CASE
        WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)
        WHEN json_type(e.props, ?) = 'text' AND {text} GLOB '[0-9]*' AND {text} NOT GLOB '*[^0-9.]*' AND {text} NOT GLOB '*.*.*' AND {text} NOT GLOB '*.' THEN CAST({text} AS REAL)
        WHEN json_type(e.props, ?) = 'text' AND {text} GLOB '-[0-9]*' AND substr({text}, 2) NOT GLOB '*[^0-9.]*' AND {text} NOT GLOB '*.*.*' AND {text} NOT GLOB '*.' THEN CAST({text} AS REAL)
        ELSE 0 END)""",
            "params": [path] * 14,
        }

    def event_prop_keys(self, query: dict[str, Any], event: str) -> list[dict[str, Any]]:
        """The property names sent with an event in a query's range, most used first."""
        dialect = self.db.dialect()
        v = visit_rows(query["filters"], query["site"], query["from"], query["to"], dialect)
        where = f"{v['sql']} AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL"
        params = [*v["params"], event]
        if dialect == "mysql":
            # Each key as a row of its own, compared and sorted by code point like every other value.
            rows = self.db.all(
                f"""SELECT j.k AS "key", COUNT(*) AS events FROM {v['from']}
             CROSS JOIN JSON_TABLE(JSON_KEYS(CASE WHEN JSON_TYPE(e.props) = 'OBJECT' THEN e.props ELSE '{{}}' END), '$[*]' COLUMNS (k VARCHAR(255) COLLATE {MYSQL_COLLATION} PATH '$')) j
             WHERE {where} GROUP BY j.k ORDER BY events DESC, j.k LIMIT 30""",
                params,
            )
        elif dialect == "postgres":
            rows = self.db.all(
                f"""SELECT k AS "key", COUNT(*) AS events FROM {v['from']} CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{{}}'::jsonb END) AS k
             WHERE {where} GROUP BY k ORDER BY events DESC, k{self._text_order} LIMIT 30""",
                params,
            )
        else:
            rows = self.db.all(
                f"""SELECT j.key AS "key", COUNT(*) AS events FROM {v['from']}, json_each(e.props) j
             WHERE {where} AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key{self._text_order} LIMIT 30""",
                params,
            )
        return [{"key": _string(r["key"]), "events": num(r["events"])} for r in rows]

    def event_prop_values(self, query: dict[str, Any], event: str, key: str, limit: int) -> list[dict[str, Any]]:
        """The values one property of an event took, with how often and by how many visitors."""
        dialect = self.db.dialect()
        v = visit_rows(query["filters"], query["site"], query["from"], query["to"], dialect)
        if dialect == "postgres":
            value = "(e.props::jsonb ->> ?)"
        elif dialect == "mysql":
            value = f"(JSON_UNQUOTE(JSON_EXTRACT(e.props, ?)) COLLATE {MYSQL_COLLATION})"
        else:
            value = "CAST(json_extract(e.props, ?) AS TEXT)"
        path = key if dialect == "postgres" else f'$."{key}"'
        rows = self.db.all(
            f"""SELECT * FROM (SELECT {value} AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM {v['from']}
         WHERE {v['sql']} AND e.kind = 'event' AND e.name = ? AND {value} IS NOT NULL GROUP BY 1) t
       ORDER BY events DESC, value{self._text_order} LIMIT ?""",
            [path, *v["params"], event, path, limit],
        )
        return [{"value": _string(r["value"]), "events": num(r["events"]), "visitors": num(r["visitors"])} for r in rows]

    @property
    def _double(self) -> str:
        """The floating point type to cast to, which MySQL names in one word."""
        return "DOUBLE" if self.db.dialect() == "mysql" else "DOUBLE PRECISION"

    def _revenue_value(self, goal: dict[str, Any]) -> dict[str, Any]:
        """A goal's worth for one converting row, as SQL."""
        if goal["valueMode"] == "prop" and goal["valueProp"]:
            return self._prop_value(goal["valueProp"])
        if goal["valueMode"] == "fixed":
            return {"sql": f"CAST(? AS {self._double})", "params": [goal["value"]]}
        return {"sql": "0", "params": []}

    def goal_totals_all(self, query: dict[str, Any], goals: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        """Every goal's totals in one pass over the range's events, instead of a query per goal: each goal adds a
        conditional count, distinct count, and sum."""
        out: dict[str, dict[str, Any]] = {}
        v = visit_rows(query["filters"], query["site"], query["from"], query["to"], self.db.dialect())
        # As many goals per query as keep it under D1's parameter limit.
        chunks: list[list[dict[str, Any]]] = [[]]
        count = len(v["params"])
        for goal in goals:
            cost = len(self._goal_scope(goal)["params"]) * 4 + len(self._revenue_value(goal)["params"])
            if chunks[-1] and count + cost > MAX_PARAMS:
                chunks.append([])
                count = len(v["params"])
            chunks[-1].append(goal)
            count += cost
        for chunk in chunks:
            if not chunk:
                continue
            columns: list[str] = []
            params: list[Any] = []
            # Only rows some goal of the chunk counts are read.
            any_: list[str] = []
            any_params: list[Any] = []
            for i, goal in enumerate(chunk):
                scope = self._goal_scope(goal)
                value = self._revenue_value(goal)
                columns.extend(
                    [
                        f"SUM(CASE WHEN {scope['sql']} THEN 1 ELSE 0 END) AS c{i}",
                        f"COUNT(DISTINCT CASE WHEN {scope['sql']} THEN e.visitor END) AS v{i}",
                        f"SUM(CASE WHEN {scope['sql']} THEN {value['sql']} ELSE 0 END) AS r{i}",
                    ]
                )
                params.extend([*scope["params"], *scope["params"], *scope["params"], *value["params"]])
                any_.append(f"({scope['sql']})")
                any_params.extend(scope["params"])
            rows = self.db.all(
                f"""SELECT {', '.join(columns)} FROM {v['from']}
         WHERE {v['sql']} AND e.kind IN ('pageview', 'event') AND ({' OR '.join(any_)})""",
                [*params, *v["params"], *any_params],
            )
            row = rows[0] if rows else {}
            for i, goal in enumerate(chunk):
                out[goal["id"]] = {"conversions": num(row.get(f"c{i}")), "visitors": num(row.get(f"v{i}")), "revenue": _round2(num(row.get(f"r{i}")))}
        return out

    def _revenue_sql(self, goal: dict[str, Any]) -> dict[str, Any]:
        if goal["valueMode"] == "prop" and goal["valueProp"]:
            value = self._prop_value(goal["valueProp"])
            return {"sql": f"SUM({value['sql']})", "params": value["params"]}
        # Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
        if goal["valueMode"] == "fixed":
            return {"sql": f"COUNT(*) * CAST(? AS {self._double})", "params": [goal["value"]]}
        return {"sql": "0", "params": []}

    def goal_totals(self, query: dict[str, Any], goal: dict[str, Any]) -> dict[str, Any]:
        """One goal's conversions, converting visitors, and revenue for a query's range and filters."""
        v = visit_rows(query["filters"], query["site"], query["from"], query["to"], self.db.dialect())
        scope = self._goal_scope(goal)
        revenue = self._revenue_sql(goal)
        rows = self.db.all(
            f"""SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, {revenue['sql']} AS revenue
       FROM {v['from']} WHERE {v['sql']} AND {scope['sql']}""",
            [*revenue["params"], *v["params"], *scope["params"]],
        )
        row = rows[0] if rows else {}
        return {"conversions": num(row.get("conversions")), "visitors": num(row.get("visitors")), "revenue": _round2(num(row.get("revenue")))}

    def goal_breakdown(self, query: dict[str, Any], goal: dict[str, Any], by: str, limit: int = 10) -> list[dict[str, Any]]:
        """A goal's conversions split by where the visit came from, or by the page it happened on."""
        v = visit_rows(query["filters"], query["site"], query["from"], query["to"], self.db.dialect())
        col = "e.path" if by == "path" else f"s.{by}"
        scope = self._goal_scope(goal)
        revenue = self._revenue_sql(goal)
        rows = self.db.all(
            f"""SELECT {col} AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, {revenue['sql']} AS revenue
       FROM {v['from']} WHERE {v['sql']} AND {scope['sql']}
       GROUP BY {col} ORDER BY conversions DESC, {col}{self._text_order} LIMIT ?""",
            [*revenue["params"], *v["params"], *scope["params"], limit],
        )
        return [
            {"value": _string(_or(r.get("value"), "")), "conversions": num(r["conversions"]), "visitors": num(r["visitors"]), "revenue": _round2(num(r.get("revenue")))}
            for r in rows
        ]

    def goal_series(self, query: dict[str, Any], goal: dict[str, Any], buckets: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """A goal's conversions and revenue in each bucket, by when each visit started."""
        if not buckets:
            return []
        dialect = self.db.dialect()
        scope = self._goal_scope(goal)
        revenue = self._revenue_sql(goal)
        # Each bucket binds three values; the rest are fixed. As many buckets a statement as keep it under D1's 100.
        fixed = len(revenue["params"]) + len(scope["params"]) + len(visit_rows(query["filters"], query["site"], 0, 0, dialect)["params"])
        size = max(1, min(BUCKETS_PER_QUERY, (MAX_PARAMS - fixed) // 3))
        if len(buckets) > size:
            return in_pieces(buckets, size, lambda piece: self.goal_series(query, goal, piece))
        v = visit_rows(query["filters"], query["site"], buckets[0]["start"], buckets[-1]["end"], dialect)
        rows = self.db.all(
            f"""WITH b (i, bs, be) AS ({bucket_table(dialect, buckets)})
       SELECT b.i AS i, COUNT(*) AS conversions, {revenue['sql']} AS revenue
       FROM {v['from']} CROSS JOIN b
       WHERE {v['sql']} AND s.started_at >= b.bs AND s.started_at < b.be AND {scope['sql']}
       GROUP BY b.i""",
            [*(x for i, b in enumerate(buckets) for x in (i, b["start"], b["end"])), *revenue["params"], *v["params"], *scope["params"]],
        )
        found = {num(r["i"]): r for r in rows}
        return [
            {"start": b["start"], "conversions": num(found.get(i, {}).get("conversions")), "revenue": _round2(num(found.get(i, {}).get("revenue")))}
            for i, b in enumerate(buckets)
        ]

    def link_domains(self) -> list[dict[str, Any]]:
        return [{"domain": r["domain"], "site": r["site"]} for r in self.db.all("SELECT domain, site FROM rl_link_domains ORDER BY domain")]

    def add_link_domain(self, domain: str, site: str, now: int) -> None:
        self.db.run(upsert(self.db.dialect(), "rl_link_domains", ["domain", "site", "created_at"], ["domain"], []), [domain, site, now])

    def remove_link_domain(self, domain: str) -> None:
        """Removes a domain. Its links keep it as their home and fall back to the app's own link path until the
        domain is added again."""
        self.db.run("DELETE FROM rl_link_domains WHERE domain = ?", [domain])

    def links(self, site: str, from_: int, to: int) -> list[dict[str, Any]]:
        """A site's links, newest first, with their clicks in a range. Clicks imported as daily counts have no
        visitor, so they add to clicks only."""
        rows = self.db.all(
            """SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors
       FROM rl_links l LEFT JOIN (
         SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events
         WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link
       ) c ON c.link = l.id
       WHERE l.site = ? AND l.deleted_at IS NULL
       ORDER BY l.created_at DESC, l.id""",
            [site, from_, to, site],
        )
        return [{**link_row(row), "clicks": num(row["clicks"]), "visitors": num(row["visitors"])} for row in rows]

    def link_series(self, site: str, link: str, buckets: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """One link's clicks per bucket."""
        if not buckets:
            return []
        if len(buckets) > BUCKETS_PER_QUERY:
            return in_pieces(buckets, BUCKETS_PER_QUERY, lambda piece: self.link_series(site, link, piece))
        rows = self.db.all(
            f"""WITH b (i, bs, be) AS ({bucket_table(self.db.dialect(), buckets)})
       SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors
       FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be
       WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i""",
            [*(x for i, b in enumerate(buckets) for x in (i, b["start"], b["end"])), link, site],
        )
        found = {num(r["i"]): r for r in rows}
        return [{"start": b["start"], "clicks": num(found.get(i, {}).get("clicks")), "visitors": num(found.get(i, {}).get("visitors"))} for i, b in enumerate(buckets)]

    def link_breakdown(self, site: str, link: str, from_: int, to: int, dimension: str, limit: int) -> list[dict[str, Any]]:
        """One link's clicks by a visit dimension: where they came from, where they were, what they used."""
        col = f"s.{SESSION_DIMENSIONS[dimension]}"
        rows = self.db.all(
            f"""SELECT {col} AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND {col} <> ''
       GROUP BY {col} ORDER BY clicks DESC, {col}{self._text_order} LIMIT ?""",
            [site, link, from_, to, limit],
        )
        return [{"value": _string(r["value"]), "visitors": num(r["visitors"]), "events": num(r["clicks"])} for r in rows]

    # Reports

    @property
    def _text_order(self) -> str:
        """Ties are broken by the value in code point order, the order the rolled-up path sorts in, so a report
        reads the same before and after its days are built. Postgres would otherwise use its locale's order. MySQL's
        columns already sort this way; a value worked out from JSON may not."""
        dialect = self.db.dialect()
        return ' COLLATE "C"' if dialect == "postgres" else f" COLLATE {MYSQL_COLLATION}" if dialect == "mysql" else ""

    def first_own_visit(self, site: str) -> int | float | None:
        """When Runlight itself first counted a visit, leaving out imported history."""
        # A session opened only by a short link click is not a visit, so it does not count as the first.
        rows = self.db.all(f"SELECT MIN(started_at) AS t FROM rl_sessions s WHERE s.site = ? AND s.imported = 0 AND {IS_VISIT}", [site])
        return _time(rows[0] if rows else None)

    def first_seen(self, site: str) -> int | float | None:
        """When the site's first visit was recorded, or None with no data yet."""
        rows = self.db.all("SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?", [site])
        return _time(rows[0] if rows else None)

    def visitors(self, query: dict[str, Any]) -> int | float:
        """Just the visitor count from stats(), in one query, for conversion rates."""
        scope = visit_scope(query["filters"], query["site"], query["from"], query["to"], self.db.dialect())
        rows = self.db.all(
            f"SELECT COUNT(DISTINCT s.visitor) AS visitors FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{scope['sql']}",
            [query["site"], query["from"], query["to"], *scope["params"]],
        )
        return num(rows[0].get("visitors") if rows else None)

    def stats(self, query: dict[str, Any]) -> dict[str, Any]:
        rolled = self._rolled_stats(query)
        if rolled:
            return rolled
        dialect = self.db.dialect()
        # Filtered or not, the numbers describe visits that started in the range (see visit_scope).
        scope = visit_scope(query["filters"], query["site"], query["from"], query["to"], dialect)
        pv = pageviews_of(query["filters"], query["site"], query["from"], query["to"], dialect)
        rows = self.db.all(
            f"""SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM({"COALESCE(pv.n, 0)" if pv else "s.pageviews"}) AS pageviews,
         SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
       FROM rl_sessions s {f"LEFT JOIN {pv['sql']} pv ON pv.session = s.id" if pv else ""}
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{scope['sql']}""",
            [*(pv["params"] if pv else []), query["site"], query["from"], query["to"], *scope["params"]],
        )
        row = rows[0] if rows else {}
        visits = num(row.get("visits"))
        pageviews = num(row.get("pageviews"))
        return {
            "visitors": num(row.get("visitors")),
            "visits": visits,
            "pageviews": pageviews,
            "viewsPerVisit": _round2(pageviews / visits) if visits > 0 else 0,
            "bounceRate": num(row.get("bounced")) / visits if visits > 0 else 0,
            "visitDuration": _js.js_round(num(row.get("duration")) / visits) if visits > 0 else 0,
        }

    def series(self, query: dict[str, Any], buckets: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not buckets:
            return []
        if len(buckets) > BUCKETS_PER_QUERY:
            return in_pieces(buckets, BUCKETS_PER_QUERY, lambda piece: self.series(query, piece))
        dialect = self.db.dialect()
        first, last = buckets[0]["start"], buckets[-1]["end"]
        params: list[Any] = [x for i, b in enumerate(buckets) for x in (i, b["start"], b["end"])]
        # Filtered or not, each bucket counts the visits that started in it (see visit_scope).
        scope = visit_scope(query["filters"], query["site"], first, last, dialect)
        pv = pageviews_of(query["filters"], query["site"], first, last, dialect)
        # Built days that fit inside one bucket come from rollups; the rest from the visits.
        plan = self._rollup_plan(query, first, last)

        def in_bucket(d: dict[str, Any]) -> int:
            for i, b in enumerate(buckets):
                if b["start"] <= d["start"] and d["end"] <= b["end"]:
                    return i
            return -1

        used = [d for d in plan["days"] if in_bucket(d) >= 0] if plan else []
        rest: list[tuple[int | float, int | float]] | None = None
        if used:
            rest = []
            from_ = first
            for d in used:
                if d["start"] > from_:
                    rest.append((from_, d["start"]))
                from_ = max(from_, d["end"])
            if from_ < last:
                rest.append((from_, last))
        # MySQL joins the buckets to every visit of the site unless told the whole range as well.
        if rest is not None:
            w = SqlStore._within(rest)
        elif dialect == "mysql":
            w = SqlStore._within([(first, last)])
        else:
            w = {"sql": "1 = 1", "params": []}
        # Filters and scattered unbuilt days add values of their own; when they would pass D1's 100, the buckets go
        # in halves.
        if len(params) + 1 + len(w["params"]) + len(scope["params"]) + (len(pv["params"]) if pv else 0) > MAX_PARAMS and len(buckets) > 1:
            half = -(-len(buckets) // 2)
            return [*self.series(query, buckets[:half]), *self.series(query, buckets[half:])]
        sums: dict[int, dict[str, int | float]] = {}

        def bump(i: int, row: dict[str, Any]) -> None:
            into = sums.setdefault(i, {"visitors": 0, "n": 0, "views": 0, "bounced": 0, "duration": 0})
            for k in into:
                into[k] += num(row.get(k))

        if used:
            rolled = self.db.all(
                f"SELECT day, visitors, visits AS n, pageviews AS views, bounced, duration FROM rl_rollups WHERE site = ? AND dim = '' AND day IN ({BUILT_DAYS})",
                [query["site"], query["site"], first, last],
            )
            at = {d["day"]: in_bucket(d) for d in used}
            for row in rolled:
                day = _string(row["day"])
                if day in at:
                    bump(at[day], row)
        rows = self.db.all(
            f"""WITH b (i, bs, be) AS ({bucket_table(dialect, buckets)})
       SELECT b.i AS i, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS n, SUM({"COALESCE(pv.n, 0)" if pv else "s.pageviews"}) AS views,
         SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
       FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be
       {f"LEFT JOIN {pv['sql']} pv ON pv.session = s.id" if pv else ""}
       WHERE {IS_VISIT}{scope['sql']} AND {w['sql']}
       GROUP BY b.i""",
            [*params, query["site"], *(pv["params"] if pv else []), *scope["params"], *w["params"]],
        )
        for row in rows:
            bump(num(row["i"]), row)
        out = []
        for i, bucket in enumerate(buckets):
            row = sums.get(i, {})
            n = num(row.get("n"))
            out.append(
                {
                    "start": bucket["start"],
                    "visitors": num(row.get("visitors")),
                    "visits": n,
                    "pageviews": num(row.get("views")),
                    "viewsPerVisit": _round2(num(row.get("views")) / n) if n > 0 else 0,
                    "bounceRate": num(row.get("bounced")) / n if n > 0 else 0,
                    "visitDuration": _js.js_round(num(row.get("duration")) / n) if n > 0 else 0,
                }
            )
        return out

    def breakdown(self, query: dict[str, Any], dimension: str, limit: int, offset: int) -> list[dict[str, Any]]:
        page = [limit, offset]
        dialect = self.db.dialect()
        if dimension in ("ai_agent", "ai_page"):
            col = "e.name" if dimension == "ai_agent" else "e.path"
            rows = self.db.all(
                f"""SELECT {col} AS value, COUNT(*) AS fetches FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'
         GROUP BY {col} ORDER BY fetches DESC, {col}{self._text_order} LIMIT ? OFFSET ?""",
                [query["site"], query["from"], query["to"], *page],
            )
            return [{"value": _string(r["value"]), "visitors": 0, "fetches": num(r["fetches"])} for r in rows]

        rolled = self._rolled_breakdown(query, dimension, limit, offset)
        if rolled is not None:
            return rolled

        # Filtered or not, the visits are those that started in the range (see visit_scope).
        scope = visit_scope(query["filters"], query["site"], query["from"], query["to"], dialect)
        if is_session_dimension(dimension):
            pv = pageviews_of(query["filters"], query["site"], query["from"], query["to"], dialect)
            col = f"s.{SESSION_DIMENSIONS[dimension]}"
            entry_exit = dimension in ("entry", "exit")
            rows = self.db.all(
                f"""SELECT {col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM({"COALESCE(pv.n, 0)" if pv else "s.pageviews"}) AS pageviews,
           SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM({DURATION}) AS duration
         FROM rl_sessions s {f"LEFT JOIN {pv['sql']} pv ON pv.session = s.id" if pv else ""}
         WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{scope['sql']} AND {col} <> ''
         GROUP BY {col} ORDER BY {"visits DESC" if entry_exit else "visitors DESC, visits DESC"}, {col}{self._text_order} LIMIT ? OFFSET ?""",
                [*(pv["params"] if pv else []), query["site"], query["from"], query["to"], *scope["params"], *page],
            )
            out = []
            for row in rows:
                visits = num(row["visits"])
                item: dict[str, Any] = {
                    "value": _string(row["value"]),
                    "visitors": num(row["visitors"]),
                    "visits": visits,
                    "bounceRate": num(row.get("bounced")) / visits if visits > 0 else 0,
                }
                if not entry_exit:
                    item["pageviews"] = num(row.get("pageviews"))
                    item["visitDuration"] = _js.js_round(num(row.get("duration")) / visits) if visits > 0 else 0
                out.append(item)
            return out

        # Rows from the visits that started in the range and that the filters pick, narrowed by any filter on the
        # same kind of row ("page is /pricing" on pages), as the rollups count them.
        def within(dimensions: list[str]) -> dict[str, Any]:
            rows = row_scope(query["filters"], dimensions, dialect)
            return {
                "sql": f" AND e.session IN (SELECT s.id FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{scope['sql']}){rows['sql']}",
                "params": [query["site"], query["from"], query["to"], *scope["params"], *rows["params"]],
                "to": query["to"] + EVENT_TAIL_MS,
            }

        if dimension in ("page", "hostname"):
            col = f"e.{EVENT_DIMENSIONS[dimension]}"
            w = within(["page", "hostname"])
            rows = self.db.all(
                f"""SELECT {col} AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews, {LIVE_VIEWS} AS views
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'{w['sql']}
         GROUP BY {col} ORDER BY visitors DESC, pageviews DESC, {col}{self._text_order} LIMIT ? OFFSET ?""",
                [query["site"], query["from"], w["to"], *w["params"], *page],
            )
            out = [{"value": _string(r["value"]), "visitors": num(r["visitors"]), "pageviews": num(r["pageviews"])} for r in rows]
            live = {_string(r["value"]): num(r["views"]) for r in rows}
            if dimension == "page" and out:
                # Each pageview's engaged time added up and its deepest scroll, then the mean over pageviews. Filters
                # add values of their own, so fewer paths go in each statement, keeping it within D1's 100.
                size = max(1, min(VALUES_PER_QUERY, MAX_PARAMS - 3 - len(w["params"])))
                times = in_pieces(
                    out,
                    size,
                    lambda piece: self.db.all(
                        f"""SELECT value, SUM(total) AS total, COUNT(*) AS views, AVG(deepest) AS scroll FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest
               FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'{w['sql']}
               AND e.path IN ({', '.join('?' for _ in piece)}) GROUP BY e.path, e.pageview) t GROUP BY value""",
                        [query["site"], query["from"], w["to"], *w["params"], *(r["value"] for r in piece)],
                    ),
                )
                by_path = {_string(t["value"]): t for t in times}
                for item in out:
                    time = by_path.get(item["value"])
                    views = live.get(item["value"], 0)
                    item["timeOnPage"] = _js.js_round(num(time.get("total")) / views) if time and views else 0
                    item["scrollDepth"] = 0 if time is None or time.get("scroll") is None else _js.js_round(num(time["scroll"]))
            return out

        if dimension == "event":
            w = within(["event"])
            rows = self.db.all(
                f"""SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'{w['sql']}
         GROUP BY e.name ORDER BY visitors DESC, events DESC, e.name{self._text_order} LIMIT ? OFFSET ?""",
                [query["site"], query["from"], w["to"], *w["params"], *page],
            )
            return [{"value": _string(r["value"]), "visitors": num(r["visitors"]), "events": num(r["events"])} for r in rows]

        return []

    def hourly(self, query: dict[str, Any]) -> list[dict[str, Any]]:
        """Visits by quarter hour since the epoch, which the caller folds into local weekdays and hours, keeping time
        zones (DST included) out of SQL. Quarters, not hours, so a site in a half-hour or 45-minute timezone (India,
        Nepal) folds each into the right local hour."""
        dialect = self.db.dialect()
        plan = self._rollup_plan(query, query["from"], query["to"])
        if plan:
            sums: dict[int | float, dict[str, Any]] = {}

            def bump(quarter: int | float, row: dict[str, Any]) -> None:
                into = sums.setdefault(quarter, {"quarter": quarter, "visits": 0, "visitors": 0, "pageviews": 0, "bounced": 0})
                into["visits"] += num(row.get("visits"))
                into["visitors"] += num(row.get("visitors"))
                into["pageviews"] += num(row.get("pageviews"))
                into["bounced"] += num(row.get("bounced"))

            rolled = self.db.all(
                f"SELECT value, visits, visitors, pageviews, bounced FROM rl_rollups WHERE site = ? AND dim = 'quarter' AND day IN ({BUILT_DAYS})",
                [query["site"], query["site"], query["from"], query["to"]],
            )
            for row in rolled:
                bump(_js.number(row["value"]), row)
            w = SqlStore._within(plan["rest"])
            raw = self.db.all(
                f"""SELECT {div(dialect, "s.started_at", 900000)} AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
           SUM(s.pageviews) AS pageviews, SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced
         FROM rl_sessions s WHERE s.site = ? AND {w['sql']} AND {IS_VISIT} GROUP BY 1""",
                [query["site"], *w["params"]],
            )
            for row in raw:
                bump(_floor(num(row["quarter"])), row)
            return list(sums.values())
        matching = visit_scope(query["filters"], query["site"], query["from"], query["to"], dialect)
        # A page filter counts that page's views as pageviews here too, as the cards do.
        pv = pageviews_of(query["filters"], query["site"], query["from"], query["to"], dialect)
        rows = self.db.all(
            f"""SELECT {div(dialect, "s.started_at", 900000)} AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
         SUM({"COALESCE(pv.n, 0)" if pv else "s.pageviews"}) AS pageviews, SUM(CASE WHEN {BOUNCE} THEN 1 ELSE 0 END) AS bounced
       FROM rl_sessions s {f"LEFT JOIN {pv['sql']} pv ON pv.session = s.id" if pv else ""}
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{matching['sql']}
       GROUP BY 1""",
            [*(pv["params"] if pv else []), query["site"], query["from"], query["to"], *matching["params"]],
        )
        return [
            {
                "quarter": _floor(num(r["quarter"])),
                "visits": num(r["visits"]),
                "visitors": num(r["visitors"]),
                "pageviews": num(r.get("pageviews")),
                "bounced": num(r.get("bounced")),
            }
            for r in rows
        ]

    def realtime(self, site: str, now: int) -> dict[str, Any]:
        since = now - 5 * 60_000
        active = self.db.all(
            "SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')",
            [site, since],
        )
        pages = self.db.all(
            f"""SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, path{self._text_order} LIMIT 10""",
            [site, since],
        )
        sources = self.db.all(
            f"""SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''
       GROUP BY s.source ORDER BY visitors DESC, s.source{self._text_order} LIMIT 10""",
            [site, since],
        )
        start = (now // 60_000) * 60_000 - 29 * 60_000
        per_minute = self.db.all(
            f"""SELECT {div(self.db.dialect(), "(ts - ?)", 60000)} AS m, COUNT(*) AS n FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1""",
            [start, site, start],
        )
        minutes: list[int | float] = [0] * 30
        for row in per_minute:
            index = _floor(num(row["m"]))
            if 0 <= index < 30:
                minutes[int(index)] += num(row["n"])
        countries = self.db.all(
            f"""SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''
       GROUP BY s.country ORDER BY visitors DESC, s.country{self._text_order} LIMIT 10""",
            [site, since],
        )
        recent = self.db.all(
            """SELECT e.ts, e.kind, e.path, e.name, s.country, s.city, s.source, s.device FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC, e.id DESC LIMIT 20""",
            [site, start],
        )

        def pairs(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
            return [{"value": _string(r["value"]), "visitors": num(r["visitors"])} for r in rows]

        return {
            "visitors": num(active[0].get("n") if active else None),
            "pages": pairs(pages),
            "sources": pairs(sources),
            "countries": pairs(countries),
            "minutes": minutes,
            "recent": [
                {
                    "ts": num(r["ts"]),
                    "kind": _string(r["kind"]),
                    "path": _string(_or(r.get("path"), "")),
                    "name": _string(_or(r.get("name"), "")),
                    "country": _string(_or(r.get("country"), "")),
                    "city": _string(_or(r.get("city"), "")),
                    "source": _string(_or(r.get("source"), "")),
                    "device": _string(_or(r.get("device"), "")),
                }
                for r in recent
            ],
        }


_INDEX_HEAD = re.compile(r"^CREATE (UNIQUE )?INDEX IF NOT EXISTS")


def _sign(n: int | float) -> int:
    return -1 if n < 0 else 1 if n > 0 else 0


def _floor(n: int | float) -> int | float:
    """Math.floor."""
    import math

    return math.floor(n) if isinstance(n, float) and math.isfinite(n) else n
