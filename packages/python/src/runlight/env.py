"""Environment variables, read in one place."""

from __future__ import annotations

import os

from ._js import trim


def env_value(name: str) -> str | None:
    """The variable's value trimmed, or None when it is unset or blank, as envValue() in runlight.ts reads it."""
    value = os.environ.get(name)
    if value is None:
        return None
    value = trim(value)
    return value or None
