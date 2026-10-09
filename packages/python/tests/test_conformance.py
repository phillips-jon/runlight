"""Replays conformance/http.json against the Python core on every store, as http-conformance.test.ts does against
the TypeScript one: each step's answer must equal the one the file holds."""

from __future__ import annotations

import hashlib
from typing import Any

import pytest

from runlight import _js
from support import conformance
from support.databases import kinds

FILE = conformance.load()
CASES = [(kind, scenario["name"]) for kind in kinds() for scenario in FILE["scenarios"]]


def _sorted(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: _sorted(value[k]) for k in sorted(value)}
    if isinstance(value, list):
        return [_sorted(v) for v in value]
    return value


def canonical(value: Any, indent: int | None = None) -> str:
    """Answers as one text to compare: object keys sorted, since JavaScript's deepEqual ignores their order, and
    written as JSON.stringify writes them, so 1.0 and 1 are the same number while true and 1 are not."""
    return _js.dumps(_sorted(value), indent)


def test_format_is_the_one_this_runner_reads() -> None:
    assert hashlib.sha256(FILE["description"].encode("utf-8")).hexdigest() == conformance.FORMAT_SHA256, (
        "conformance/http.json describes its format differently now. Read the change, port it to the runner, "
        "then update FORMAT_SHA256."
    )


@pytest.mark.parametrize(("kind", "name"), CASES, ids=[f"{k}: {n}" for k, n in CASES])
def test_scenario(databases, kind: str, name: str) -> None:
    from runlight.store import Stores

    scenario = next(s for s in FILE["scenarios"] if s["name"] == name)
    store = Stores.from_db(databases.db(kind))
    answers = conformance.Player().play(scenario, conformance.CoreTarget, store)
    assert len(answers) == len(scenario["steps"])
    differ = [i for i, step in enumerate(scenario["steps"]) if canonical(step.get("expect")) != canonical(answers[i])]
    if differ:
        i = differ[0]
        step = scenario["steps"][i]
        others = f" Steps {', '.join(str(n + 1) for n in differ[1:])} differ too." if len(differ) > 1 else ""
        assert canonical(answers[i], 1) == canonical(step.get("expect"), 1), f"{name} ({kind}): step {i + 1}, {step['method']} {step['path']} answered differently.{others}"
