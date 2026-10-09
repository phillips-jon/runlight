"""Journeys, as journeys.test.ts tests them, and against packages/php/tests/fixtures/journeys.json (PHP
JourneysTest)."""

from __future__ import annotations

import math

from support.fixtures import load

from runlight import _js
from runlight.journeys import journeys


def _rows(visits: dict[str, list[str]]) -> list[dict[str, str]]:
    return [{"session": session, "path": path} for session, pages in visits.items() for path in pages]


def test_journeys_line_paths_up_by_step_with_flows_and_follow_a_start_an_end_and_one_page() -> None:
    data = _rows(
        {
            "a": ["/", "/pricing", "/signup"],
            "b": ["/", "/pricing", "/pricing", "/docs"],
            "c": ["/", "/blog"],
            "d": ["/blog", "/", "/pricing"],
            "e": ["/docs"],
        }
    )
    all_ = journeys(data, {"steps": 3})
    assert all_["visits"] == 5
    assert all_["columns"][0] == {"items": [{"value": "/", "visits": 3}, {"value": "/blog", "visits": 1}, {"value": "/docs", "visits": 1}], "visits": 5, "left": 1}
    assert all_["columns"][1]["items"][0] == {"value": "/pricing", "visits": 2}, "a refresh counts once"
    from_home = [l for l in all_["links"] if l["step"] == 0 and l["from"] == "/"]  # noqa: E741
    assert [[l["to"], l["visits"]] for l in from_home] == [["/pricing", 2], ["/blog", 1]]  # noqa: E741
    assert len(all_["paths"]) == 5
    # With two steps, visits a, b, and d go on to a third page, so only c went no further than step two.
    two = journeys(data, {"steps": 2})
    assert [two["columns"][1]["visits"], two["columns"][1]["left"]] == [4, 1], "the last step counts only visits that ended there"
    assert all_["paths"][0] == {"pages": ["/", "/blog"], "visits": 1}, "ties in a fixed order"

    from_pricing = journeys(data, {"steps": 3, "start": "/pricing"})
    assert from_pricing["visits"] == 3, "visits that reached /pricing, from there on"
    assert from_pricing["columns"][0]["items"] == [{"value": "/pricing", "visits": 3}]

    to_signup = journeys(data, {"steps": 4, "end": "/signup"})
    assert to_signup["paths"] == [{"pages": ["/", "/pricing", "/signup"], "visits": 1}]

    through = journeys(data, {"steps": 3, "through": {"step": 1, "value": "/blog"}})
    assert through["visits"] == 1


def test_fixtures_match() -> None:
    fixture = load("journeys")
    for run in fixture["runs"]:
        options = dict(run["options"])
        if options.get("steps") == "NaN":
            options["steps"] = math.nan
        result = journeys(fixture["datasets"][run["dataset"]], options)
        assert _js.dumps(result) == _js.dumps(run["result"]), f"dataset {run['dataset']} with {run['options']}"
