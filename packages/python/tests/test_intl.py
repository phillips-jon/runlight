"""Replays tests/fixtures/intl.json (scripts/python-intl.mts): Intl's numbers, money, dates, and region names as
reports.ts writes them, from Node's ICU."""

from __future__ import annotations

from support import fixtures

from runlight import _intl, _js


def run(case: dict) -> str:
    lang = case["lang"]
    kind = case["kind"]
    if kind in ("number", "percent", "decimal", "currency"):
        n = _js.number(case["n"])
        if kind == "number":
            return _intl.number(lang, n)
        if kind == "percent":
            return _intl.percent(lang, n)
        if kind == "decimal":
            return _intl.number(lang, n, 1, 1)
        return _intl.currency(lang, n, case["currency"], 0 if _js.is_integer(n) else 2)
    if kind == "monthYear":
        return _intl.month_year(lang, case["date"])
    if kind == "shortDay":
        return _intl.short_day(lang, case["date"], False)
    if kind == "shortDayYear":
        return _intl.short_day(lang, case["date"], True)
    return _intl.region(lang, case["code"])


def test_intl_matches_node() -> None:
    cases = fixtures.own("intl")["cases"]
    failures = [f"{fixtures.label(c)} gave {run(c)!r}" for c in cases if run(c) != c["out"]]
    assert len(cases) > 1000
    assert failures[:20] == []
