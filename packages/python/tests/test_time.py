"""The TypeScript SDK's time tests, then the fixture written from it."""

from __future__ import annotations

import calendar
import hashlib
from datetime import datetime, timezone

from support import fixtures

from runlight import _js
from runlight.time import PERIODS, add_days, add_months, buckets, compare_range, is_date, is_timezone, local_date
from runlight.time import local_weekday_hour, resolve_range, start_of


def iso(ms: int) -> str:
    return datetime.fromtimestamp(ms // 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + f".{ms % 1000:03d}Z"


def utc(y: int, m: int, d: int = 1, h: int = 0, i: int = 0) -> int:
    """Date.UTC, months from 0."""
    return calendar.timegm((y, m + 1, d, h, i, 0)) * 1000


def test_a_local_day_starts_at_local_midnight() -> None:
    assert iso(start_of("2026-07-01", "Europe/London")) == "2026-06-30T23:00:00.000Z"
    assert iso(start_of("2026-01-15", "America/Toronto")) == "2026-01-15T05:00:00.000Z"
    assert iso(start_of("2026-01-15", "Asia/Kolkata")) == "2026-01-14T18:30:00.000Z"
    assert iso(start_of("2026-01-15", "UTC")) == "2026-01-15T00:00:00.000Z"


def test_the_spring_dst_change_makes_a_23_hour_day() -> None:
    range = resolve_range({"from": "2026-03-07", "to": "2026-03-09"}, "America/Toronto", utc(2026, 2, 10))
    days = buckets(range, "America/Toronto")
    assert [(d["end"] - d["start"]) // 3_600_000 for d in days] == [24, 23, 24]


def test_named_periods_resolve_in_the_sites_timezone() -> None:
    now = utc(2026, 9, 6, 2)  # 2026-10-06 02:00 UTC is still the 5th in Toronto
    assert local_date(now, "America/Toronto") == "2026-10-05"
    today = resolve_range({"period": "today"}, "America/Toronto", now)
    assert today["fromDate"] == "2026-10-05"
    assert today["interval"] == "hour"
    week = resolve_range({"period": "7d"}, "UTC", now)
    assert week["fromDate"] == "2026-09-30"
    assert week["toDate"] == "2026-10-06"
    last_month = resolve_range({"period": "last_month"}, "UTC", now)
    assert [last_month["fromDate"], last_month["toDate"]] == ["2026-09-01", "2026-09-30"]
    assert resolve_range({"period": "12mo"}, "UTC", now)["interval"] == "month"
    assert resolve_range({"period": "nope"}, "UTC", now) is None
    assert resolve_range({"from": "2026-10-05", "to": "2026-10-01"}, "UTC", now) is None
    assert resolve_range({"from": "2026-02-30", "to": "2026-03-01"}, "UTC", now) is None


def test_month_buckets_start_on_the_first() -> None:
    range = resolve_range({"from": "2026-01-15", "to": "2026-03-10", "interval": "month"}, "UTC", utc(2026, 3, 1))
    months = buckets(range, "UTC")
    assert len(months) == 3
    assert iso(months[0]["start"]) == "2026-01-15T00:00:00.000Z"
    assert iso(months[1]["start"]) == "2026-02-01T00:00:00.000Z"
    assert iso(months[2]["end"]) == "2026-03-11T00:00:00.000Z"


def test_comparison_ranges_previous_a_year_back_custom_and_off() -> None:
    now = utc(2026, 9, 6, 12)
    week = resolve_range({"period": "7d"}, "UTC", now)
    prev = compare_range(week, "previous", "UTC")
    assert [prev["fromDate"], prev["toDate"]] == ["2026-09-23", "2026-09-29"]
    assert prev["to"] == week["from"]
    year = compare_range(week, "year", "UTC")
    assert [year["fromDate"], year["toDate"]] == ["2025-09-30", "2025-10-06"]
    leap = compare_range(resolve_range({"from": "2028-02-29", "to": "2028-02-29"}, "UTC", now), "year", "UTC")
    assert leap["fromDate"] == "2027-02-28"
    custom = compare_range(week, "custom", "UTC", {"from": "2026-01-01", "to": "2026-01-07"})
    assert custom["fromDate"] == "2026-01-01"
    assert compare_range(week, "custom", "UTC", {"from": "2026-01-07", "to": "2026-01-01"}) is None
    assert compare_range(week, "off", "UTC") is None


def test_a_day_whose_midnight_is_skipped_by_the_clocks_begins_when_they_land() -> None:
    # Santiago, Havana, and the Azores move their clocks forward at midnight.
    for date, zone, start in [
        ("2026-09-06", "America/Santiago", "2026-09-06T04:00:00.000Z"),
        ("2026-03-08", "America/Havana", "2026-03-08T05:00:00.000Z"),
        ("2026-03-29", "Atlantic/Azores", "2026-03-29T01:00:00.000Z"),
    ]:
        at = start_of(date, zone)
        assert iso(at) == start, zone
        assert local_date(at, zone) == date
        assert local_date(at - 1, zone) != date


def test_a_date_with_a_month_or_day_that_does_not_exist_is_not_a_date() -> None:
    for bad in ["2026-13-01", "2026-00-05", "2026-02-30", "2026-04-31", "2026-1-01", "9999-12-31", "0001-01-01"]:
        assert not is_date(bad), bad
    assert is_date("2028-02-29")


# ICU's System V zones with summer time keep the United States rules of their day, which no zone in the time
# zone database has; their names are taken, and they follow today's rules here.
SYSTEM_V_SUMMER = [
    "systemv/ast4adt", "systemv/est5edt", "systemv/cst6cdt", "systemv/mst7mdt", "systemv/pst8pdt", "systemv/yst9ydt",
]  # fmt: skip

# The fixture came from Node's ICU with time zone data 2025c. The system's database may be newer, and disagree
# wherever a zone's rules changed since: these zones' later instants are not compared.
CHANGED_SINCE_2025C = {
    "America/Vancouver", "Canada/Pacific", "America/Edmonton", "America/Yellowknife", "Canada/Mountain",
    "Africa/Casablanca", "Africa/El_Aaiun",
}  # fmt: skip


def changed(zone: str, ts: int) -> bool:
    # The changes since 2025c (British Columbia and Alberta keeping summer time, Morocco's Ramadan dates) start in
    # 2026.
    return zone in CHANGED_SINCE_2025C and ts >= utc(2026, 0)


def test_zones() -> None:
    fixture = fixtures.load("time")
    failures = []
    # Before 1970 ICU follows the time zone database's backzone history, where zones that are now links
    # (Africa/Bamako, Europe/Oslo) kept their own clocks; the system's database has only the links, so instants
    # before 1970 are compared for the focus zones alone, in test_instants_around_every_offset_change.
    since_1970 = [(i, ts) for i, ts in enumerate(fixture["sampleTimes"]) if ts >= 0]
    for zone in fixture["zones"]:
        valid = is_timezone(zone["name"])
        if valid != zone["valid"]:
            failures.append(zone["name"] + (" taken" if valid else " refused"))
            continue
        if not valid or zone["name"].lower() in SYSTEM_V_SUMMER:
            continue
        for i, ts in since_1970:
            if changed(zone["name"], ts):
                continue
            weekday, hour = local_weekday_hour(ts, zone["name"])
            local = f"{local_date(ts, zone['name'])} {weekday} {hour}"
            if local != zone["local"][i]:
                failures.append(f"{zone['name']} at {ts}: {local} not {zone['local'][i]}")
    assert len(fixture["zones"]) > 600
    assert failures == []


def test_instants_around_every_offset_change() -> None:
    failures = []
    instants = fixtures.load("time")["instants"]
    for zone, ts, date, weekday, hour in instants:
        if changed(zone, ts):
            continue
        got = [local_date(ts, zone), *local_weekday_hour(ts, zone)]
        if got != [date, weekday, hour]:
            failures.append(f"{zone} {ts}: {got} not {date} {weekday} {hour}")
    assert len(instants) > 10000
    assert failures[:30] == []


def test_day_starts() -> None:
    fixture = fixtures.load("time")
    failures = []
    for zone, date, hour, start in fixture["starts"]:
        if changed(zone, start):
            continue
        got = start_of(date, zone, hour)
        if got != start:
            failures.append(f"{zone} {date} {hour}: {got} not {start}")
    for zone, year, sha in fixture["dayStarts"]:
        if changed(zone, utc(year, 11, 31)):
            continue
        days = []
        d = f"{year}-01-01"
        while d < f"{year + 1}-01-01":
            days.append(start_of(d, zone))
            d = add_days(d, 1)
        if hashlib.sha256(_js.dumps(days).encode()).hexdigest() != sha:
            failures.append(f"{zone} {year}: every day's start")
    assert failures[:30] == []


def test_date_math() -> None:
    for case in fixtures.load("time")["dates"]:
        date = case["date"]
        assert is_date(date) == case["isDate"], date
        if case["plus"] is not None:
            assert [add_days(date, n) for n in [-400, -366, -365, -31, -1, 0, 1, 28, 29, 31, 365, 366, 1000]] == case[
                "plus"
            ], date
            assert [add_months(date, n) for n in [-25, -12, -11, -1, 0, 1, 11, 12, 13]] == case["months"], date
    assert PERIODS == fixtures.load("time")["periods"]


def test_ranges_and_buckets() -> None:
    failures = []
    ranges = fixtures.load("time")["ranges"]
    for case in ranges:
        range = resolve_range(case["input"], case["zone"], case["now"], case["firstDate"])
        got: dict = {"range": range}
        want: dict = {"range": case["range"]}
        if range is not None:
            parts = buckets(range, case["zone"])
            got["buckets"] = {
                "count": len(parts),
                "first": parts[0] if parts else None,
                "sha256": hashlib.sha256(_js.dumps(parts).encode()).hexdigest(),
            }
            want["buckets"] = case["buckets"]
            if "compare" in case:
                got["compare"] = {
                    mode: compare_range(range, mode, case["zone"], {"from": "2025-02-28", "to": "2025-03-31"})
                    for mode in ["previous", "year", "off", "custom", "nope"]
                }
                want["compare"] = case["compare"]
        if _js.dumps(got) != _js.dumps(want):
            failures.append(f"{fixtures.label([case['zone'], case['now'], case['input']])} gave {got} not {want}")
    assert len(ranges) > 2000
    assert failures[:20] == []


def test_compare_ranges() -> None:
    for case in fixtures.load("time")["compares"]:
        got = compare_range(case["range"], case["mode"], case["zone"], case["custom"])
        assert _js.dumps(got) == _js.dumps(case["compare"]), fixtures.label(case)
