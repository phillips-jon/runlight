"""Helpers for the store tests: visits written through the store as the tracker writes them, a Db that lets a test
watch every statement, and the queries the tests ask (PHP tests/Store/Seed.php, WatchedDb.php, StoreTestCase.php)."""

from __future__ import annotations

import calendar
import os
import shutil
import subprocess
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from runlight.store import SqlStore, Stores

DAY = 86_400_000
HOUR = 3_600_000
MIN = 60_000

# Date.UTC(2026, 9, 6, 12), the clock the TypeScript tests start from.
NOW = 1_791_288_000_000

ROOT = Path(__file__).resolve().parents[4]


def utc(year: int, month: int, day: int, hour: int = 0) -> int:
    """Date.UTC, with months from 1."""
    return calendar.timegm((year, month, day, hour, 0, 0)) * 1000


def utc_date(ms: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ms // 1000))


def store(databases: Any, kind: str, timezone: str = "UTC") -> SqlStore:
    """A fresh store with its tables and the site "default" in UTC."""
    s = Stores.from_db(databases.db(kind))
    s.migrate()
    s.upsert_site({"id": "default", "name": "Example", "hostnames": ["example.com"], "timezone": timezone}, NOW)
    return s


def q(from_: int, to: int, *filters: tuple[str, str, str]) -> dict[str, Any]:
    """A query over a range, with filters given as (dimension, op, value)."""
    return {"site": "default", "from": from_, "to": to, "filters": [{"dimension": d, "op": op, "value": v} for d, op, v in filters]}


def today(*filters: tuple[str, str, str]) -> dict[str, Any]:
    """The UTC day holding NOW, as a query."""
    return q(NOW - 12 * HOUR, NOW + 12 * HOUR, *filters)


def goal(id: str, **fields: Any) -> dict[str, Any]:
    return {
        "id": id, "site": "default", "name": id, "kind": "event", "match": "", "clickBy": "", "valueMode": "none", "value": 0,
        "valueProp": "", "currency": "USD", "createdAt": 0, **fields,
    }  # fmt: skip


def event(**fields: Any) -> dict[str, Any]:
    """An EventRow with every field empty but those given."""
    return {
        "site": "default", "ts": 0, "kind": "event", "visitor": "", "session": "", "pageview": "", "path": "", "hostname": "",
        "title": "", "name": "", "props": None, "engagedMs": 0, "scroll": None, "link": "", **fields,
    }  # fmt: skip


def visit(s: SqlStore, id: str, visitor: str, started_at: int, fields: dict[str, Any] | None = None, rows: list[tuple] | None = None, site: str = "default") -> None:
    """A session with its fields, then its rows in order. A row is one of:
    ("pageview", path, ts, pageview_id[, hostname]), ("event", name, ts, props | None[, path]),
    ("engagement", pageview_id, ts, ms, scroll | None)."""
    fields = fields or {}
    s.insert_session(
        {
            "id": id, "site": site, "visitor": visitor, "startedAt": started_at, "hostname": "example.com", "referrerHost": "", "referrerPath": "",
            "source": "", "channel": "Direct", "utmSource": "", "utmMedium": "", "utmCampaign": "", "utmTerm": "", "utmContent": "",
            "country": "", "region": "", "city": "", "browser": "Chrome", "browserVersion": "129", "os": "macOS", "osVersion": "", "device": "Desktop",
            "screen": "", "language": "en", **fields,
        }  # fmt: skip
    )
    paths: dict[str, str] = {}
    last = "/"
    for row in rows or []:
        base = event(site=site, visitor=visitor, session=id, path=last, hostname=fields.get("hostname", "example.com"))
        if row[0] == "pageview":
            _, path, ts, pv = row[:4]
            paths[pv] = path
            last = path
            s.insert_event({**base, "ts": ts, "kind": "pageview", "pageview": pv, "path": path, "hostname": row[4] if len(row) > 4 else base["hostname"], "title": f"Title {path}"[:500]})
            s.touch_session(id, ts, "pageview", path)
        elif row[0] == "event":
            _, name, ts, props = row[:4]
            at = row[4] if len(row) > 4 else last
            s.insert_event({**base, "ts": ts, "kind": "event", "name": name, "props": props, "path": at})
            s.touch_session(id, ts, "event", at)
        else:
            _, pv, ts, ms, scroll = row
            s.insert_event({**base, "ts": ts, "kind": "engagement", "pageview": pv, "path": paths.get(pv, last), "engagedMs": ms, "scroll": scroll})
            s.add_engagement(id, ms)


def build_days(s: SqlStore, site: str, from_: int, before: int) -> int:
    """A site's days built as the core builds them, a UTC day at a time, for every whole day before `before`."""
    built = 0
    day = from_ // DAY * DAY
    while day + DAY <= before:
        s.build_rollup_day(site, utc_date(day), day, day + DAY)
        built += 1
        day += DAY
    return built


class WatchedDb:
    """A Db that lets a test see, and step into, every statement: as the TypeScript tests replace db.run and db.all
    on a store. Statements inside a transaction or lock go through it too."""

    def __init__(self, inner: Any) -> None:
        self.inner = inner
        self.before: Callable[[str, list[Any]], None] | None = None
        self.after_run: Callable[[str, list[Any]], None] | None = None

    def dialect(self) -> str:
        return self.inner.dialect()

    def all(self, sql: str, params: Any = ()) -> list[dict[str, Any]]:
        if self.before:
            self.before(sql, list(params))
        return self.inner.all(sql, params)

    def run(self, sql: str, params: Any = ()) -> None:
        if self.before:
            self.before(sql, list(params))
        self.inner.run(sql, params)
        if self.after_run:
            self.after_run(sql, list(params))

    def affected(self, sql: str, params: Any = ()) -> int:
        if self.before:
            self.before(sql, list(params))
        return self.inner.affected(sql, params)

    def transaction(self, fn: Callable[[Any], Any]) -> Any:
        return self.inner.transaction(lambda _: fn(self))

    def exclusive(self, fn: Callable[[Any], Any]) -> Any:
        return self.inner.exclusive(lambda _: fn(self))

    def close(self) -> None:
        self.inner.close()


def node() -> str | None:
    """node 22 or later on the PATH (or RUNLIGHT_NODE), with tsx installed at the repository root."""
    if not (ROOT / "node_modules" / "tsx").is_dir():
        return None
    for candidate in [os.environ.get("RUNLIGHT_NODE"), shutil.which("node"), "/Users/joncphillips/.nvm/versions/node/v24.14.1/bin/node"]:
        if not candidate or not os.path.exists(candidate):
            continue
        try:
            version = subprocess.run([candidate, "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
        except OSError:
            continue
        if version.startswith("v") and int(version[1:].split(".")[0]) >= 22:
            return candidate
    return None


def node_store(binary: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    """scripts/php-fixtures-store.mts with these arguments: the TypeScript store, run over a database."""
    return subprocess.run([binary, "--import", "tsx", "scripts/php-fixtures-store.mts", *args], capture_output=True, text=True, cwd=ROOT, timeout=600)


def everything(s: SqlStore) -> list[dict[str, Any]]:
    """A database with a bit of everything, written through the Python store, and the reads to compare over it, with
    the TypeScript method names."""
    s.migrate()
    now = utc(2026, 10, 6, 12)
    s.upsert_site({"id": "default", "name": "Example", "hostnames": ["example.com"], "timezone": "UTC"}, now)
    s.upsert_site({"id": "b", "name": "Bee", "hostnames": [], "timezone": "Asia/Tokyo"}, now)
    s.set_site_overrides("b", {"name": "Renamed"})
    pages = ["/", "/pricing", "/blog/one", "/caf%C3%A9", "/%C3%9Cber-uns", "/thanks", "/#/cart"]
    countries = ["GB", "US", "DE", "FR"]
    campaigns = ["alpha", "Zeta", "émile", "Émile", "a-b", "ab", ""]
    n = 0
    for day in range(9, -1, -1):
        for v in range(5):
            n += 1
            start = now - day * DAY - 10 * HOUR + v * 2 * HOUR + n * 1000
            rows: list[tuple] = []
            t = start
            for p in range(1 + n % 3):
                rows.append(("pageview", pages[(n + p) % len(pages)], t, f"pv{n}x{p}"))
                if n % 2 == 0:
                    rows.append(("engagement", f"pv{n}x{p}", t + 5000, 8000 + n * 100, 30 + n % 50 if n % 3 else None))
                if n % 3 == 0:
                    rows.append(("event", "Signup", t + 6000, {"plan": "pro" if n % 2 else "team", "amount": f"{5 + n % 4}.5"}))
                t += 30_000
            visit(s, f"s{n}", f"v{n % 17}", start, {
                "country": countries[n % 4], "source": "Google" if n % 2 else "", "channel": "Search" if n % 2 else "Direct",
                "utmCampaign": campaigns[n % len(campaigns)], "device": "Desktop" if n % 3 else "Mobile", "browser": "Chrome" if n % 4 else "Safari",
            }, rows)  # fmt: skip
    s.save_goal({"id": "a" * 24, "site": "default", "name": "Signup", "kind": "event", "match": "Signup", "clickBy": "", "valueMode": "prop", "value": 0, "valueProp": "amount", "currency": "USD", "createdAt": now})
    s.save_goal({"id": "b" * 24, "site": "default", "name": "Thanks", "kind": "page", "match": "/th*", "clickBy": "", "valueMode": "fixed", "value": 4.25, "valueProp": "", "currency": "EUR", "createdAt": now})
    s.save_goal({"id": "c" * 24, "site": "default", "name": "Cart", "kind": "page", "match": "/#/cart", "clickBy": "", "valueMode": "none", "value": 0, "valueProp": "", "currency": "USD", "createdAt": now})
    s.save_funnel({"id": "f" * 24, "site": "default", "name": "F", "steps": [{"kind": "page", "match": "/"}, {"kind": "page", "match": "/pricing"}, {"kind": "event", "match": "Signup"}], "createdAt": now})
    s.insert_link({"id": "l" * 24, "site": "default", "domain": "", "slug": "go", "name": "Go", "url": "https://example.com/", "createdAt": now - DAY, "updatedAt": now - DAY})
    s.add_link_domain("go.example.com", "default", now)
    for i in range(6):
        s.insert_event(event(ts=now - i * 7 * HOUR, kind="click", visitor=f"cv{i}" if i % 2 else "", link="l" * 24))
        s.insert_event(event(ts=now - i * 5 * HOUR, kind="fetch", path=pages[i % 3], hostname="example.com", name="GPTBot" if i % 2 else "ClaudeBot", props={"company": "X"}))
    s.insert_share({"id": "s" * 24, "site": "default", "name": "Client", "createdAt": now})
    s.insert_token({"id": "k" * 24, "name": "Script", "site": "", "scope": "manage", "hash": "h" * 64, "hint": "abcd", "createdAt": now, "lastUsedAt": None})
    s.insert_report({"id": "r" * 24, "site": "default", "email": "a@example.com", "frequency": "weekly", "lang": "en", "token": "q" * 32, "origin": "", "lastPeriod": "", "lastSentAt": None, "createdAt": now})
    s.set_setting("remote:a", "1")
    s.salt("2026-10-06", "9" * 64)
    build_days(s, "default", now - 7 * DAY, now - 3 * DAY)

    calls: list[dict[str, Any]] = []

    def add(method: str, *args: Any) -> None:
        calls.append({"method": method, "args": list(args)})

    add("sites")
    add("siteOverrides")
    add("rollupDays", "default")
    filters: list[list[dict[str, str]]] = [
        [],
        [{"dimension": "country", "op": "is", "value": "GB"}],
        [{"dimension": "page", "op": "contains", "value": "über"}],
        [{"dimension": "event", "op": "not", "value": "Signup"}],
        [{"dimension": "utm_campaign", "op": "contains", "value": "ÉMILE"}],
    ]
    for from_, to in ((now - 8 * DAY, now + DAY), (now - 5 * DAY - 3 * HOUR, now - DAY)):
        for f in filters:
            query = {"site": "default", "from": from_, "to": to, "filters": f}
            add("stats", query)
            add("hourly", query)
            for dimension in ("page", "hostname", "event", "entry", "exit", "source", "channel", "utm_campaign", "country", "device", "browser", "ai_agent", "ai_page"):
                add("breakdown", query, dimension, 5, 0)
            add("goalTotalsAll", query, s.goals("default"))
            add("funnelCounts", query, s.funnels("default")[0])
            add("journeyPages", query, 3)
            add("eventPropKeys", query, "Signup")
            add("eventPropValues", query, "Signup", "plan", 5)
            for g in s.goals("default"):
                add("goalBreakdown", query, g, "path", 5)
        add("links", "default", from_, to)
    buckets = [{"start": now - (11 - i) * DAY, "end": now - (10 - i) * DAY} for i in range(12)]
    for f in filters:
        add("series", {"site": "default", "filters": f}, buckets)
        add("goalSeries", {"site": "default", "filters": f}, s.goals("default")[0], buckets)
    add("linkSeries", "default", "l" * 24, buckets)
    add("realtime", "default", now - 9 * HOUR)
    add("goals")
    add("funnels", "default")
    add("linkBySlug", "go")
    add("linkDomains")
    add("shares", "default")
    add("tokens")
    add("reports")
    add("settingsStartingWith", "remote:")
    add("saltIfExists", "2026-10-06")
    add("pageview", "default", "pv3x1")
    return calls


def snake(name: str) -> str:
    """A TypeScript method name as this port names it: goalTotalsAll as goal_totals_all."""
    return "".join(f"_{c.lower()}" if c.isupper() else c for c in name)


def answer(s: SqlStore, call: dict[str, Any]) -> Any:
    """A read's answer in JSON's terms, as the TypeScript script writes it: a Set as a sorted list."""
    result = getattr(s, snake(call["method"]))(*call["args"])
    if call["method"] == "rollupDays":
        result = sorted(result)
    return result
