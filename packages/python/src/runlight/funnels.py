"""Funnels: checking one from the dashboard."""

from __future__ import annotations

from typing import Any

from . import _js
from .goals import page_pattern
from .hash import random_id


class FunnelError(Exception):
    """Why a funnel was refused, as a code the dashboard says in its own words."""

    def __init__(self, message: str, code: str, params: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = params or {}


def _text(value: Any) -> str:
    """String(value ?? "")."""
    return "" if value is None or value is _js.UNDEFINED else _js.string(value)


def funnel_from(input: dict[str, Any], site: str, existing: list[dict[str, Any]], now: int, id: str | None = None) -> dict[str, Any]:
    """Checks and tidies a funnel from the dashboard: a name, and two to eight steps, each a page (with * as a
    wildcard) or an event name."""
    # .slice() counts UTF-16 units, as TypeScript does.
    name = _js.cut(_js.trim(_text(input.get("name") if isinstance(input, dict) else None)), 80)
    if not name:
        raise FunnelError("Give the funnel a name", "funnel_name")
    if any(f["id"] != id and f["name"].lower() == name.lower() for f in existing):
        raise FunnelError(f'There is already a funnel called "{name}"', "funnel_exists", {"name": name})
    raw = input.get("steps") if isinstance(input, dict) else None
    steps: list[dict[str, str]] = []
    for item in raw if isinstance(raw, list) else []:
        step = item if isinstance(item, dict) else {}
        kind = "event" if step.get("kind") == "event" else "page"
        match = _js.cut(_js.trim(_text(step.get("match"))), 500)
        if not match:
            continue
        if kind == "page":
            # A full URL is fine to paste; the path is what counts.
            path = page_pattern(match)
            if path is None:
                raise FunnelError(f'"{match}" is not a path or a URL', "funnel_page_bad", {"match": match})
            match = path
        steps.append({"kind": kind, "match": match})
    if len(steps) < 2:
        raise FunnelError("A funnel needs at least two steps", "funnel_short")
    if len(steps) > 8:
        raise FunnelError("A funnel has at most eight steps", "funnel_long")
    before = next((f for f in existing if f["id"] == id), None)
    return {"id": id if id is not None else random_id(), "site": site, "name": name, "steps": steps, "createdAt": before["createdAt"] if before is not None else now}
