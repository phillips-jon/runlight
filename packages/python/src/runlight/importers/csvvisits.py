"""Visit history from a CSV file, in one of two shapes: Umami's data export
(one row per pageview or event, as in its website_event table) or Runlight's
own, documented on the dashboard docs page. The dashboard reads the file,
sorts it with row_time, and sends it in batches; the server turns each row
into a hit with csv_hit. Nothing here touches a database.
"""

from __future__ import annotations

import math
import re
from typing import Any

from .. import _js
from ..http import Url
from .http import parse_date

# "umami" or "runlight"
CsvFormat = str

# At most this many rows in one request.
CSV_BATCH = 2000


def csv_format(columns: list[str]) -> CsvFormat | None:
    """Which shape a file is, from its header row (lower case, as the dashboard reads it)."""
    if "created_at" in columns and "url_path" in columns:
        return "umami"
    if "time" in columns and ("path" in columns or "url" in columns):
        return "runlight"
    return None


_NUMERIC = re.compile(r"\d+(\.\d+)?\Z", re.ASCII)
_ZONED = re.compile(r"[zZ]|[+-]\d\d:?\d\d\Z", re.ASCII)
_TIMED = re.compile(r"T\d", re.ASCII)
_SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*://", re.I)
_LEADING_QUESTION = re.compile(r"^\?")


def row_time(row: dict[str, str], format: CsvFormat) -> int | float:
    """A row's time in milliseconds, or NaN. ISO 8601 with or without a zone, "2024-05-01 12:34:56"
    (both read as UTC when no zone is given, as Umami writes them), or a Unix time in seconds or milliseconds."""
    value = row.get("created_at" if format == "umami" else "time")
    text = "" if value is None else _js.trim(value)
    if not text:
        return math.nan
    if _NUMERIC.match(text):
        n = _js.number(text)
        return _js.js_round(n * 1000) if n < 1e12 else _js.js_round(n)
    iso = text.replace(" ", "T", 1)
    return parse_date(iso if _ZONED.search(iso) or not _TIMED.search(iso) else f"{iso}Z")


def _cell(row: dict[str, str], *names: str) -> str:
    for n in names:
        value = row.get(n)
        if value is not None and _js.trim(value):
            return _js.trim(value)
    return ""


def _own_key(row: dict[str, str]) -> str:
    """A row with no visitor is its own visit, keyed by its whole content so a second import gives it the same
    ids."""
    return f"row:{_js.dumps(sorted(([k, v] for k, v in row.items()), key=lambda kv: _js.order_key(kv[0])))}"


def _full_referrer(value: str) -> str:
    """A referrer as a full address: a bare domain gains https://."""
    if not value:
        return ""
    return value if _SCHEME.match(value) else f"https://{value}"


def csv_hit(row: dict[str, str], format: CsvFormat) -> dict[str, Any] | None:
    """One row as {ns, hit}: a hit and the namespace its ids are made in, or None for a row that is not a
    pageview or a named event, or has no time. Umami rows use the namespace the Umami API import does, so the same
    visits brought in both ways get the same ids."""
    ts = row_time(row, format)
    if not _js.is_finite(ts):
        return None
    if format == "umami":
        type = _cell(row, "event_type") or "1"
        name = _cell(row, "event_name")
        if type != "1" and not (type == "2" and name):
            return None
        website = _cell(row, "website_id")
        domain = _cell(row, "referrer_domain")
        referrer = ""
        if domain:
            query = _cell(row, "referrer_query")
            referrer = f"https://{domain}{_cell(row, 'referrer_path') or '/'}{'?' + _LEADING_QUESTION.sub('', query) if query else ''}"
        return {
            "ns": f"umami-visits:{website}" if website else "umami-csv",
            "hit": {
                "ts": ts,
                "key": _cell(row, "session_id", "visit_id") or _own_key(row),
                "kind": "pageview" if type == "1" else "event",
                "hostname": _cell(row, "hostname"),
                "path": _cell(row, "url_path") or "/",
                "query": _cell(row, "url_query"),
                "referrer": referrer,
                "title": _cell(row, "page_title"),
                "name": name if type == "2" else "",
                "country": _cell(row, "country"),
                "region": _cell(row, "subdivision1", "region"),
                "city": _cell(row, "city"),
                "browser": _cell(row, "browser"),
                "os": _cell(row, "os"),
                "device": _cell(row, "device"),
                "screen": _cell(row, "screen"),
                "language": _cell(row, "language"),
            },
        }
    # Runlight's own shape: a full url, or a path (with its query) and a hostname.
    hostname = _cell(row, "hostname")
    path = _cell(row, "path")
    query = ""
    url = _cell(row, "url")
    if url:
        u = Url.parse(url if _SCHEME.match(url) else f"https://{url}")
        if u is None:
            return None
        hostname = hostname or u.hostname
        path = u.pathname
        query = _js.slice16(u.search, 1)
    else:
        at = path.find("?")
        if at >= 0:
            path, query = path[:at], path[at + 1 :]
    if not path.startswith("/"):
        path = f"/{path}"
    name = _cell(row, "event")
    return {
        "ns": "csv",
        "hit": {
            "ts": ts,
            # Without a visitor column every row is its own visit.
            "key": _cell(row, "visitor") or _own_key(row),
            "kind": "event" if name else "pageview",
            "hostname": hostname,
            "path": path,
            "query": query,
            "referrer": _full_referrer(_cell(row, "referrer")),
            "title": _cell(row, "title"),
            "name": name,
            "country": _cell(row, "country"),
            "region": _cell(row, "region"),
            "city": _cell(row, "city"),
            "browser": _cell(row, "browser"),
            "os": _cell(row, "os"),
            "device": _cell(row, "device"),
            "screen": _cell(row, "screen"),
            "language": _cell(row, "language"),
        },
    }
