"""Journeys: the paths visits take through a site, page by page. Each visit's pages are read in order, a page seen
twice in a row (a refresh) counts once, and the path is cut to a number of steps, from a start page and to an end
page when those are chosen. The answer lines the paths up in columns, one per step, with the flows between them, as
Umami's journeys do.

JourneyOptions: {steps, start?, end?, through?: {step, value}} (through: only paths that show this page at this
step, 0-based, to follow one page). The answer: {visits, columns: [{items: [{value, visits}], visits, left}], links:
[{step, from, to, visits}], paths: [{pages, visits}]}, where "" is any other page.
"""

from __future__ import annotations

import functools
import math
from typing import Any

from . import _js

# How many pages of a visit to read: enough to find a start page and still have the steps after it.
PAGES_PER_VISIT = 40
_TOP = 8


def _lt(a: str, b: str) -> bool:
    """JavaScript's a < b on text: by UTF-16 units."""
    return _js.order_key(a) < _js.order_key(b)


def _steps(value: Any) -> int:
    """Math.min(Math.max(Math.floor(steps) || 5, 2), 8)."""
    n = _js.number(value)
    n = math.floor(n) if isinstance(n, float) and math.isfinite(n) else n
    if not n or (isinstance(n, float) and math.isnan(n)):
        n = 5
    return int(min(max(n, 2), 8))


def _at(pages: list[str], step: object) -> str | None:
    """pages[step], undefined (None) for a step that is not an index of the list, as a fraction or -1 is not."""
    if not _js.is_integer(step):
        return None
    index = int(step)  # type: ignore[call-overload]
    return pages[index] if 0 <= index < len(pages) else None


def journeys(rows: list[dict[str, str]], options: dict[str, Any]) -> dict[str, Any]:
    steps = _steps(options.get("steps"))
    # Group each visit's pages, dropping refreshes.
    visits: dict[str, list[str]] = {}
    for row in rows:
        pages = visits.setdefault(row["session"], [])
        if not pages or pages[-1] != row["path"]:
            pages.append(row["path"])
    sequences: list[list[str]] = []
    # Visits that went on past the last step shown, so they never count as having gone no further.
    cut: set[int] = set()
    start = options.get("start")
    end = options.get("end")
    through = options.get("through")
    for pages in visits.values():
        if start:
            if start not in pages:
                continue
            pages = pages[pages.index(start) :]
        if end:
            if end not in pages:
                continue
            pages = pages[: pages.index(end) + 1]
        more = len(pages) > steps
        pages = pages[:steps]
        if through and _at(pages, through["step"]) != through["value"]:
            continue
        sequences.append(pages)
        if more:
            cut.add(id(pages))

    columns: list[dict[str, Any]] = []
    kept: list[set[str]] = []
    for i in range(steps):
        counts: dict[str, int] = {}
        reached = 0
        left = 0
        for s in sequences:
            if len(s) <= i:
                continue
            reached += 1
            if len(s) == i + 1 and id(s) not in cut:
                left += 1
            counts[s[i]] = counts.get(s[i], 0) + 1
        ordered = sorted(counts.items(), key=functools.cmp_to_key(lambda a, b: (b[1] - a[1]) or (-1 if _lt(a[0], b[0]) else 1)))
        top = ordered[:_TOP]
        rest = sum(v for _, v in ordered[_TOP:])
        kept.append({v for v, _ in top})
        if not reached:
            break
        items = [{"value": value, "visits": n} for value, n in top]
        if rest:
            items.append({"value": "", "visits": rest})
        columns.append({"items": items, "visits": reached, "left": left})

    link_counts: dict[tuple[int, str, str], dict[str, Any]] = {}
    for s in sequences:
        i = 0
        while i + 1 < len(s) and i + 1 < len(columns):
            from_ = s[i] if s[i] in kept[i] else ""
            to = s[i + 1] if s[i + 1] in kept[i + 1] else ""
            link = link_counts.setdefault((i, from_, to), {"step": i, "from": from_, "to": to, "visits": 0})
            link["visits"] += 1
            i += 1

    path_counts: dict[str, dict[str, Any]] = {}
    for s in sequences:
        path = path_counts.setdefault("\u0000".join(s), {"pages": s, "visits": 0})
        path["visits"] += 1

    def link_order(a: dict[str, Any], b: dict[str, Any]) -> int:
        if a["step"] != b["step"]:
            return a["step"] - b["step"]
        if a["visits"] != b["visits"]:
            return b["visits"] - a["visits"]
        if _lt(a["from"], b["from"]):
            return -1
        if _lt(b["from"], a["from"]):
            return 1
        if _lt(a["to"], b["to"]):
            return -1
        if _lt(b["to"], a["to"]):
            return 1
        return 0

    paths = sorted(path_counts.items(), key=functools.cmp_to_key(lambda a, b: (b[1]["visits"] - a[1]["visits"]) or (-1 if _lt(a[0], b[0]) else 1)))
    return {
        "visits": len(sequences),
        "columns": columns,
        # Ties go by page, as the columns and paths do, so the order never follows the visits' random ids.
        "links": sorted(link_counts.values(), key=functools.cmp_to_key(link_order)),
        "paths": [p for _, p in paths][:20],
    }
