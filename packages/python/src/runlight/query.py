"""Report queries: which dimensions exist, where each lives, and how filters
are read from a URL. Shared by every store.

A Filter is a dict {"dimension", "op", "value"}, op one of "is", "not", or "contains". A Query is a dict
{"site", "from", "to", "filters"}, `from` inclusive and `to` exclusive, both epoch milliseconds.
"""

from __future__ import annotations

from typing import Any

from . import _js

# Dimensions recorded per event.
EVENT_DIMENSIONS: dict[str, str] = {
    "page": "path",
    "hostname": "hostname",
    "event": "name",
}

# Dimensions recorded once per session, from its first request.
SESSION_DIMENSIONS: dict[str, str] = {
    "entry": "entry_path",
    "exit": "exit_path",
    "referrer": "referrer_host",
    "source": "source",
    "channel": "channel",
    "utm_source": "utm_source",
    "utm_medium": "utm_medium",
    "utm_campaign": "utm_campaign",
    "utm_term": "utm_term",
    "utm_content": "utm_content",
    "country": "country",
    "region": "region",
    "city": "city",
    "browser": "browser",
    "browser_version": "browser_version",
    "os": "os",
    "os_version": "os_version",
    "device": "device",
    "screen": "screen",
    "language": "language",
}

# AI agent fetches are their own rows, outside visits.
FETCH_DIMENSIONS: list[str] = ["ai_agent", "ai_page"]

DIMENSIONS: list[str] = [*EVENT_DIMENSIONS, *SESSION_DIMENSIONS, *FETCH_DIMENSIONS]


def is_dimension(value: str) -> bool:
    return value in DIMENSIONS


def is_session_dimension(value: str) -> bool:
    return value in SESSION_DIMENSIONS


def is_event_dimension(value: str) -> bool:
    return value in EVENT_DIMENSIONS


def parse_filter(text: str) -> dict[str, Any] | None:
    """`dimension:op:value`, where the value may itself contain colons."""
    first = text.find(":")
    second = -1 if first < 0 else text.find(":", first + 1)
    if second < 0:
        return None
    dimension = text[:first]
    op = text[first + 1 : second]
    value = text[second + 1 :]
    if not is_session_dimension(dimension) and not is_event_dimension(dimension):
        return None
    if op not in ("is", "not", "contains"):
        return None
    # 500 UTF-16 units, as JavaScript counts them.
    return {"dimension": dimension, "op": op, "value": _js.slice16(value, 0, 500)}


# The most filters a query takes, which keeps every statement within Cloudflare D1's 100 values.
MAX_FILTERS = 6
