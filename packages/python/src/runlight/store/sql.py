"""The SQL that store.ts builds outside its class: the schema, filters as conditions, and the small pieces every
report shares. Each statement is the TypeScript one, for each dialect ("sqlite", "postgres", "mysql"), so one
database serves either implementation.

A filter is {"dimension", "op", "value"}. A piece of SQL with its values is {"sql", "params"}.
"""

from __future__ import annotations

import math
import re
import unicodedata
from collections.abc import Callable, Sequence
from typing import Any, TypeVar

from .. import _js
from ..query import EVENT_DIMENSIONS, SESSION_DIMENSIONS, is_session_dimension
from ..sources import recorded_path

T = TypeVar("T")
R = TypeVar("R")

# A session's bounce: one page, nothing clicked that was tracked, under ten seconds engaged.
BOUNCE_MS = 10_000
BOUNCE = f"(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < {BOUNCE_MS}))"
VISIT_KINDS = "e.kind IN ('pageview', 'event')"
# Cloudflare D1 takes at most 100 bound parameters a statement, so lists that grow with the range (chart
# buckets, values) go in pieces, and built days are chosen by their dates.
BUCKETS_PER_QUERY = 30
VALUES_PER_QUERY = 50
# The most values one statement binds: D1's 100, less a little.
MAX_PARAMS = 96
# The built days inside a range, as a subquery taking (site, from, to).
BUILT_DAYS = "SELECT day FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ?"

# The most visits journeys reads, newest first.
JOURNEY_VISITS = 20_000

# How long after a visit starts its events are looked for: far past any real visit.
EVENT_TAIL_MS = 2 * 86_400_000

PIECE_MS = 86_400_000

# Pageviews that can report engaged time: the tracker's, which carry a pageview id. Imported history has none,
# so time on page is the mean over these, counting a view that reported nothing (under a second) as none.
LIVE_VIEWS = "SUM(CASE WHEN e.pageview <> '' THEN 1 ELSE 0 END)"

# A session that is a visit: a short link click alone opens one that is not.
IS_VISIT = "(s.pageviews > 0 OR s.events > 0)"

# Engaged time, or for imported visits with none, first to last request.
DURATION = "COALESCE(s.engaged_ms, s.last_at - s.started_at)"

SCHEMA_VERSION = 11

# MySQL's text collation: UTF-8 compared and sorted by code point, case and trailing spaces included, as SQLite
# and Postgres's "C" collation do. MariaDB has it too, from 11.4.
MYSQL_COLLATION = "utf8mb4_0900_bin"

_PATH_DIMENSIONS = {"page", "entry", "exit"}


def code_order(a: str, b: str) -> int:
    """Orders text by code point, as SQLite and Postgres's "C" collation do (JavaScript's < compares UTF-16 units).
    Python compares str by code point already."""
    return -1 if a < b else 1 if a > b else 0


def in_pieces(items: Sequence[T], size: int, run: Callable[[list[T]], list[R]]) -> list[R]:
    """Runs a query over pieces of a list and joins the answers, in order."""
    out: list[R] = []
    for i in range(0, len(items), size):
        out.extend(run(list(items[i : i + size])))
    return out


def schema(dialect: str) -> list[str]:
    my = dialect == "mysql"
    id_ = "BIGSERIAL PRIMARY KEY" if dialect == "postgres" else "BIGINT AUTO_INCREMENT PRIMARY KEY" if my else "INTEGER PRIMARY KEY AUTOINCREMENT"

    # MySQL keys and indexes TEXT only by a prefix, so there a column that is keyed, indexed, grouped, or
    # sorted is VARCHAR, sized past anything Runlight writes to it. Elsewhere text is text.
    def str_(n: int) -> str:
        return f"VARCHAR({n})" if my else "TEXT"

    def text(n: int) -> str:
        return f"{str_(n)} NOT NULL DEFAULT ''"

    # Free text that is never keyed. MySQL takes a default for it only as an expression.
    def long(fallback: str) -> str:
        return f"MEDIUMTEXT NOT NULL DEFAULT ('{fallback}')" if my else f"TEXT NOT NULL DEFAULT '{fallback}'"

    table = f" DEFAULT CHARSET=utf8mb4 COLLATE={MYSQL_COLLATION}" if my else ""
    site = str_(100)
    key = str_(100)
    path = 1000
    medium = "MEDIUMTEXT" if my else "TEXT"
    return [
        f'CREATE TABLE IF NOT EXISTS rl_meta ("key" {str_(100)} PRIMARY KEY, value {medium} NOT NULL){table}',
        f"""CREATE TABLE IF NOT EXISTS rl_sites (
      id {site} PRIMARY KEY, name {text(200)}, hostnames {long("[]")},
      timezone {str_(64)} NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL,
      overrides {long("{}")}){table}""",
        f"CREATE TABLE IF NOT EXISTS rl_salts (day {str_(32)} PRIMARY KEY, salt {str_(255)} NOT NULL){table}",
        f"""CREATE TABLE IF NOT EXISTS rl_sessions (
      id {key} PRIMARY KEY, site {site} NOT NULL, visitor {key} NOT NULL,
      started_at BIGINT NOT NULL, last_at BIGINT NOT NULL,
      entry_path {text(path)}, exit_path {text(path)},
      pageviews INTEGER NOT NULL DEFAULT 0, events INTEGER NOT NULL DEFAULT 0,
      engaged_ms BIGINT, imported INTEGER NOT NULL DEFAULT 0,
      hostname {text(255)}, referrer_host {text(255)}, referrer_path {text(500)},
      source {text(200)}, channel {text(100)},
      utm_source {text(200)}, utm_medium {text(200)}, utm_campaign {text(200)}, utm_term {text(200)}, utm_content {text(200)},
      country {text(16)}, region {text(100)}, city {text(100)},
      browser {text(100)}, browser_version {text(100)}, os {text(100)}, os_version {text(100)},
      device {text(50)}, screen {text(50)}, language {text(50)}){table}""",
        "CREATE INDEX IF NOT EXISTS rl_sessions_site_started ON rl_sessions (site, started_at)",
        # MySQL takes an index that leads with the site as a way to read all of a site's rows, even where a
        # range of time would read far fewer, so there an index for looking a value up leads with that value.
        f"CREATE INDEX IF NOT EXISTS rl_sessions_visitor ON rl_sessions ({'visitor, site' if my else 'site, visitor'}, last_at)",
        f"""CREATE TABLE IF NOT EXISTS rl_events (
      id {id_}, site {site} NOT NULL, ts BIGINT NOT NULL, kind {str_(20)} NOT NULL,
      visitor {text(100)}, session {text(100)}, pageview {text(100)},
      path {text(path)}, hostname {text(255)}, title {text(500)}, name {text(255)}, props {medium},
      engaged_ms BIGINT NOT NULL DEFAULT 0, scroll INTEGER, link {text(100)}){table}""",
        "CREATE INDEX IF NOT EXISTS rl_events_site_ts ON rl_events (site, ts)",
        # Goals and events read one kind of row in a range; created on start for older databases too.
        "CREATE INDEX IF NOT EXISTS rl_events_site_kind_ts ON rl_events (site, kind, ts)",
        f"CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events ({'pageview, site' if my else 'site, pageview'})",
        # Page and event filters find the visits they pick through these, rather than reading every row in the
        # range. MySQL indexes the first 255 characters of a path, which is enough to find it.
        f"CREATE INDEX IF NOT EXISTS rl_events_site_path ON rl_events ({'path(255), site' if my else 'site, path'}, ts)",
        # MySQL has no partial index, so its index of event names holds the kind too.
        "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (name, site, kind, ts)"
        if my
        else "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (site, name, ts) WHERE kind = 'event'",
        # Version 3: short links; "" is the app's own domain. Version 4: a slug is unique across every domain, so
        # a link whose domain is removed can fall back to the app's own link path without colliding with another.
        # MySQL has no partial index, so there a generated column holds the slug of a live link only, and is
        # unique.
        f"""CREATE TABLE IF NOT EXISTS rl_links (
      id {key} PRIMARY KEY, site {site} NOT NULL, domain {text(255)}, slug {str_(255)} NOT NULL,
      name {text(255)}, url {str_(4000)} NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
      deleted_at BIGINT{", live_slug VARCHAR(255) AS (CASE WHEN deleted_at IS NULL THEN slug END) VIRTUAL" if my else ""}){table}""",
        "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (live_slug)"
        if my
        else "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (slug) WHERE deleted_at IS NULL",
        "CREATE INDEX IF NOT EXISTS rl_events_link ON rl_events (link, ts)",
        f"CREATE TABLE IF NOT EXISTS rl_link_domains (domain {str_(255)} PRIMARY KEY, site {site} NOT NULL, created_at BIGINT NOT NULL){table}",
        # Version 5: share links.
        f"CREATE TABLE IF NOT EXISTS rl_shares (id {key} PRIMARY KEY, site {site} NOT NULL, name {text(255)}, created_at BIGINT NOT NULL){table}",
        # Version 6: goals.
        f"""CREATE TABLE IF NOT EXISTS rl_goals (
      id {key} PRIMARY KEY, site {site} NOT NULL, name {str_(255)} NOT NULL, kind {str_(20)} NOT NULL, "match" {str_(1000)} NOT NULL,
      click_by {text(20)}, value_mode {str_(20)} NOT NULL DEFAULT 'none', value {"DOUBLE" if my else "REAL"} NOT NULL DEFAULT 0,
      value_prop {text(255)}, currency {str_(10)} NOT NULL DEFAULT 'USD', created_at BIGINT NOT NULL){table}""",
        # Version 7: install-wide settings (the mail service) and email report subscriptions.
        f'CREATE TABLE IF NOT EXISTS rl_settings ("key" {str_(255)} PRIMARY KEY, value {medium} NOT NULL){table}',
        f"""CREATE TABLE IF NOT EXISTS rl_reports (
      id {key} PRIMARY KEY, site {site} NOT NULL, email {str_(320)} NOT NULL, frequency {str_(20)} NOT NULL,
      lang {str_(20)} NOT NULL DEFAULT 'en', token {str_(128)} NOT NULL, origin {text(500)},
      last_period {text(40)}, last_sent_at BIGINT, created_at BIGINT NOT NULL){table}""",
        "CREATE UNIQUE INDEX IF NOT EXISTS rl_reports_token ON rl_reports (token)",
        # Version 8: read-only API tokens, for scripts and AI assistants over MCP.
        f"""CREATE TABLE IF NOT EXISTS rl_tokens (
      id {key} PRIMARY KEY, name {str_(255)} NOT NULL, site {text(100)}, hash {str_(128)} NOT NULL, hint {text(20)},
      created_at BIGINT NOT NULL, last_used_at BIGINT, scope {str_(20)} NOT NULL DEFAULT 'read'){table}""",
        "CREATE UNIQUE INDEX IF NOT EXISTS rl_tokens_hash ON rl_tokens (hash)",
        # Version 9: funnels.
        f"CREATE TABLE IF NOT EXISTS rl_funnels (id {key} PRIMARY KEY, site {site} NOT NULL, name {str_(255)} NOT NULL, steps {medium} NOT NULL, created_at BIGINT NOT NULL){table}",
        # Version 11: daily rollups. A day is the site's own local day; rl_rollup_days says which days are built
        # and where they begin and end.
        f"CREATE TABLE IF NOT EXISTS rl_rollup_days (site {site} NOT NULL, day {str_(32)} NOT NULL, start_at BIGINT NOT NULL, end_at BIGINT NOT NULL, PRIMARY KEY (site, day)){table}",
        "CREATE INDEX IF NOT EXISTS rl_rollup_days_range ON rl_rollup_days (site, start_at)",
        # A value can be a whole path, longer than MySQL's keys allow, so there the rows of a day are found by an
        # index without it; a day's rows are only ever written all at once.
        f"""CREATE TABLE IF NOT EXISTS rl_rollups (
      site {site} NOT NULL, day {str_(32)} NOT NULL, dim {str_(32)} NOT NULL, value {text(path)},
      visitors BIGINT NOT NULL DEFAULT 0, visits BIGINT NOT NULL DEFAULT 0, pageviews BIGINT NOT NULL DEFAULT 0,
      bounced BIGINT NOT NULL DEFAULT 0, duration BIGINT NOT NULL DEFAULT 0,
      engaged BIGINT NOT NULL DEFAULT 0, views BIGINT NOT NULL DEFAULT 0, scroll_sum BIGINT NOT NULL DEFAULT 0, scroll_n BIGINT NOT NULL DEFAULT 0,
      events BIGINT NOT NULL DEFAULT 0,
      {"KEY rl_rollups_day (site, dim, day)" if my else "PRIMARY KEY (site, dim, day, value)"}){table}""",
    ]


def num(value: Any) -> int | float:
    """Number(value ?? 0), or 0 when that is not finite."""
    n = _js.number(0 if value is None else value)
    if isinstance(n, float) and not math.isfinite(n):
        return 0
    return n


def _text(value: Any) -> str:
    """String(value), as TS reads a column."""
    return _js.string(value)


def goal_row(r: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": _text(r["id"]),
        "site": _text(r["site"]),
        "name": _text(r["name"]),
        "kind": _text(r["kind"]),
        "match": _text(r["match"]),
        "clickBy": _text(r.get("click_by") if r.get("click_by") is not None else ""),
        "valueMode": _text(r["value_mode"]),
        "value": _js.number(r.get("value") if r.get("value") is not None else 0),
        "valueProp": _text(r.get("value_prop") if r.get("value_prop") is not None else ""),
        "currency": _text(r.get("currency") if r.get("currency") is not None else "USD"),
        "createdAt": _js.number(r["created_at"]),
    }


def link_row(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": _text(row["id"]),
        "site": _text(row["site"]),
        "domain": _text(row.get("domain") if row.get("domain") is not None else ""),
        "slug": _text(row["slug"]),
        "name": _text(row.get("name") if row.get("name") is not None else ""),
        "url": _text(row["url"]),
        "createdAt": _js.number(row["created_at"]),
        "updatedAt": _js.number(row["updated_at"]),
    }


def glob_pattern(pattern: str) -> str:
    """A `*` pattern as SQLite GLOB, everything else taken literally ([ and ? are GLOB's own)."""
    return "*".join(re.sub(r"[\[?]", lambda m: f"[{m.group(0)}]", part) for part in pattern.split("*"))


def escape_like(value: str) -> str:
    return re.sub(r"[\\%_]", lambda m: "\\" + m.group(0), value)


def like_pattern(pattern: str) -> str:
    """A `*` pattern as SQL LIKE, everything else taken literally."""
    return "%".join(escape_like(part) for part in pattern.split("*"))


def upsert(dialect: str, table: str, columns: list[str], key: list[str], update: list[str]) -> str:
    """An INSERT that updates the row already there with the same key, or with `update` empty leaves it be. MySQL
    says it its own way, and has no other unique key on these tables to trip over."""
    insert = f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join('?' for _ in columns)})"
    if dialect == "mysql":
        sets = ", ".join(f"{c} = {f'VALUES({c})' if update else c}" for c in (update or [key[0]]))
        return f"{insert} ON DUPLICATE KEY UPDATE {sets}"
    action = f"UPDATE SET {', '.join(f'{c} = excluded.{c}' for c in update)}" if update else "NOTHING"
    return f"{insert} ON CONFLICT ({', '.join(key)}) DO {action}"


def div(dialect: str, a: str, b: int) -> str:
    """Whole-number division, which MySQL's `/` is not."""
    return f"({a} DIV {b})" if dialect == "mysql" else f"({a} / {b})"


def as_text(dialect: str, value: str) -> str:
    """A value as text: MySQL casts to CHAR, and has no TEXT type to cast to."""
    return f"CAST({value} AS {'CHAR' if dialect == 'mysql' else 'TEXT'})"


def bucket_table(dialect: str, buckets: Sequence[Any]) -> str:
    """A table of buckets (i, bs, be) for a WITH clause. Postgres is told the first row's types; MySQL and MariaDB
    write a table of values differently from each other, so they get a UNION of rows."""
    if dialect == "mysql":
        return " UNION ALL ".join("SELECT ? AS i, ? AS bs, ? AS be" if i == 0 else "SELECT ?, ?, ?" for i in range(len(buckets)))
    cast = dialect == "postgres"
    rows = ("(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))" if cast and i == 0 else "(?, ?, ?)" for i in range(len(buckets)))
    return f"VALUES {', '.join(rows)}"


def column(dimension: str) -> str:
    return f"s.{SESSION_DIMENSIONS[dimension]}" if is_session_dimension(dimension) else f"e.{EVENT_DIMENSIONS[dimension]}"


def as_recorded(value: str, whole: bool) -> str:
    """Text in the form a recorded path holds it, percent-encoded, as part of a path or as a whole one."""
    rooted = whole or value.startswith("/")
    path = recorded_path(value if rooted else f"/{value}")
    if path is None:
        return value
    return path if rooted else path[1:]


def any_case(value: str) -> str:
    """A GLOB pattern for text containing `value` in any mix of upper and lower case, letter by letter."""
    out = "*"
    for ch in value:
        lower = ch.lower()
        upper = ch.upper()
        if lower != upper and len(lower) == 1 and len(upper) == 1:
            out += f"[{lower}{upper}]"
        else:
            out += f"[{ch}]" if ch in ("*", "?", "[") else ch
    return f"{out}*"


def _title(value: str) -> str:
    """value.replace(/(^|[\\s\\-/_.])(\\p{L})/gu, gap + letter.toUpperCase()): each letter at the start or after
    white space, a dash, a slash, an underscore, or a dot, in upper case."""
    out = []
    for i, ch in enumerate(value):
        if (i == 0 or value[i - 1] in "-/_." or _js.SPACE.match(value[i - 1])) and unicodedata.category(ch).startswith("L"):
            out.append(ch.upper())
        else:
            out.append(ch)
    return "".join(out)


def condition(filter: dict[str, Any], dialect: str, positive: bool = False) -> dict[str, Any]:
    """One filter as a condition on its own column, with "is not" flipped to "is" when `positive` asks."""
    col = column(filter["dimension"])
    op = "is" if positive and filter["op"] == "not" else filter["op"]
    value = filter["value"]
    # Paths are recorded percent-encoded, as the browser's URL parser writes them, so "/café" is matched as
    # "/caf%C3%A9", just as a goal for it is.
    path = filter["dimension"] in _PATH_DIMENSIONS
    if op in ("is", "not"):
        return {"sql": f"{col} {'=' if op == 'is' else '<>'} ?", "params": [as_recorded(value, True) if path else value]}
    if path:
        # An encoded letter's case is in its bytes (%C3%9C is Ü, %C3%BC is ü), which no database folds, so a
        # path is also tried in lower, upper, and title case, encoded each way.
        title = _title(value.lower())
        forms = list(dict.fromkeys(as_recorded(f, False) for f in (value, value.lower(), value.upper(), title)))
        lower = dialect != "sqlite"
        one = f"LOWER({col}) LIKE ? ESCAPE '\\'" if lower else f"{col} LIKE ? ESCAPE '\\'"
        return {
            "sql": f"({' OR '.join(one for _ in forms)})",
            "params": [f"%{escape_like(f.lower() if lower else f)}%" for f in forms],
        }
    # Postgres and MySQL lower case any letter, so both sides lowered find any mix. Their LIKE then compares
    # exactly: Postgres's always, MySQL's under Runlight's binary collation.
    if dialect != "sqlite":
        return {"sql": f"LOWER({col}) LIKE ? ESCAPE '\\'", "params": [f"%{escape_like(value.lower())}%"]}
    # SQLite's LIKE and LOWER ignore case for ASCII letters only, so "über" would never find "Über". GLOB with
    # both cases of every letter finds any mix, Unicode included.
    return {"sql": f"{col} GLOB ?", "params": [any_case(value)]}


def visit_scope(filters: list[dict[str, Any]], site: str, from_: int, to: int, dialect: str) -> dict[str, Any]:
    """The visits a query's filters pick, as conditions on `s`. A filter on the visit (source, country, entry page)
    applies to it directly. A filter on a page, hostname, or event picks the visits that had a matching row, or
    for "is not", that never had one. Every number then describes those whole visits, and a visit belongs to the
    range it started in, as it does with no filter. Rows count up to EVENT_TAIL_MS past the range, for a visit
    still going when it ends."""
    parts: list[str] = []
    params: list[Any] = []
    for f in filters:
        c = condition(f, dialect, True)
        if is_session_dimension(f["dimension"]):
            own = condition(f, dialect)
            parts.append(own["sql"])
            params.extend(own["params"])
        else:
            # An event filter reads events only, which lets it use the index of event names.
            kinds = "e.kind = 'event'" if f["dimension"] == "event" else VISIT_KINDS
            rows = f"FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND {kinds} AND {c['sql']}"
            # Postgres plans NOT IN over a list too big for its memory as a scan of the list for every visit,
            # which runs for hours, so it gets NOT EXISTS, an anti join. SQLite reads NOT IN through a temporary
            # index, and runs NOT EXISTS once a visit.
            if f["op"] == "not" and dialect == "postgres":
                parts.append(f"NOT EXISTS (SELECT 1 {rows} AND e.session = s.id)")
            else:
                parts.append(f"s.id {'NOT IN' if f['op'] == 'not' else 'IN'} (SELECT e.session {rows})")
            params.extend([site, from_, to + EVENT_TAIL_MS, *c["params"]])
    return {"sql": "".join(f" AND {p}" for p in parts), "params": params}


def row_scope(filters: list[dict[str, Any]], dimensions: list[str], dialect: str) -> dict[str, Any]:
    """Conditions on `e` from the filters on the given row dimensions that keep rows (is, contains). With "page is
    /pricing", pageviews mean views of /pricing, as people expect, while the visits are whole. A row counts when it
    matches any filter on each of its dimensions: two page filters count the views of either page, and a hostname
    filter beside them keeps those on that host."""
    sql = ""
    params: list[Any] = []
    for dimension in dimensions:
        kept = [condition(f, dialect) for f in filters if f["dimension"] == dimension and f["op"] != "not"]
        if not kept:
            continue
        sql += f" AND ({' OR '.join(c['sql'] for c in kept)})"
        for c in kept:
            params.extend(c["params"])
    return {"sql": sql, "params": params}


def pageviews_of(filters: list[dict[str, Any]], site: str, from_: int, to: int, dialect: str) -> dict[str, Any] | None:
    """Pageviews for each visit a filter picks, as a table to LEFT JOIN on `pv.session = s.id`, when a page or
    hostname filter narrows what counts as a pageview. None when every pageview of a visit counts."""
    rows = row_scope(filters, ["page", "hostname"], dialect)
    if not rows["sql"]:
        return None
    return {
        "sql": f"(SELECT e.session AS session, COUNT(*) AS n FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'{rows['sql']} GROUP BY e.session)",
        "params": [site, from_, to + EVENT_TAIL_MS, *rows["params"]],
    }


def visit_rows(filters: list[dict[str, Any]], site: str, from_: int, to: int, dialect: str) -> dict[str, Any]:
    """For reports that count rows (goals, event properties, funnels): the rows of the visits a query picks, as a
    FROM list and conditions over `e` and `s`. These count visits the way every other report does, with or without
    a filter: a visit belongs to the range it started in, and its rows count up to EVENT_TAIL_MS past the range.
    Written as a CROSS JOIN so SQLite reads the events through their (site, kind, ts) index and looks each visit up
    by its id, whatever its statistics say."""
    scope = visit_scope(filters, site, from_, to, dialect)
    return {
        "from": "rl_events e CROSS JOIN rl_sessions s",
        "sql": f"e.site = ? AND e.ts >= ? AND e.ts < ? AND s.id = e.session AND s.site = ? AND s.started_at >= ? AND s.started_at < ? AND {IS_VISIT}{scope['sql']}",
        "params": [site, from_, to + EVENT_TAIL_MS, site, from_, to, *scope["params"]],
    }
