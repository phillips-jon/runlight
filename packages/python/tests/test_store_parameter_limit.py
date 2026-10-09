"""d1-limits.test.ts at the store: no statement binds more than 100 values, as Cloudflare D1 requires, over a year of
data, on SQLite as D1 runs it and on MySQL, whose statements for the same reports are written differently (PHP
ParameterLimitTest)."""

from __future__ import annotations

from typing import Any

import pytest
from support.databases import kinds
from support.store import DAY, HOUR, NOW, WatchedDb, build_days, goal, store, visit

from runlight.store import SqlStore

LIMITED = [k for k in kinds() if k != "postgres"]


@pytest.mark.parametrize("kind", LIMITED)
def test_no_statement_binds_more_than_100_parameters(databases: Any, kind: str) -> None:
    s = store(databases, kind)

    # A visit every third day for a year, so a year of days can be built.
    def fill(tx: SqlStore) -> None:
        for d in range(0, 365, 3):
            t = NOW - 365 * DAY + d * DAY
            visit(tx, f"y{d}", f"v{d}", t, {"country": "GB"}, [("pageview", f"/p{d % 40}", t, f"y{d}"), ("event", f"Goal{d % 30}", t + 1, {"amount": d})])

    s.transaction(fill)
    build_days(s, "default", NOW - 366 * DAY, NOW - DAY)
    for g in range(30):
        s.save_goal(goal(f"{g:x}".rjust(24, "0"), name=f"Goal {g}", match=f"Goal{g}", valueMode="prop" if g % 2 else "fixed", value=5, valueProp="amount"))
    funnel = {"id": "f" * 24, "site": "default", "name": "Funnel", "steps": [{"kind": "page", "match": "/p1"}, {"kind": "event", "match": "Goal1"}], "createdAt": 0}
    s.save_funnel(funnel)
    # Days not built, scattered through the last month, as late engagement or an import leaves them.
    for d in range(2, 30, 3):
        s.clear_rollups("default", {"from": NOW - d * DAY, "to": NOW - d * DAY + 1})

    # Every statement from here on is checked.
    watched = WatchedDb(s.db)
    most = 0

    def check(sql: str, params: list[Any]) -> None:
        nonlocal most
        most = max(most, len(params))
        if len(params) > 100:
            raise RuntimeError(f"a statement bound {len(params)} parameters")

    watched.before = check
    view = SqlStore(watched)
    goals = view.goals("default")

    def days(from_: int, to: int, size: int) -> list[dict[str, int]]:
        return [{"start": at, "end": min(at + size, to)} for at in range(from_, to, size)]

    def f(d: str, op: str, v: str) -> dict[str, str]:
        return {"dimension": d, "op": op, "value": v}

    # As many filters as a query takes, each of the kind that binds the most.
    many = [f("page", "contains", "/P"), f("page", "contains", "é"), f("event", "contains", "goal"), f("hostname", "contains", "example"), f("page", "not", "/x"), f("country", "not", "XX")]
    # Path filters in mixed case are tried in several forms, each a value of its own.
    paths = [f("page", "contains", "/pÉ"), f("page", "contains", "/Pé"), f("page", "contains", "/xÜ"), f("page", "contains", "/üX"), f("page", "contains", "/ÉtÉ"), f("hostname", "contains", "eXa")]
    ranges = {
        "12mo": (NOW - 365 * DAY, NOW + DAY, DAY),
        "all": (NOW - 400 * DAY, NOW + DAY, 30 * DAY),
        "90d": (NOW - 90 * DAY, NOW + DAY, DAY),
        "30d": (NOW - 30 * DAY, NOW + DAY, DAY),
        "7d hourly": (NOW - 7 * DAY, NOW + DAY, HOUR),
    }
    for from_, to, size in ranges.values():
        for filters in ([], [f("page", "contains", "/p")], [f("country", "not", "XX")], many, paths):
            query = {"site": "default", "from": from_, "to": to, "filters": filters}
            view.stats(query)
            view.series(query, days(from_, to, size))
            view.hourly(query)
            view.breakdown(query, "page", 1000, 0)
            view.breakdown(query, "source", 1000, 0)
            view.breakdown(query, "event", 1000, 0)
            assert len(view.goal_totals_all(query, goals)) == 30
            for g in (goals[1], goals[2]):
                view.goal_totals(query, g)
                view.goal_series(query, g, days(from_, to, size))
                view.goal_breakdown(query, g, "path")
            view.funnel_counts(query, funnel)
            view.journey_pages(query, 5)
            view.event_prop_keys(query, "Goal1")
            view.event_prop_values(query, "Goal1", "amount", 10)
    assert most <= 100
    assert most > 50, "the reads came close"
