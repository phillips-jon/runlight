"""Location from platform headers, with a lookup behind them, replayed from the TypeScript SDK. The MMDB cases of
the same fixture are the MMDB reader's tests."""

from __future__ import annotations

from support import fixtures

from runlight.geo import locate, location_from_headers
from runlight.http import Headers


def test_headers() -> None:
    for case in fixtures.load("geo")["headers"]:
        assert location_from_headers(Headers(case["headers"])) == case["location"], fixtures.label(case["headers"])


def test_locate() -> None:
    for case in fixtures.load("geo")["located"]:

        def lookup(ip: str, case: dict = case) -> dict | None:
            if case.get("throws"):
                raise RuntimeError("broken")
            return case["found"]

        got = locate(Headers(case["headers"]), case["ip"], None if case.get("noLookup") else lookup)
        assert got == case["location"], fixtures.label(case)
