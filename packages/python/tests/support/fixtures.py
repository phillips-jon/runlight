"""The language-neutral fixtures the TypeScript SDK writes, read where the PHP tests read them."""

from __future__ import annotations

import json
from functools import cache
from pathlib import Path
from typing import Any

from runlight import _js

ROOT = Path(__file__).resolve().parents[4]
PHP_FIXTURES = ROOT / "packages" / "php" / "tests" / "fixtures"
CONFORMANCE = ROOT / "conformance"
OWN_FIXTURES = ROOT / "packages" / "python" / "tests" / "fixtures"


@cache
def load(name: str) -> Any:
    """packages/php/tests/fixtures/<name>.json, read as JSON.parse reads it."""
    return _js.loads((PHP_FIXTURES / f"{name}.json").read_text("utf-8"))


@cache
def conformance(name: str) -> Any:
    """conformance/<name>.json."""
    return _js.loads((CONFORMANCE / f"{name}.json").read_text("utf-8"))


@cache
def own(name: str) -> Any:
    """packages/python/tests/fixtures/<name>.json, the fixtures this port writes from TypeScript itself."""
    return _js.loads((OWN_FIXTURES / f"{name}.json").read_text("utf-8"))


def label(value: Any) -> str:
    """A short label for a case, for messages."""
    text = json.dumps(value, ensure_ascii=False, default=str)
    return text[:160] + "..." if len(text) > 160 else text
