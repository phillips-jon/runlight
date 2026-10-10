"""Visit history from Umami and from CSV files, as visits-import*.test.ts and visits-csv.test.ts test it at the store
(PHP tests/Core/VisitsImportTest.php)."""

from __future__ import annotations

import datetime
import math
import time
from typing import Any

import pytest
from support.databases import kinds
from support.store import WatchedDb
from test_import_step import Router

from runlight import _js
from runlight.http import Request, Url
from runlight.importers import ImportError
from runlight.importers.csvvisits import csv_format, row_time
from runlight.importers.visits import import_csv_visits, import_umami_visits, umami_websites

DAY = 86_400_000
CREDENTIALS = {"url": "https://umami.example.com", "apiKey": "key"}
CHROME_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"


def at(iso: str) -> int:
    """Date.parse of an ISO time."""
    return int(datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)


class Harness:
    """A Runlight on a fresh database with a clock the test moves, as helpers.ts's setup() is."""

    def __init__(self, store: Any, options: dict[str, Any]) -> None:
        from runlight import Runlight

        self.now = 0
        self.rl = Runlight({"store": store, "now": lambda: self.now, **options})

    def store(self) -> Any:
        return self.rl.store

    def advance(self, ms: int) -> None:
        self.now += ms

    def query(self, from_: str, to: str) -> dict[str, Any]:
        from runlight.time import add_days, start_of

        row = self.rl.site(None)
        tz = row["timezone"]
        return {"site": row["id"], "from": start_of(from_, tz), "to": start_of(add_days(to, 1), tz), "filters": []}

    def stats(self, query: dict[str, Any]) -> dict[str, Any]:
        return self.store().stats(query)

    def values(self, query: dict[str, Any], dimension: str) -> list[Any]:
        return [r["value"] for r in self.store().breakdown(query, dimension, 10, 0)]


def hit(url: str, body: dict[str, Any], ip: str) -> Request:
    headers = {"user-agent": CHROME_MAC, "x-forwarded-for": ip, "content-type": "text/plain;charset=UTF-8"}
    return Request(url, "POST", headers, _js.dumps(body))


def store_of(databases: Any, kind: str) -> Any:
    from runlight.store import Stores

    return Stores.from_db(databases.db(kind))


def umami(events: list[dict[str, Any]], sessions: list[dict[str, Any]] | None = None, created: str = "2026-03-01T08:00:00Z", newest_first: bool = True) -> Router:
    """A small Umami: one website, events answered by time window like the real API, newest first."""
    sessions = sessions or []

    def inside(url: Url) -> list[dict[str, Any]]:
        q = url.search_params
        start, end = int(q.get("startAt")), int(q.get("endAt"))
        rows = [e for e in events if start <= at(e["createdAt"]) <= end]
        return rows[::-1] if newest_first else rows

    def window(url: Url, init: Any) -> dict[str, Any]:
        rows = inside(url)
        return {"data": rows, "count": len(rows)}

    return Router(
        [
            (r"/api/websites\?", lambda u, i: {"data": [{"id": "w1", "name": "Blog", "domain": "blog.example.com"}], "count": 1}),
            (r"/api/websites/w1$", lambda u, i: {"id": "w1", "createdAt": created}),
            (r"/api/websites/w1/events\?", window),
            (r"/api/websites/w1/sessions\?", lambda u, i: {"data": sessions, "count": len(sessions)}),
        ]
    )


def fake_events() -> list[dict[str, Any]]:
    common = {"hostname": "blog.example.com", "country": "CA", "city": "Toronto", "device": "mobile", "os": "iOS", "browser": "ios"}
    gb = {"hostname": "blog.example.com", "country": "GB", "city": "London", "device": "desktop", "os": "Mac OS", "browser": "chrome"}
    return [
        # Visit 1: Google, two pages and a signup, in Toronto on a phone.
        {"sessionId": "s1", "createdAt": "2026-03-01T10:00:00.000Z", "urlPath": "/", "urlQuery": "utm_campaign=spring", "referrerDomain": "www.google.com", "referrerPath": "/", "pageTitle": "Home", "eventType": 1, **common},  # noqa: E501
        {"sessionId": "s1", "createdAt": "2026-03-01T10:02:00.000Z", "urlPath": "/pricing", "pageTitle": "Pricing", "eventType": 1, **common},
        {"sessionId": "s1", "createdAt": "2026-03-01T10:03:00.000Z", "urlPath": "/pricing", "eventType": 2, "eventName": "Signup", **common},
        # The same Umami session two hours later is a second visit.
        {"sessionId": "s1", "createdAt": "2026-03-01T12:30:00.000Z", "urlPath": "/blog", "eventType": 1, **common},
        # Visit 3: direct, desktop, the next day.
        {"sessionId": "s2", "createdAt": "2026-03-02T09:00:00.000Z", "urlPath": "/", "eventType": 1, **gb},
        # A performance event is not a visit.
        {"sessionId": "s2", "createdAt": "2026-03-02T09:00:01.000Z", "urlPath": "/", "eventType": 5, **gb},
    ]


SESSIONS = [
    {"id": "s1", "screen": "390x844", "language": "en-CA", "region": "CA-ON"},
    {"id": "s2", "screen": "1440x900", "language": "en-GB", "region": "GB-ENG"},
]


def harness(store: Any, router: Router, now: int, timezone: str = "UTC") -> Harness:
    t = Harness(store, {"site": {"hostnames": ["blog.example.com"], "timezone": timezone}, "fetcher": router})
    t.now = now
    return t


def import_all(t: Harness, credentials: dict[str, str] = CREDENTIALS) -> dict[str, int]:
    cursor = None
    totals = {"pageviews": 0, "events": 0, "visits": 0, "steps": 0}
    while True:
        step = import_umami_visits(t.rl, "default", credentials, "w1", cursor)
        cursor = step["cursor"]
        for key in ("pageviews", "events", "visits"):
            totals[key] += step[key]
        totals["steps"] += 1
        assert step["done"] <= step["total"]
        if cursor is None:
            return totals


def test_umami_is_asked_only_at_a_public_https_address_and_follows_no_redirect() -> None:
    router = umami(fake_events(), SESSIONS)
    with pytest.raises(ImportError) as raised:
        umami_websites({"url": "http://umami.example.com", "apiKey": "key"}, router)
    assert raised.value.code == "import_umami_address"
    for url in ["https://10.0.0.2", "https://127.0.0.1:3000", "https://169.254.169.254", "https://localhost"]:
        with pytest.raises(ImportError) as raised:
            umami_websites({"url": url, "apiKey": "key"}, router)
        assert raised.value.code == "unreachable", url
    assert router.requests == [], "nothing is asked of an address off the public internet, nor asked again"


@pytest.mark.parametrize("kind", kinds())
def test_umami_visit_history_pageviews_and_events_become_visits_with_sources_places_and_devices(databases: Any, kind: str) -> None:
    router = umami(fake_events(), SESSIONS)
    assert umami_websites(CREDENTIALS, router) == [{"id": "w1", "name": "Blog", "domain": "blog.example.com"}]
    t = harness(store_of(databases, kind), router, at("2026-03-04T00:00:00Z"))
    totals = import_all(t)
    assert {k: totals[k] for k in ("pageviews", "events", "visits")} == {"pageviews": 4, "events": 1, "visits": 3}
    for r in router.requests:
        assert Router.authorization(r["init"]) == "Bearer key", "every request carries the key"

    q = t.query("2026-03-01", "2026-03-03")
    stats = t.stats(q)
    assert stats["pageviews"] == 4
    assert stats["visits"] == 3
    assert stats["visitors"] == 2, "one Umami session on one day is one visitor"
    assert stats["visitDuration"] > 0, "imported visits take their length from first to last pageview"
    assert t.values(q, "source") == ["Google"]
    assert sorted(t.values(q, "region")) == ["CA-ON", "GB-ENG"]
    assert sorted(t.values(q, "browser")) == ["Chrome", "Safari"]
    assert t.values(q, "event") == ["Signup"]
    assert t.values(q, "utm_campaign") == ["spring"]

    # Running it again carries on from where it stopped, so nothing doubles.
    t.advance(DAY)
    again = import_umami_visits(t.rl, "default", CREDENTIALS, "w1", None)
    assert again["pageviews"] == 0
    assert t.stats(q)["pageviews"] == 4

    # No imported visitor id lasts past a day.
    days: dict[str, set[str]] = {}
    for r in t.store().db.all("SELECT visitor, ts FROM rl_events"):
        days.setdefault(r["visitor"], set()).add(time.strftime("%Y-%m-%d", time.gmtime(int(r["ts"]) // 1000)))
    assert all(len(s) == 1 for s in days.values())


def test_umami_visit_history_stops_where_runlights_own_visits_begin(databases: Any) -> None:
    t = harness(store_of(databases, "sqlite"), umami(fake_events(), SESSIONS), at("2026-03-01T23:00:00Z"))
    # Runlight started counting on the evening of March 1st.
    t.rl.collect(hit("https://x.com/runlight/e", {"k": "pageview", "u": "https://blog.example.com/"}, "203.0.113.9"))
    assert import_all(t)["pageviews"] == 3, "March 2nd is left to Runlight"


def test_a_step_that_failed_part_way_can_run_again_without_counting_anything_twice(databases: Any) -> None:
    from runlight.store import SqlStore

    watched = WatchedDb(databases.db("sqlite"))
    t = harness(SqlStore(watched), umami(fake_events(), SESSIONS), at("2026-03-04T00:00:00Z"))
    t.rl.init()
    writes = [0]

    def before(sql: str, params: Any) -> None:
        if sql.startswith("INSERT INTO rl_events"):
            writes[0] += 1
            if writes[0] > 2:
                raise RuntimeError("connection lost")

    watched.before = before
    with pytest.raises(RuntimeError, match="connection lost"):
        import_umami_visits(t.rl, "default", CREDENTIALS, "w1", None)
    watched.before = None
    import_all(t)
    stats = t.stats(t.query("2026-03-01", "2026-03-03"))
    assert stats["pageviews"] == 4
    assert stats["visits"] == 3
    totals = t.store().db.all("SELECT SUM(pageviews) AS pageviews, SUM(events) AS events FROM rl_sessions")[0]
    assert (int(totals["pageviews"]), int(totals["events"])) == (4, 1)


def test_umami_visit_history_skips_days_older_than_the_site_keeps(databases: Any) -> None:
    t = harness(store_of(databases, "sqlite"), umami(fake_events(), SESSIONS), at("2026-09-01T12:00:00Z"))
    t.rl.init()
    # Six months back from September 1st at noon is March 1st at noon, so March 1st is left out.
    t.rl.set_retention("default", 6)
    assert import_all(t)["pageviews"] == 1, "only March 2nd comes in"


def test_an_unreadable_saved_progress_setting_starts_as_if_there_were_none(databases: Any) -> None:
    t = harness(store_of(databases, "sqlite"), umami(fake_events(), SESSIONS), at("2026-03-04T00:00:00Z"))
    t.rl.init()
    t.rl.store.set_setting("import:umami-visits:default:w1", "not a number")
    assert import_all(t)["pageviews"] == 4, "every day is read from the website's start"


def test_an_imported_visit_across_utc_midnight_is_one_visit_on_the_sites_own_day(databases: Any) -> None:
    common = {"hostname": "blog.example.com", "eventType": 1, "country": "CA", "device": "desktop", "os": "Mac OS", "browser": "chrome"}
    events = [
        {"sessionId": "n1", "createdAt": "2026-03-02T23:55:00.000Z", "urlPath": "/", **common},
        {"sessionId": "n1", "createdAt": "2026-03-03T00:05:00.000Z", "urlPath": "/about", **common},
    ]
    router = umami(events, [{"id": "n1"}], "2026-03-02T00:00:00Z", False)
    t = harness(store_of(databases, "sqlite"), router, at("2026-03-10T00:00:00Z"), "America/Toronto")
    import_all(t)
    stats = t.stats(t.query("2026-03-02", "2026-03-02"))
    assert [stats["visits"], stats["visitors"], stats["pageviews"]] == [1, 1, 2]


def ev(session: str, iso: str, path: str, name: str | None = None) -> dict[str, Any]:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(at(iso) // 1000))
    row: dict[str, Any] = {"sessionId": session, "createdAt": stamp, "hostname": "blog.example.com", "urlPath": path, "eventType": 2 if name is not None else 1}
    if name is not None:
        row["eventName"] = name
    return row


@pytest.mark.parametrize("kind", kinds())
def test_an_imported_visit_that_runs_past_midnight_keeps_one_visitor_on_all_its_rows(databases: Any, kind: str) -> None:
    events = [
        ev("s1", "2026-03-01T23:50:00Z", "/a"), ev("s1", "2026-03-02T00:05:00Z", "/b"), ev("s1", "2026-03-02T00:06:00Z", "/b", "Signup"),
        ev("s1", "2026-03-02T10:00:00Z", "/b"), ev("s1", "2026-03-02T10:01:00Z", "/b", "Signup"),
    ]  # fmt: skip
    t = harness(store_of(databases, kind), umami(events, [], "2026-03-01T00:00:00.000Z"), at("2026-03-05T12:00:00Z"))
    import_all(t)
    assert t.store().db.all("SELECT e.id FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.visitor <> s.visitor") == []
    q = t.query("2026-03-01", "2026-03-02")

    def read() -> dict[str, Any]:
        return {
            "pages": [[r["value"], r["visitors"]] for r in t.store().breakdown(q, "page", 10, 0)],
            "events": [[r["value"], r["visitors"]] for r in t.store().breakdown(q, "event", 10, 0)],
        }

    raw = read()
    while t.rl.build_rollups() > 0:
        pass
    assert read() == raw, "the same before and after the days are built"
    assert raw["events"] == [["Signup", 2]]


@pytest.mark.parametrize("kind", kinds())
def test_a_visit_that_crosses_into_the_next_import_step_has_its_first_day_built_again(databases: Any, kind: str) -> None:
    events = [ev("s0", "2026-03-02T10:00:00Z", "/"), ev("s1", "2026-03-14T23:50:00Z", "/a"), ev("s1", "2026-03-15T00:10:00Z", "/b"), ev("s2", "2026-03-20T10:00:00Z", "/")]
    t = harness(store_of(databases, kind), umami(events, [], "2026-03-01T00:00:00.000Z"), at("2026-03-25T12:00:00Z"))
    cursor = import_umami_visits(t.rl, "default", CREDENTIALS, "w1", None)["cursor"]
    # The scheduled check builds days between two steps.
    while t.rl.build_rollups() > 0:
        pass
    while cursor is not None:
        cursor = import_umami_visits(t.rl, "default", CREDENTIALS, "w1", cursor)["cursor"]
    while t.rl.build_rollups() > 0:
        pass
    q = t.query("2026-03-14", "2026-03-14")

    def read() -> dict[str, Any]:
        return {"stats": t.stats(q), "pages": [[r["value"], r["pageviews"]] for r in t.store().breakdown(q, "page", 10, 0)]}

    rolled = read()
    t.store().clear_rollups("default")
    assert read() == rolled
    assert rolled["stats"]["pageviews"] == 2


def test_a_step_cursor_carries_a_sign_in_token_but_never_an_api_key(databases: Any) -> None:
    events = [ev("s0", "2026-03-02T10:00:00Z", "/"), ev("s2", "2026-03-20T10:00:00Z", "/")]
    t = harness(store_of(databases, "sqlite"), umami(events, [], "2026-03-01T00:00:00.000Z"), at("2026-03-25T12:00:00Z"))
    cursor = _js.loads(import_umami_visits(t.rl, "default", CREDENTIALS, "w1", None)["cursor"])
    assert list(cursor.keys()) == ["website", "day", "start", "end"]
    assert cursor["day"] == at("2026-03-15T00:00:00Z"), "fourteen days a step"
    with pytest.raises(ImportError) as caught:
        import_umami_visits(t.rl, "default", CREDENTIALS, "w/1", None)
    assert caught.value.code == "import_website"
    # With a username and password, the sign-in's token rides along instead.
    router = Router([(r"/api/auth/login", lambda u, i: {"token": "tok"}), *umami(events, [], "2026-03-01T00:00:00.000Z").routes])
    signed = harness(store_of(databases, "sqlite"), router, at("2026-03-25T12:00:00Z"))
    following = _js.loads(import_umami_visits(signed.rl, "default", {"url": "https://umami.example.com", "username": "u", "password": "p"}, "w1", None)["cursor"])
    assert following["token"] == "tok"


# CSV

RUNLIGHT_ROWS = [
    {"time": "2026-03-01T10:00:00Z", "url": "https://blog.example.com/?utm_campaign=spring", "referrer": "www.google.com", "visitor": "a", "country": "CA", "region": "CA-ON", "city": "Toronto", "browser": "Safari", "os": "iOS", "device": "mobile", "title": "Home"},  # noqa: E501
    {"time": "2026-03-01T10:02:00Z", "url": "https://blog.example.com/pricing", "visitor": "a", "country": "CA", "browser": "Safari", "os": "iOS", "device": "mobile"},
    {"time": "2026-03-01T10:03:00Z", "url": "https://blog.example.com/pricing", "event": "Signup", "visitor": "a"},
    {"time": "1772442000", "path": "/", "hostname": "blog.example.com", "visitor": "b", "country": "GB", "browser": "Chrome", "os": "macOS", "device": "desktop"},
    # Not a time at all.
    {"time": "yesterday", "path": "/x", "visitor": "c"},
]


def csv(databases: Any, now: int = 0) -> Harness:
    t = Harness(store_of(databases, "sqlite"), {"site": {"hostnames": ["blog.example.com"], "timezone": "UTC"}})
    t.now = now or at("2026-03-04T00:00:00Z")
    return t


def test_csv_in_runlights_format_rows_become_visits_with_sources_places_devices_and_events(databases: Any) -> None:
    t = csv(databases)
    assert import_csv_visits(t.rl, "default", RUNLIGHT_ROWS) == {"pageviews": 3, "events": 1, "visits": 2, "skipped": 1}
    q = t.query("2026-03-01", "2026-03-03")
    stats = t.stats(q)
    assert [stats["pageviews"], stats["visits"], stats["visitors"]] == [3, 2, 2]
    assert t.values(q, "source") == ["Google"]
    assert t.values(q, "utm_campaign") == ["spring"]
    assert t.values(q, "event") == ["Signup"]
    assert sorted(t.values(q, "device")) == ["desktop", "mobile"]
    assert t.values(q, "region") == ["CA-ON"]

    # The same file again replaces what it brought in, so nothing doubles.
    import_csv_visits(t.rl, "default", RUNLIGHT_ROWS)
    assert t.stats(q)["pageviews"] == 3
    assert t.stats(q)["visits"] == 2


def test_csv_in_runlights_format_without_a_visitor_column_every_row_is_its_own_visit(databases: Any) -> None:
    t = csv(databases)
    rows = [{"time": "2026-03-01 10:00:00", "path": "/a"}, {"time": "2026-03-01 10:01:00", "path": "/b?ref=x"}]
    assert import_csv_visits(t.rl, "default", rows)["visits"] == 2
    import_csv_visits(t.rl, "default", rows)
    q = t.query("2026-03-01", "2026-03-03")
    assert t.stats(q)["visits"] == 2, "the same rows get the same ids the second time"
    assert sorted(t.values(q, "page")) == ["/a", "/b"]


def test_csv_from_umamis_export_pageviews_and_named_events_come_across_other_event_types_do_not(databases: Any) -> None:
    t = csv(databases)
    rows = [
        {"website_id": "w1", "session_id": "s1", "created_at": "2026-03-01 10:00:00", "hostname": "blog.example.com", "url_path": "/", "url_query": "", "referrer_domain": "news.ycombinator.com", "page_title": "Home", "event_type": "1", "country": "CA", "subdivision1": "ON", "city": "Toronto", "browser": "ios", "os": "iOS", "device": "mobile", "screen": "390x844", "language": "en-CA"},  # noqa: E501
        {"website_id": "w1", "session_id": "s1", "created_at": "2026-03-01 10:03:00", "hostname": "blog.example.com", "url_path": "/pricing", "event_type": "2", "event_name": "Signup"},
        {"website_id": "w1", "session_id": "s1", "created_at": "2026-03-01 10:03:01", "hostname": "blog.example.com", "url_path": "/pricing", "event_type": "5"},
        {"website_id": "w1", "session_id": "s2", "created_at": "2026-03-02T09:00:00.000Z", "hostname": "blog.example.com", "url_path": "/blog", "event_type": "1", "country": "GB", "browser": "chrome", "os": "Mac OS", "device": "desktop"},  # noqa: E501
    ]
    assert import_csv_visits(t.rl, "default", rows) == {"pageviews": 2, "events": 1, "visits": 2, "skipped": 1}
    q = t.query("2026-03-01", "2026-03-03")
    assert t.values(q, "source") == ["Hacker News"]
    assert t.values(q, "region") == ["CA-ON"]
    assert sorted(t.values(q, "browser")) == ["Chrome", "Safari"]


def test_csv_rows_from_after_runlights_own_first_visit_are_left_to_runlight(databases: Any) -> None:
    t = csv(databases, at("2026-03-01T23:00:00Z"))
    t.rl.collect(hit("https://x.com/runlight/e", {"k": "pageview", "u": "https://blog.example.com/"}, "203.0.113.9"))
    step = import_csv_visits(t.rl, "default", RUNLIGHT_ROWS[:4])
    assert step["pageviews"] == 2, "March 2nd is left to Runlight"
    assert step["skipped"] == 1


def test_a_csv_it_cannot_read_and_a_batch_that_is_too_big_are_refused(databases: Any) -> None:
    t = csv(databases)
    for rows, code in [([{"date": "2026-03-01", "visitors": "12"}], "import_csv_format"), ([RUNLIGHT_ROWS[0]] * 2001, "import_csv_batch"), ("not rows", "import_csv_batch")]:
        with pytest.raises(ImportError) as caught:
            import_csv_visits(t.rl, "default", rows)
        assert caught.value.code == code
    assert import_csv_visits(t.rl, "default", RUNLIGHT_ROWS)["visits"] == 2


def test_csv_times_and_formats() -> None:
    assert csv_format(["created_at", "url_path", "session_id"]) == "umami"
    assert csv_format(["time", "url"]) == "runlight"
    assert csv_format(["date", "visitors"]) is None
    iso = at("2026-03-01T10:00:00Z")
    assert row_time({"time": "2026-03-01 10:00:00"}, "runlight") == iso, "no zone reads as UTC"
    assert row_time({"time": "2026-03-01T12:00:00+02:00"}, "runlight") == iso
    assert row_time({"time": str(iso // 1000)}, "runlight") == iso, "Unix seconds"
    assert row_time({"time": str(iso)}, "runlight") == iso, "Unix milliseconds"
    assert row_time({"created_at": "2026-03-01 10:00:00"}, "umami") == iso
    assert math.isnan(row_time({"time": ""}, "runlight"))
    assert math.isnan(row_time({"time": "yesterday"}, "runlight"))
