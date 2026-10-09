"""Email reports without the core: the period each covers, against packages/php/tests/fixtures/reports.json, and whole
reports built over the TypeScript SDK's own database, against tests/fixtures/reports-store.json
(scripts/python-fixtures-reports.mts). The reports.json cases that send hits through the core belong to the core's
tests."""

from __future__ import annotations

import shutil
from pathlib import Path
from types import SimpleNamespace

from support.fixtures import PHP_FIXTURES, load, own

from runlight.reports import build_report, last_period
from runlight.store import Stores


def test_periods_match_the_typescript_sdk() -> None:
    periods = load("reports")["periods"]
    assert len(periods) > 1000
    for case in periods:
        assert last_period(case["frequency"], case["now"], case["zone"]) == case["period"], f"{case['frequency']} {case['now']} {case['zone']}"


def test_reports_built_over_the_same_database_match_the_typescript_sdk(tmp_path: Path) -> None:
    file = tmp_path / "store.db"
    shutil.copy(PHP_FIXTURES / "store.db", file)
    store = Stores.sqlite(str(file))
    store.migrate()
    runlight = SimpleNamespace(store=store)
    cases = own("reports-store")["cases"]
    assert len(cases) >= 30
    for case in cases:
        got = build_report(runlight, case["site"], case["frequency"], case["period"], case["lang"], case["links"])
        label = f"{case['site']['id']} {case['frequency']} {case['period']['key']} {case['lang']}"
        assert got["subject"] == case["report"]["subject"], label
        assert got["text"] == case["report"]["text"], label
        assert got["html"] == case["report"]["html"], label
    store.close()
