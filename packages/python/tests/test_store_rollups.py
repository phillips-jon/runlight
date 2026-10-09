"""Daily rollups, as rollups.test.ts and counting.test.ts test them at the store (PHP RollupsTest)."""

from __future__ import annotations

import time
from typing import Any

import pytest
from support.databases import kinds
from support.store import DAY, HOUR, MIN, NOW, WatchedDb, build_days, event, q, store, utc, visit

from runlight import _js
from runlight.store import SqlStore

KINDS = kinds()
PAGES = ["/", "/blog/one", "/blog/two", "/pricing", "/about"]
SOURCES = ["Google", "Hacker News", "", "ChatGPT", "Twitter"]
COUNTRIES = ["GB", "US", "DE", "CA"]


def _ten_days(s: SqlStore) -> None:
    """Ten days of visits, some running past midnight, ending two hours before NOW."""
    now = NOW - 10 * DAY
    n = 0
    for _day in range(10):
        for _v in range(6):
            n += 1
            start = now
            rows: list[tuple] = []
            for p in range(1 + n % 3):
                id = f"pv{n}x{p}"
                rows.append(("pageview", PAGES[(n + p) % 5], now, id))
                now += 20_000 + (n % 5) * 7_000
                if n % 2 == 0:
                    rows.append(("engagement", id, now, 9_000 + n * 100, 40 + n % 60))
                if n % 4 == 0:
                    rows.append(("event", "Signup", now, None))
            # Visitor ids change every day, as the daily salt changes them.
            source = SOURCES[n % 5]
            visit(s, f"s{n}", f"v{n % 4}" + time.strftime("%Y%m%d", time.gmtime(start // 1000)), start, {
                "source": source, "channel": "Direct" if source == "" else "Referral", "referrerHost": "" if source == "" else "x.example",
                "country": COUNTRIES[n % 4], "device": "Mobile" if n % 3 == 0 else "Desktop", "browser": "Safari" if n % 3 == 0 else "Chrome",
                "os": "iOS" if n % 3 == 0 else "macOS",
            }, rows)  # fmt: skip
            now += 3 * HOUR + (n % 7) * MIN
        # A visit that runs past midnight belongs to the day it started.
        now += DAY - 6 * (3 * HOUR) - 30 * MIN


def _everything(s: SqlStore) -> dict[str, str]:
    """Every report the dashboard asks the store for, as JSON, for comparing before and after."""
    out: dict[str, Any] = {}
    ranges = {
        "7d": (NOW - 7 * DAY, NOW + DAY),
        "30d": (NOW - 30 * DAY, NOW + DAY),
        "odd": (NOW - 6 * DAY - 5 * HOUR, NOW - 2 * DAY + 3 * HOUR),
        "today": (NOW - 12 * HOUR, NOW + 12 * HOUR),
        "all": (0, NOW + DAY),
    }
    for name, (from_, to) in ranges.items():
        query = q(from_, to)
        out[f"stats {name}"] = s.stats(query)
        buckets = []
        at = NOW - 12 * DAY if from_ == 0 else from_
        while at < to:
            buckets.append({"start": at, "end": min(at + DAY, to)})
            at += DAY
        out[f"series {name}"] = s.series(query, buckets)
        out[f"hourly {name}"] = sorted(s.hourly(query), key=lambda r: r["quarter"])
        for dimension in ("page", "event", "entry", "exit", "source", "channel", "referrer", "country", "browser", "device", "os"):
            out[f"{dimension} {name}"] = s.breakdown(query, dimension, 3, 0)
            out[f"{dimension} {name} page 2"] = s.breakdown(query, dimension, 3, 3)
    out["filtered"] = s.stats(q(NOW - 30 * DAY, NOW + DAY, ("country", "is", "GB")))
    return {k: _js.dumps(v) for k, v in out.items()}


@pytest.mark.parametrize("kind", KINDS)
def test_reports_read_from_daily_rollups_match_reports_read_from_every_visit(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    _ten_days(s)
    before = _everything(s)
    assert build_days(s, "default", NOW - 11 * DAY, NOW) >= 8
    assert len(s.rollup_days("default")) == 11
    after = _everything(s)
    for key, value in before.items():
        assert after[key] == value, key

    # Proof the reports read the rollups: with the built days' raw visits gone, a long range still adds up.
    span = s.db.all("SELECT MIN(start_at) AS s, MAX(end_at) AS e FROM rl_rollup_days")[0]
    s.db.run("DELETE FROM rl_events WHERE ts >= ? AND ts < ?", [int(span["s"]), int(span["e"]) - 2 * HOUR])
    s.db.run("DELETE FROM rl_sessions WHERE started_at >= ? AND started_at < ?", [int(span["s"]), int(span["e"]) - 2 * HOUR])
    again = _everything(s)
    for key in ("stats 30d", "source 30d", "page 30d", "event 30d", "hourly 30d"):
        assert again[key] == before[key], f"{key} comes from rollups"


@pytest.mark.parametrize("kind", KINDS)
def test_a_late_event_and_engagement_on_an_old_pageview_are_counted_once_the_day_is_built_again(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    # Evening of October 5th, then rollups built the next morning.
    start = utc(2026, 10, 5, 20)
    visit(s, "s1", "v1", start, {}, [("pageview", "/", start, "late1")])
    day5 = utc(2026, 10, 5)
    s.build_rollup_day("default", "2026-10-05", day5, day5 + DAY)
    # The tab was left open overnight: its event and engagement arrive now.
    late = start + 7 * HOUR
    s.insert_event(event(ts=late, kind="event", visitor="v1", session="s1", pageview="late1", path="/", hostname="example.com", name="Signup"))
    s.touch_session("s1", late, "event", "/", False)
    s.insert_event(event(ts=late, kind="engagement", visitor="v1", session="s1", pageview="late1", path="/", hostname="example.com", engagedMs=60_000, scroll=80))
    s.add_engagement("s1", 60_000)
    s.touched_old_visit("default", start, late - 2 * HOUR)
    assert s.rollup_days("default") == set(), "the day is forgotten"
    s.touched_old_visit("default", start, start - 1)
    query = q(day5, day5 + DAY)

    def read() -> str:
        return _js.dumps([s.stats(query), s.breakdown(query, "event", 10, 0), s.breakdown(query, "page", 10, 0)])

    s.build_rollup_day("default", "2026-10-05", day5, day5 + DAY)
    rolled = read()
    s.clear_rollups("default")
    assert s.rollup_days("default") == set()
    assert read() == rolled
    assert s.stats(query)["bounceRate"] == 0, "the event means the visit did not bounce"
    assert [r["value"] for r in s.breakdown(query, "event", 10, 0)] == ["Signup"]


@pytest.mark.parametrize("kind", KINDS)
def test_ties_come_in_code_point_order_the_same_before_and_after_the_days_are_built(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    values = ["alpha", "Zeta", "beta", "Gamma", "émile", "Émile", "_x", "a-b", "ab"]
    t = NOW - DAY
    for i, value in enumerate(values):
        visit(s, f"s{i}", f"v{i}", t + i * MIN, {"utmCampaign": value}, [("pageview", "/", t + i * MIN, f"pv{i}")])
    expected = sorted(values)
    week = q(NOW - 7 * DAY, NOW + DAY)
    assert [r["value"] for r in s.breakdown(week, "utm_campaign", 20, 0)] == expected, "read from every visit"
    build_days(s, "default", NOW - 2 * DAY, NOW)
    assert [r["value"] for r in s.breakdown(week, "utm_campaign", 20, 0)] == expected, "read from rollups"


def _built(databases: Any, kind: str, days: int) -> tuple[SqlStore, dict[str, Any], dict[str, Any]]:
    """Visits a few days back, built, as the two clearing tests start."""
    s = store(databases, kind)
    for d in range(days):
        t = NOW - (days + 2 - d) * DAY
        visit(s, f"s{d}", f"v{d}", t, {}, [("pageview", "/", t, f"d{d}")])
    build_days(s, "default", NOW - (days + 3) * DAY, NOW - DAY)
    month = q(NOW - 30 * DAY, NOW + DAY)
    return s, month, s.stats(month)


@pytest.mark.parametrize("kind", KINDS)
def test_a_day_built_by_another_process_while_it_is_being_cleared_is_never_left_marked_built_without_its_numbers(databases: Any, kind: str) -> None:
    s, month, before = _built(databases, kind, 4)
    watched = WatchedDb(s.db)
    view = SqlStore(watched)
    raced = False

    def after_run(sql: str, params: list[Any]) -> None:
        nonlocal raced
        if not raced and sql.startswith("DELETE FROM rl_rollup_days WHERE site = ? AND start_at"):
            raced = True
            watched.after_run = None
            # Another process builds the days right after their marks are deleted.
            build_days(s, "default", NOW - 7 * DAY, NOW - DAY)

    watched.after_run = after_run
    view.clear_rollups("default", {"from": NOW - 4 * DAY, "to": NOW})
    assert raced
    assert s.stats(month) == before


@pytest.mark.parametrize("kind", KINDS)
def test_clearing_days_that_stops_part_way_leaves_none_marked_built_without_its_numbers(databases: Any, kind: str) -> None:
    s, month, before = _built(databases, kind, 8)
    watched = WatchedDb(s.db)
    deletes = 0

    def before_statement(sql: str, params: list[Any]) -> None:
        nonlocal deletes
        if sql.startswith("DELETE FROM rl_rollups WHERE"):
            deletes += 1
            if deletes > 3:
                raise RuntimeError("connection lost")

    watched.before = before_statement
    with pytest.raises(RuntimeError, match="connection lost"):
        SqlStore(watched).clear_rollups("default")
    assert s.stats(month) == before
    build_days(s, "default", NOW - 12 * DAY, NOW - DAY)
    assert s.stats(month) == before


@pytest.mark.parametrize("kind", KINDS)
def test_retention_drops_old_visits_with_their_events_and_forgets_the_days_they_were_in(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    for i, at in enumerate([utc(2025, 10, 1), utc(2026, 7, 1), utc(2026, 10, 6)]):
        t = at + HOUR
        visit(s, f"s{i}", f"v{i}", t, {}, [("pageview", "/", t, f"p{i}"), ("event", "E", t + 1, None)])
    # An event of the oldest visit that came after the cutoff goes with it.
    s.insert_event(event(ts=utc(2025, 10, 1) + DAY, kind="event", visitor="v0", session="s0", path="/", name="Late"))
    all_ = q(0, NOW + DAY)
    assert s.stats(all_)["visits"] == 3
    s.build_rollup_day("default", "2026-07-01", utc(2026, 7, 1), utc(2026, 7, 2))
    s.drop_before("default", utc(2026, 4, 6))
    assert s.stats(all_)["visits"] == 2, "the visit from a year ago is gone"
    assert int(s.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE session = 's0'")[0]["n"]) == 0, "its events, even the late one"
    assert s.rollup_days("default") == {"2026-07-01"}, "a day after the cutoff stays built"
    s.drop_before("default", utc(2026, 8, 1))
    assert s.stats(all_)["visits"] == 1
    assert s.rollup_days("default") == set(), "a day before the cutoff is built again later"

    # Events whose visit is gone, as an older version left them, are swept.
    s.insert_event(event(ts=NOW - DAY, kind="pageview", visitor="x", session="gone", pageview="g", path="/"))
    s.insert_event(event(ts=NOW - DAY, kind="fetch", path="/", name="GPTBot"))
    s.drop_orphans("default", 0, NOW + DAY)
    assert int(s.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE session = 'gone'")[0]["n"]) == 0
    assert int(s.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'fetch'")[0]["n"]) == 1, "rows of no visit stay"
