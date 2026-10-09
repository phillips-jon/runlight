"""Replays the importer scenarios in tests/fixtures/outbound.json (the cases of importers.test.ts and more): each
importer, run step by step against the same answers, must send the TypeScript SDK's exact requests, wait as long
between retries, ask about the same known links, and hand back the same steps, cursors included. The store side of
an import (import_step, write_link) is in test_import_step.py."""

from __future__ import annotations

import math
import re
from typing import Any

import pytest
from support import fixtures
from support.fake_fetcher import FakeFetcher

from runlight import _js
from runlight.http import FetchError, Response
from runlight.importers.bitly import bitly
from runlight.importers.dub import dub
from runlight.importers.http import Http, HttpError, iso_string, parse_date
from runlight.importers.rebrandly import rebrandly
from runlight.importers.shortio import shortio
from runlight.importers.types import ImportError
from runlight.importers.umami import umami


SOURCES = {"bitly": bitly, "dub": dub, "rebrandly": rebrandly, "shortio": shortio, "umami": umami}


def scenarios() -> list[Any]:
    return fixtures.load("outbound")["importers"]


@pytest.mark.parametrize("scenario", scenarios(), ids=lambda s: s["name"])
def test_scenario_matches_typescript(scenario: dict[str, Any]) -> None:
    now = fixtures.load("outbound")["now"]
    left = [r.get("times", math.inf) for r in scenario["routes"]]

    def answer(url: str, init: dict[str, Any]) -> Response:
        for i, route in enumerate(scenario["routes"]):
            if left[i] <= 0 or not re.search(route["pattern"], url):
                continue
            left[i] -= 1
            if route.get("unreachable"):
                raise FetchError("fetch failed")
            return Response(_js.dumps(route.get("body")), route.get("status", 200), {"content-type": "application/json", **(route.get("headers") or {})})
        return Response("{}", 404)

    fetcher = FakeFetcher(answer)
    waits: list[Any] = []
    http = Http(fetcher, waits.append)
    importer = SOURCES[scenario["source"]]
    known_calls: list[Any] = []

    def known(source_id: Any, slug: Any = None, url: Any = None) -> bool:
        known_calls.append([source_id, slug, url])
        return source_id in scenario["known"] or f"{slug} {url}" in scenario["known"]

    expected = scenario["steps"]
    cursor = expected[0].get("cursor") if expected else None
    for i, want in enumerate(expected):
        assert cursor == want["cursor"], f"step {i} starts from the same cursor"
        try:
            result = importer.step({"credentials": scenario["credentials"], "cursor": cursor, "known": known, "now": now, "http": http})
        except ImportError as error:
            assert "error" in want, f"step {i} should not fail: {error}"
            got: dict[str, Any] = {"message": str(error), "code": error.code, "params": error.params}
            if isinstance(error, HttpError):
                got["status"] = error.status
            got["name"] = type(error).__name__
            assert _js.dumps(got) == _js.dumps(want["error"])
            continue
        assert "error" not in want, f"step {i} should fail"
        assert _js.dumps(result) == _js.dumps(want["result"]), f"step {i}"
        cursor = result["cursor"]

    sent = fetcher.requests
    requests = scenario["requests"]
    if not scenario["ordered"]:
        # Umami asks for a link's events and sessions at once in TS; here one follows the other.
        sent = sorted(_js.dumps(r) for r in sent)
        requests = sorted(_js.dumps(r) for r in requests)
    assert sent == requests
    assert waits == scenario["waits"]
    assert known_calls == scenario["knownCalls"]


def test_dates_parse_as_javascript_parses_them() -> None:
    assert parse_date("2026-01-01T00:00:00Z") == 1767225600000
    assert parse_date("2026-01-01T00:00:00+0000") == 1767225600000
    assert parse_date("2026-01-01") == 1767225600000
    assert parse_date("2026-01-01T02:00:00.5+02:00") == 1767225600500
    assert parse_date("2026-01-01T00:00:00") == 1767225600000, "local time, and the tests run in UTC"
    assert parse_date("2026-01-01 00:00:00") == 1767225600000
    assert parse_date("2026/03/01") == 1772323200000
    assert parse_date("2026-03-01 10:00:00 UTC") == 1772359200000
    assert parse_date("2026-03-01T10:00Z") == 1772359200000
    assert parse_date("2026-03-01T24:00:00Z") == 1772409600000
    assert parse_date("Tue, 03 Mar 2026 10:00:00 GMT") == 1772532000000
    assert parse_date("1970-01-01T00:00:00.000Z") == 0
    for text in ["nope", "2026-02-30", None, "", "1772409600000", "2026-01-01T00:00:00+00"]:
        assert math.isnan(parse_date(text)), repr(text)
    assert iso_string(1772409600000) == "2026-03-02T00:00:00.000Z"
    assert iso_string(-1) == "1969-12-31T23:59:59.999Z"
    with pytest.raises(ValueError):
        iso_string(math.nan)
