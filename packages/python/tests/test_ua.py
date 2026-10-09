"""Replays conformance/ua.json, every case, and the wider fixture written from the TypeScript SDK."""

from __future__ import annotations

import pytest
from support import fixtures

from runlight import _js
from runlight.ua import ai_agent, is_bot, parse_client

CASES = fixtures.conformance("ua")["cases"]


@pytest.mark.parametrize("case", CASES, ids=[f"{i} {c['ua'][:90]}" for i, c in enumerate(CASES)])
def test_conformance(case: dict) -> None:
    agent = ai_agent(case["ua"])
    if "agent" in case:
        assert agent is not None
        assert agent["name"] == case["agent"]["name"]
        assert agent["kind"] == case["agent"]["kind"]
        return
    assert agent is None, "not an AI agent"
    assert is_bot(case["ua"]) == bool(case.get("bot", False))
    if "client" in case:
        assert parse_client(case["ua"], case.get("hints") or {}, case.get("screenWidth")) == case["client"]


def test_client_hints_mark_a_mobile_chromium_as_mobile() -> None:
    ua = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
    assert parse_client(ua)["device"] == "tablet"
    # An Android UA without Mobile still reads as a tablet.
    assert parse_client(ua, {"mobile": "?1"})["device"] == "tablet"
    desktop = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
    assert parse_client(desktop, {"mobile": "?1"})["device"] == "mobile"


def test_fixture() -> None:
    cases = fixtures.load("ua")["cases"]
    failures = []
    for case in cases:
        got = {
            "agent": ai_agent(case["ua"]),
            "bot": is_bot(case["ua"]),
            "client": parse_client(case["ua"], case.get("hints") or {}, case.get("screenWidth")),
        }
        want = {"agent": case["agent"], "bot": case["bot"], "client": case["client"]}
        if _js.dumps(got) != _js.dumps(want):
            failures.append(f"{fixtures.label(case)} gave {fixtures.label(got)}")
    assert len(cases) > 200
    assert failures[:20] == []
