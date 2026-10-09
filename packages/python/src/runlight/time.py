"""Dates in a site's timezone, without a date library. Ranges are computed
here as epoch milliseconds so the database only ever compares integers.

A Range is a dict {"from", "to", "fromDate", "toDate", "interval"}: `from` inclusive, `to` exclusive, and the
first and last local dates covered, YYYY-MM-DD, both inclusive. A Bucket is a dict {"start", "end"}.

The TypeScript reads local times through Intl.DateTimeFormat, which knows ICU's zone names. Python's zoneinfo
reads the system's time zone database (or the tzdata package), which knows nearly the same ones, and the
differences are settled here as the PHP port settles them: a name is matched without regard to case, the few
links whose history differs from the zone ICU takes them for (CET, EST, MST) go to that zone, ICU's own extra
names (PST, SystemV/EST5EDT) are added, and "Factory", which ICU refuses, is refused.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone as fixed_zone, tzinfo
from functools import cache
from typing import Any
from zoneinfo import ZoneInfo, available_timezones

from . import _js


PERIODS = ["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"]
INTERVALS = ["hour", "day", "week", "month"]
COMPARE_MODES = ["previous", "year", "custom", "off"]

MAX_BUCKETS = 1000
# A month of hours. Longer hourly ranges are cut off rather than refused.
MAX_HOURS = 744

# Names Intl reads as another zone than the time zone database's own entry, or that only ICU has.
_ALIASES = {
    # Links, or old zones of their own, that ICU reads as these.
    "cet": "Europe/Brussels", "eet": "Europe/Athens", "est": "America/Panama", "gmt": "UTC", "gmt+0": "UTC",
    "gmt-0": "UTC", "hst": "Pacific/Honolulu", "met": "Europe/Brussels", "mst": "America/Phoenix", "uct": "UTC",
    "wet": "Europe/Lisbon",
    # ICU's three letter names, kept from early Java.
    "act": "Australia/Darwin", "aet": "Australia/Sydney", "agt": "America/Argentina/Buenos_Aires",
    "art": "Africa/Cairo", "ast": "America/Anchorage", "bet": "America/Sao_Paulo", "bst": "Asia/Dhaka",
    "cat": "Africa/Maputo", "cnt": "America/St_Johns", "cst": "America/Chicago", "ctt": "Asia/Shanghai",
    "eat": "Africa/Nairobi", "ect": "Europe/Paris", "iet": "America/Indiana/Indianapolis", "ist": "Asia/Kolkata",
    "jst": "Asia/Tokyo", "mit": "Pacific/Apia", "net": "Asia/Yerevan", "nst": "Pacific/Auckland",
    "plt": "Asia/Karachi", "pnt": "America/Phoenix", "prt": "America/Puerto_Rico", "pst": "America/Los_Angeles",
    "sst": "Pacific/Guadalcanal", "vst": "Asia/Ho_Chi_Minh",
    # ICU's System V zones.
    "systemv/ast4": "Etc/GMT+4", "systemv/ast4adt": "America/Halifax", "systemv/est5": "Etc/GMT+5",
    "systemv/est5edt": "America/New_York", "systemv/cst6": "Etc/GMT+6", "systemv/cst6cdt": "America/Chicago",
    "systemv/mst7": "Etc/GMT+7", "systemv/mst7mdt": "America/Denver", "systemv/pst8": "Etc/GMT+8",
    "systemv/pst8pdt": "America/Los_Angeles", "systemv/yst9": "Etc/GMT+9", "systemv/yst9ydt": "America/Anchorage",
    "systemv/hst10": "Etc/GMT+10",
    # Names the database dropped and ICU kept.
    "canada/east-saskatchewan": "America/Regina", "us/pacific-new": "America/Los_Angeles",
}  # fmt: skip

# An offset, as ECMA-402 takes one: a sign (a minus sign too), two digit hours, and optional minutes.
_OFFSET = re.compile("([+\\-]|−)([01][0-9]|2[0-3])(?::?([0-5][0-9]))?\\Z")
_PRINTABLE = re.compile(r"[\x21-\x7e]*\Z")


@cache
def _names() -> dict[str, str]:
    """Lowercase name to the database's name."""
    names = {name.lower(): name for name in available_timezones()}
    # Files some systems keep beside the zones, which are not zone names to ICU.
    for name in ("factory", "localtime", "posixrules", "posix", "right"):
        names.pop(name, None)
    return names


@cache
def _zone(timezone: str) -> tzinfo | None:
    """The zone Intl.DateTimeFormat would use for a timeZone option, or None where it throws a RangeError."""
    m = _OFFSET.match(timezone)
    if m:
        minutes = int(m.group(2)) * 60 + int(m.group(3) or "0")
        return fixed_zone(timedelta(minutes=minutes if m.group(1) == "+" else -minutes))
    if not _PRINTABLE.match(timezone):
        return None
    key = timezone.lower()
    name = _ALIASES.get(key) or _names().get(key)
    if name is None:
        return None
    try:
        return ZoneInfo(name)
    except (ValueError, OSError):
        return None


def is_timezone(value: str) -> bool:
    return _zone(value) is not None


def _parts(ts: int, timezone: str) -> tuple[int, int, int, int, int, int]:
    """Year, month, day, hour, minute, and second of an instant in a zone, as Intl formats them."""
    zone = _zone(timezone)
    if zone is None:
        raise _js.RangeError(f"Invalid time zone specified: {timezone}")
    local = datetime.fromtimestamp(ts // 1000, zone)
    return local.year, local.month, local.day, local.hour, local.minute, local.second


def _offset(ts: int, timezone: str) -> int:
    """Milliseconds the zone is ahead of UTC at an instant."""
    y, mo, d, h, mi, s = _parts(ts, timezone)
    return _utc(y, mo - 1, d, h, mi, s) - (ts - _rem(ts, 1000))


def start_of(date: str, timezone: str, hour: int = 0) -> int:
    """The instant a local date (and hour) begins in a zone."""
    y, m, d = _split(date)
    guess = _utc(y, m - 1, d, hour)
    first = guess - _offset(guess, timezone)
    at = guess - _offset(first, timezone)
    # Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it never
    # happens, and the sum above lands before it; the day then begins when the clocks land, at most a
    # few quarter hours on.
    for _ in range(8):
        ly, lm, ld, lh, _mi, _s = _parts(at, timezone)
        if _utc(ly, lm - 1, ld, lh) >= guess:
            break
        at += 15 * 60_000
    return at


def local_date(ts: int, timezone: str) -> str:
    """The local date of an instant, YYYY-MM-DD."""
    y, m, d, *_ = _parts(ts, timezone)
    return f"{str(y).rjust(4, '0')}-{m:02d}-{d:02d}"


def add_days(date: str, days: int) -> str:
    y, m, d = _split(date)
    return _iso(_utc(y, m - 1, d + days))[:10]


def add_months(date: str, months: int) -> str:
    y, m, _d = _split(date)
    return _iso(_utc(y, m - 1 + months, 1))[:10]


_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\Z")


def is_date(value: str) -> bool:
    # Years from 1900 to 9998, so the day after any date is a date too.
    if not _DATE.match(value) or value < "1900" or value >= "9999":
        return False
    # A month or day that does not exist (2026-13-01) makes no date at all, rather than a wrong one.
    y, m, d = _split(value)
    try:
        datetime(y, m, d)
        return True
    except ValueError:
        return False


def _days_between(start: str, end: str) -> int:
    fy, fm, fd = _split(start)
    ty, tm, td = _split(end)
    return (_utc(ty, tm - 1, td) - _utc(fy, fm - 1, fd)) // 86_400_000


def _default_interval(from_date: str, to_date: str) -> str:
    days = _days_between(from_date, to_date)
    if days < 1:
        return "hour"
    if days <= 92:
        return "day"
    return "month"


def resolve_range(input: dict[str, Any], timezone: str, now: int, first_date: str | None = None) -> dict[str, Any] | None:
    """A named period or custom dates as a range in the site's timezone.
    `first_date` is the earliest local date with data, used by "all"."""
    today = local_date(now, timezone)
    start = input.get("from")
    end = input.get("to")

    if start or end:
        if not start or not end or not is_date(start) or not is_date(end) or start > end:
            return None
        from_date = start
        to_date = end
    else:
        period = input.get("period")
        if period is None:
            period = "30d"
        month_start = f"{today[:8]}01"
        if period == "today":
            from_date = to_date = today
        elif period == "yesterday":
            from_date = to_date = add_days(today, -1)
        elif period == "7d":
            from_date, to_date = add_days(today, -6), today
        elif period == "30d":
            from_date, to_date = add_days(today, -29), today
        elif period == "90d":
            from_date, to_date = add_days(today, -89), today
        elif period == "month":
            from_date, to_date = month_start, today
        elif period == "last_month":
            from_date, to_date = add_months(today, -1), add_days(month_start, -1)
        elif period == "year":
            from_date, to_date = f"{today[:4]}-01-01", today
        elif period == "12mo":
            from_date, to_date = add_months(today, -11), today
        elif period == "all":
            from_date, to_date = (first_date if first_date and first_date < today else today), today
        else:
            return None

    interval = input.get("interval")
    if interval not in INTERVALS:
        interval = _default_interval(from_date, to_date)
    return {
        "from": start_of(from_date, timezone),
        "to": start_of(add_days(to_date, 1), timezone),
        "fromDate": from_date,
        "toDate": to_date,
        "interval": interval,
    }


def _add_years(date: str, years: int) -> str:
    y, m, d = _split(date)
    shifted = _utc(y + years, m - 1, d)
    # Feb 29 in a year without one becomes Feb 28, not Mar 1.
    sy, sm, _sd = _civil(shifted)
    if sm != m:
        # setUTCDate(0): the last day of the month before.
        shifted = _utc(sy, sm - 1, 0)
    return _iso(shifted)[:10]


def compare_range(
    range: dict[str, Any], mode: str, timezone: str, custom: dict[str, Any] | None = None
) -> dict[str, Any] | None:
    """The range a period is compared with: the same number of days just before
    it, the same dates a year earlier, or custom dates. None for "off" or bad
    custom dates."""
    custom = custom or {}
    if mode == "off":
        return None
    if mode == "year":
        from_date = _add_years(range["fromDate"], -1)
        to_date = _add_years(range["toDate"], -1)
    elif mode == "custom":
        start = custom.get("from")
        end = custom.get("to")
        if not start or not end or not is_date(start) or not is_date(end) or start > end:
            return None
        from_date = start
        to_date = end
    else:
        days = _days_between(range["fromDate"], range["toDate"]) + 1
        from_date = add_days(range["fromDate"], -days)
        to_date = add_days(range["fromDate"], -1)
    return {
        "from": start_of(from_date, timezone),
        "to": start_of(add_days(to_date, 1), timezone),
        "fromDate": from_date,
        "toDate": to_date,
        "interval": range["interval"],
    }


def buckets(range: dict[str, Any], timezone: str) -> list[dict[str, int]]:
    """Chart buckets covering a range, each starting on a local boundary."""
    starts: list[int] = []
    if range["interval"] == "hour":
        t = range["from"]
        while t < range["to"] and len(starts) < MAX_HOURS:
            starts.append(t)
            t += 3_600_000
    else:
        date = range["fromDate"]
        if range["interval"] == "week":
            date = add_days(date, -_weekday(date))
        elif range["interval"] == "month":
            date = f"{date[:8]}01"
        while date <= range["toDate"] and len(starts) < MAX_BUCKETS:
            starts.append(start_of(date, timezone))
            if range["interval"] == "day":
                date = add_days(date, 1)
            elif range["interval"] == "week":
                date = add_days(date, 7)
            else:
                date = add_months(date, 1)
    return [
        {"start": max(start, range["from"]), "end": min(starts[i + 1] if i + 1 < len(starts) else range["to"], range["to"])}
        for i, start in enumerate(starts)
    ]


def local_weekday_hour(ts: int, timezone: str) -> tuple[int, int]:
    """Monday is 0."""
    y, m, d, h, *_ = _parts(ts, timezone)
    return _weekday(f"{y:04d}-{m:02d}-{d:02d}"), h


def _weekday(date: str) -> int:
    """Monday is 0."""
    y, m, d = _split(date)
    days = _utc(y, m - 1, d) // 86_400_000
    # 1970-01-01 was a Thursday.
    return (days + 3) % 7


def _split(date: str) -> tuple[int, int, int]:
    """date.split("-").map(Number), for the dates passed here (anything but digits reads as 0)."""
    parts = [int(p) if p.isascii() and p.isdigit() else 0 for p in date.split("-")]
    return parts[0], parts[1] if len(parts) > 1 else 0, parts[2] if len(parts) > 2 else 0


def _rem(a: int, b: int) -> int:
    """JavaScript's %, which takes the sign of the dividend."""
    r = abs(a) % b
    return -r if a < 0 else r


def _utc(year: int, month: int, day: int, hour: int = 0, minute: int = 0, second: int = 0) -> int:
    """Date.UTC: months and days past their ends roll over, and a year from 0 to 99 means 1900 to 1999."""
    if 0 <= year <= 99:
        year += 1900
    year += month // 12
    month = month % 12 + 1
    days = _days_from_civil(year, month, 1) + day - 1
    return days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000


def _days_from_civil(y: int, m: int, d: int) -> int:
    """Days from 1970-01-01 to a proleptic Gregorian date."""
    y -= 1 if m <= 2 else 0
    era = y // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _civil(ms: int) -> tuple[int, int, int]:
    """Year, month, and day of an instant in UTC."""
    z = ms // 86_400_000 + 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return yoe + era * 400 + (1 if m <= 2 else 0), m, d


def _iso(ms: int) -> str:
    """The date part of Date.prototype.toISOString, with its six digit form outside years 0 to 9999."""
    y, m, d = _civil(ms)
    year = f"{y:04d}" if 0 <= y <= 9999 else ("-" if y < 0 else "+") + f"{abs(y):06d}"
    return f"{year}-{m:02d}-{d:02d}"
