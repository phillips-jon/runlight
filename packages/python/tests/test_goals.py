"""Goals and funnels checked from the dashboard, against packages/php/tests/fixtures/goals.json (written from the
TypeScript SDK by scripts/php-fixtures-store.mts), and the checks goals.test.ts and funnels.test.ts make (PHP
GoalsTest)."""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

from support.fixtures import label, load

from runlight import _js
from runlight.funnels import FunnelError, funnel_from
from runlight.goals import GoalError, click_rules, goal_from, page_pattern


def _outcome(fn: Callable[[], dict[str, Any]], fresh: bool) -> str:
    """The answer as the fixture writes it: the row with a new id as "<random>", or the error."""
    try:
        value = fn()
        if fresh and re.fullmatch(r"[0-9a-f]{24}", value["id"]):
            value = {**value, "id": "<random>"}
        return _js.dumps({"value": value})
    except (GoalError, FunnelError) as error:
        return _js.dumps({"error": {"message": error.message, "code": error.code, "params": error.params}})


def test_goals_are_checked_as_the_typescript_sdk_checks_them() -> None:
    fixture = load("goals")
    assert len(fixture["goals"]) > 50
    for i, case in enumerate(fixture["goals"]):
        got = _outcome(lambda case=case: goal_from(case["input"], "s", fixture["existing"], 1000, case["id"]), case["id"] is None)
        assert got == _js.dumps(case["result"]), f"#{i} {label(case['input'])}"


def test_funnels_are_checked_as_the_typescript_sdk_checks_them() -> None:
    fixture = load("goals")
    for i, case in enumerate(fixture["funnels"]):
        got = _outcome(lambda case=case: funnel_from(case["input"], "s", fixture["existingFunnels"], 1000, case["id"]), case["id"] is None)
        assert got == _js.dumps(case["result"]), f"#{i} {label(case['input'])}"


def test_page_patterns_and_click_rules() -> None:
    fixture = load("goals")
    for case in fixture["patterns"]:
        assert page_pattern(case["input"]) == case["result"], case["input"]

    def goal(id: str, **g: Any) -> dict[str, Any]:
        return {"id": id, "site": "s", "name": id, "kind": "event", "match": id, "clickBy": "", "valueMode": "none", "value": 0, "valueProp": "", "currency": "USD", "createdAt": 5, **g}

    rules = click_rules(
        [
            {"id": "s", "name": "S", "hostnames": ["www.example.com", "shop.example.com"], "timezone": "UTC"},
            {"id": "t", "name": "T", "hostnames": [], "timezone": "UTC"},
            {"id": "u", "name": "U", "hostnames": ["u.example"], "timezone": "UTC"},
        ],
        [
            goal("c" * 24, name="Buy", kind="click", match=".buy", clickBy="selector"),
            goal("d" * 24, name="Out", kind="click", match="https://x.example/*", clickBy="link", site="t"),
            goal("e" * 24, name="E", site="u"),
        ],
    )
    assert _js.dumps(rules) == _js.dumps(fixture["rules"])


def test_goal_checks_say_what_is_wrong() -> None:
    made = goal_from({"name": "X", "kind": "event", "match": "X"}, "default", [], 1)
    codes = []
    for input, existing in [
        ({"name": "x", "kind": "event", "match": "Y"}, [made]),
        ({"name": "Y", "kind": "event", "match": "Y", "currency": "dollars"}, []),
        ({"name": "Z", "kind": "event", "match": "Z", "valueMode": "fixed", "value": -1}, []),
        ({"name": "W", "kind": "event", "match": "W", "valueMode": "prop", "valueProp": "a b"}, []),
        ({"name": "P", "kind": "page", "match": "/p", "valueMode": "prop"}, []),
    ]:
        try:
            goal_from(input, "default", existing, 1)
            codes.append("none")
        except GoalError as error:
            codes.append(error.code)
    assert codes == ["goal_exists", "goal_currency", "goal_amount", "goal_prop_name", "goal_prop_kind"]
    renamed = goal_from({"name": "Renamed", "kind": "event", "match": "X"}, "default", [made], 99, made["id"])
    assert [renamed["id"], renamed["createdAt"]] == [made["id"], 1], "a goal changed keeps its id and when it was made"
