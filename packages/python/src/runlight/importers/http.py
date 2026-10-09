"""JSON over HTTPS with a timeout and a few retries on rate limits and server
errors, plus the few pieces of JavaScript the importers lean on (Date.parse,
toISOString, and fields that may be missing). An importer's requests go through
an Http, so tests can pass a fake Fetcher and a sleep that does not wait.
"""

from __future__ import annotations

import datetime
import email.utils
import math
import re
import time
from collections.abc import Callable
from typing import Any

from .. import _js
from ..http import Fetcher, FetchError, Url, UrllibFetcher
from .types import ImportError


class HttpError(ImportError):
    """A service answered with a status that is not success."""

    def __init__(self, message: str, status: int, code: str, params: dict[str, str] | None = None) -> None:
        super().__init__(message, code, params)
        self.status = status


def _host(url: str) -> str:
    parsed = Url.parse(url)
    if parsed is None:
        raise TypeError("Invalid URL")
    return parsed.host


def _wait(ms: int | float) -> None:
    if ms > 0:
        time.sleep(ms / 1000)


class Http:
    """Where an importer's requests go: a Fetcher (the Runlight's), and a sleep given milliseconds."""

    def __init__(self, fetcher: Fetcher | None = None, sleep: Callable[[int | float], None] | None = None) -> None:
        self.fetcher = fetcher or UrllibFetcher()
        self.sleep = sleep or _wait

    def pause(self, ms: int | float) -> None:
        self.sleep(ms)

    def get_json(self, url: str, init: dict[str, Any] | None = None) -> Any:
        """Fetches JSON. `init` takes headers, method, and body."""
        init = init or {}
        attempt = 1
        while True:
            options: dict[str, Any] = {}
            if "method" in init:
                options["method"] = init["method"]
            options["headers"] = {"accept": "application/json", **(init.get("headers") or {})}
            if "body" in init:
                options["body"] = init["body"]
            options["timeoutMs"] = 20_000
            try:
                response = self.fetcher.fetch(url, options)
            except FetchError:
                if attempt < 3:
                    attempt += 1
                    continue
                host = _host(url)
                raise ImportError(f"Could not reach {host}", "unreachable", {"host": host}) from None
            if response.ok:
                return response.json_body()
            if response.status == 401:
                raise HttpError("The key or sign-in was refused", 401, "import_refused")
            if (response.status == 429 or response.status >= 500) and attempt < 4:
                # Retry-After in seconds; none, zero, negative, or not a number waits the default backoff.
                wait = _js.number(response.headers.get("retry-after")) * 1000
                if not wait > 0:
                    wait = 800 * attempt
                self.pause(_js.whole(min(wait, 10_000)))
                attempt += 1
                continue
            host = _host(url)
            raise HttpError(f"{host} answered {response.status}", response.status, "import_status", {"host": host, "status": str(response.status)})


def get_json(url: str, init: dict[str, Any] | None = None, http: Http | None = None) -> Any:
    """getJson through `http`, or a default Http."""
    return (http or Http()).get_json(url, init)


# What JavaScript's ?. and ?? do with fields of parsed JSON.


def at(value: Any, *path: str | int) -> Any:
    """value?.a?.b: UNDEFINED where a step is null, undefined, or missing. A null field stays None."""
    for key in path:
        if value is None or value is _js.UNDEFINED:
            return _js.UNDEFINED
        value = _js.get(value, key)
    return value


def either(value: Any, otherwise: Any) -> Any:
    """value ?? otherwise"""
    return otherwise if value is None or value is _js.UNDEFINED else value


def defined(fields: dict[str, Any]) -> dict[str, Any]:
    """An object as JSON.stringify keeps it: the fields holding undefined left out."""
    return {k: v for k, v in fields.items() if v is not _js.UNDEFINED}


def items(value: Any) -> list[Any]:
    """A value TypeScript iterates with for...of or .map, which throws when it is no array."""
    if not isinstance(value, list):
        raise TypeError(f"{_js.string(value)} is not iterable")
    return value


def credential(credentials: dict[str, Any], name: str) -> str:
    """credentials[name]?.trim() ?? "": a credential as text, "" when it was not given."""
    value = credentials.get(name)
    return "" if value is None else _js.trim(str(value))


def positive(value: Any) -> bool:
    """value > 0, as JavaScript compares a value it reads from JSON."""
    n = _js.number(value)
    return not math.isnan(n) and n > 0


# Date.parse and toISOString.

_ISO = re.compile(
    r"([+-]\d{6}|\d{4})(?:-(\d{2})(?:-(\d{2}))?)?(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}:\d{2})?)?\Z",
    re.I | re.ASCII,
)
# The forms V8's fallback parser takes that services send: a date with - or /, a time after T or a space, and
# a zone of Z, UTC, GMT, or an offset with or without its colon. Without a zone it is local time.
_LEGACY = re.compile(
    r"(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?"
    r"(?:\s*(Z|UTC|GMT)|([+-])(\d{2}):?(\d{2}))?\Z",
    re.I | re.ASCII,
)


def _days_in(year: int, month: int) -> int:
    if month == 2:
        return 29 if (year % 4 == 0 and year % 100 != 0) or year % 400 == 0 else 28
    return 30 if month in (4, 6, 9, 11) else 31


def _days_from_civil(y: int, m: int, d: int) -> int:
    y -= 1 if m <= 2 else 0
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _utc_ms(year: int, month: int, day: int, hour: int, minute: int, second: int, ms: int) -> int:
    return ((_days_from_civil(year, month, day) * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + ms


def _local(utc: int) -> int:
    """A wall-clock time in the process's zone as epoch milliseconds, as JavaScript reads a time with no zone."""
    seconds = utc // 1000
    try:
        offset = time.localtime(seconds).tm_gmtoff
        offset = time.localtime(seconds - offset).tm_gmtoff
    except (OverflowError, OSError, ValueError):
        offset = 0
    return utc - offset * 1000


def parse_date(text: Any) -> int | float:
    """Date.parse: milliseconds, or NaN for text that is not a date. The ISO forms are read as JavaScript reads
    them (a date alone is UTC, a date and time without an offset is local time); other forms as V8's fallback
    parser reads the ones services send."""
    if not isinstance(text, str):
        if text is None or text is _js.UNDEFINED:
            return math.nan
        text = _js.string(text)
    text = _js.trim(text)
    m = _ISO.match(text)
    if m:
        year = int(m.group(1))
        month = int(m.group(2)) if m.group(2) else 1
        day = int(m.group(3)) if m.group(3) else 1
        timed = m.group(4) is not None
        hour = int(m.group(4)) if timed else 0
        minute = int(m.group(5)) if timed else 0
        second = int(m.group(6)) if m.group(6) else 0
        ms = int(m.group(7).ljust(3, "0")[:3]) if m.group(7) else 0
        if (
            m.group(1) == "-000000"
            or not 1 <= month <= 12
            or not 1 <= day <= _days_in(year, month)
            or hour > 24
            or minute > 59
            or second > 59
            or (hour == 24 and (minute or second or ms))
        ):
            return math.nan
        zone = m.group(8) or ""
        utc = _utc_ms(year, month, day, hour, minute, second, ms)
        if zone.upper() == "Z" or (not timed and zone == ""):
            return utc
        if zone:
            sign = -1 if zone[0] == "-" else 1
            return utc - sign * (int(zone[1:3]) * 60 + int(zone[4:6])) * 60_000
        return _local(utc)
    m = _LEGACY.match(text)
    if m:
        year, month, day = int(m.group(1)), int(m.group(2)), int(m.group(3))
        hour = int(m.group(4)) if m.group(4) else 0
        minute = int(m.group(5)) if m.group(5) else 0
        second = int(m.group(6)) if m.group(6) else 0
        ms = int(m.group(7).ljust(3, "0")[:3]) if m.group(7) else 0
        if not 1 <= month <= 12 or not 1 <= day <= _days_in(year, month) or hour > 24 or minute > 59 or second > 59:
            return math.nan
        utc = _utc_ms(year, month, day, hour, minute, second, ms)
        if m.group(8):
            return utc
        if m.group(9):
            sign = -1 if m.group(9) == "-" else 1
            return utc - sign * (int(m.group(10)) * 60 + int(m.group(11))) * 60_000
        return _local(utc)
    if not re.search(r"\d", text):
        return math.nan
    parsed = email.utils.parsedate_tz(text)
    if parsed is None:
        return math.nan
    year, month, day, hour, minute, second = parsed[:6]
    if not 1 <= month <= 12 or not 1 <= day <= _days_in(year, month):
        return math.nan
    utc = _utc_ms(year, month, day, hour, minute, second, 0)
    return _local(utc) if parsed[9] is None else utc - parsed[9] * 1000


def iso_string(ms: Any) -> str:
    """new Date(ms).toISOString(); a RangeError for a time out of range."""
    if not _js.is_finite(ms) or abs(ms) > 8_640_000_000_000_000:
        raise _js.RangeError("Invalid time value")
    # TimeClip truncates toward zero.
    ms = int(ms)
    at = datetime.datetime(1970, 1, 1, tzinfo=datetime.UTC) + datetime.timedelta(milliseconds=ms) if -62135596800000 <= ms < 253402300800000 else None
    if at is not None:
        return at.strftime("%Y-%m-%dT%H:%M:%S.") + f"{at.microsecond // 1000:03d}Z"
    days, rest = divmod(ms, 86_400_000)
    y, mo, d = _civil(days)
    year = f"{y:04d}" if 0 <= y <= 9999 else ("-" if y < 0 else "+") + f"{abs(y):06d}"
    h, rest = divmod(rest, 3_600_000)
    mi, rest = divmod(rest, 60_000)
    s, milli = divmod(rest, 1000)
    return f"{year}-{mo:02d}-{d:02d}T{h:02d}:{mi:02d}:{s:02d}.{milli:03d}Z"


def _civil(days: int) -> tuple[int, int, int]:
    z = days + 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return yoe + era * 400 + (1 if m <= 2 else 0), m, d
