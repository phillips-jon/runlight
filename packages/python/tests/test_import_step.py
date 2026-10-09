"""Link imports written into the store, as importers.test.ts tests them (PHP tests/Core/ImportStepTest.php)."""

from __future__ import annotations

import calendar
import re
from collections.abc import Callable
from typing import Any

import pytest

from runlight import _js
from runlight.http import Headers, Response, Url
from runlight.importers import ImportError, import_step
from runlight.importers.write import imported_link_id, write_link

NOW = 1_791_288_000_000


class Router:
    """A Fetcher that answers from a table of URL patterns, recording what was asked, as the TS tests' serve()
    replaces globalThis.fetch. Each answer is a body to send as JSON, or (status, body)."""

    def __init__(self, routes: list[tuple[str, Callable[..., Any]]]) -> None:
        self.routes = routes
        self.calls: list[str] = []
        self.requests: list[dict[str, Any]] = []

    def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
        init = init or {}
        u = Url(url)
        self.calls.append(f"{init.get('method', 'GET')} {u.host}{u.pathname}")
        self.requests.append({"url": url, "init": init})
        for pattern, answer in self.routes:
            if re.search(pattern, u.href):
                result = answer(u, init)
                status, body = result if isinstance(result, tuple) else (200, result)
                return Response(_js.dumps(body), status, {"content-type": "application/json"})
        return Response("{}", 404)

    @staticmethod
    def authorization(init: dict[str, Any]) -> str | None:
        """The authorization header a request carried."""
        return Headers(init.get("headers")).get("authorization")


def utc(y: int, m: int, d: int) -> int:
    return calendar.timegm((y, m, d, 0, 0, 0)) * 1000


def runlight(router: Router | None = None) -> Any:
    from runlight import Runlight
    from runlight.store import Stores

    options: dict[str, Any] = {"store": Stores.sqlite(":memory:"), "now": lambda: NOW}
    if router is not None:
        options["fetcher"] = router
    return Runlight(options)


def run_all(router: Router, source: str, credentials: dict[str, str]) -> tuple[Any, dict[str, Any], Any]:
    rl = runlight(router)
    cursor = None
    done: Any = 0
    totals: dict[str, Any] = {"links": 0, "clicks": 0, "skipped": 0, "failed": []}
    while True:
        step = import_step(rl, "default", source, credentials, cursor, done)
        cursor = step["cursor"]
        done = step["done"]
        for key in ("links", "clicks", "skipped"):
            totals[key] += step[key]
        totals["failed"].extend(step["failed"])
        if cursor is None:
            return rl, totals, done


def links(rl: Any) -> list[dict[str, Any]]:
    return rl.store.links("default", 0, NOW + 1)


def test_dub_every_click_where_the_plan_allows() -> None:
    router = Router(
        [
            (r"api\.dub\.co/links\?.*startingAfter=l2", lambda u, i: []),
            (
                r"api\.dub\.co/links\?",
                lambda u, i: [
                    {"id": "l1", "domain": "dub.sh", "key": "launch", "url": "https://a.com/launch", "title": "Launch", "createdAt": "2026-01-02T00:00:00Z"},
                    {"id": "l2", "domain": "go.brand.com", "key": "sale", "url": "https://a.com/sale", "title": None, "createdAt": "2026-02-03T00:00:00Z"},
                ],
            ),
            (
                r"/events\?.*linkId=l1",
                lambda u, i: [
                    {"timestamp": "2026-03-01T10:00:00Z", "click": {"id": "c1", "country": "CA", "city": "Toronto", "device": "Mobile", "browser": "Chrome", "os": "iOS", "referer": "instagram.com", "refererUrl": "https://instagram.com/"}},  # noqa: E501
                    {"timestamp": "2026-03-02T10:00:00Z", "click": {"id": "c2", "country": "US", "device": "Desktop", "browser": "Safari", "os": "Mac OS", "referer": "(direct)"}},
                ],
            ),
            (r"/events\?.*linkId=l2", lambda u, i: []),
        ]
    )
    rl, totals, _ = run_all(router, "dub", {"apiKey": "dub_test"})
    assert totals["links"] == 2
    assert totals["clicks"] == 2
    by_slug = {link["slug"]: link for link in links(rl)}
    assert by_slug["launch"]["domain"] == "", "dub.sh stays behind; the link moves to /go"
    assert by_slug["sale"]["domain"] == "go.brand.com", "branded domains come across"
    assert rl.store.link_domains()[0] == {"domain": "go.brand.com", "site": "default"}
    session = rl.store.db.all("SELECT country, source, device FROM rl_sessions ORDER BY started_at LIMIT 1")[0]
    assert session == {"country": "CA", "source": "Instagram", "device": "mobile"}
    assert int(rl.store.db.all("SELECT imported FROM rl_sessions LIMIT 1")[0]["imported"]) == 1


def test_dub_daily_counts_when_the_plan_has_no_events_api() -> None:
    router = Router(
        [
            (r"api\.dub\.co/links\?", lambda u, i: [{"id": "l1", "domain": "dub.sh", "key": "x", "url": "https://a.com", "title": "X", "createdAt": "2026-01-02T00:00:00Z"}]),
            (r"/events\?", lambda u, i: (403, {"error": {"message": "Business plan required"}})),
            (r"/analytics\?", lambda u, i: [{"start": "2026-03-01T00:00:00.000Z", "clicks": 3}, {"start": "2026-03-02T00:00:00.000Z", "clicks": 0}]),
        ]
    )
    rl, totals, _ = run_all(router, "dub", {"apiKey": "dub_test"})
    assert totals["clicks"] == 3
    row = links(rl)[0]
    assert row["clicks"] == 3
    assert row["visitors"] == 0, "daily counts add clicks, not made-up visitors"
    times = [int(r["ts"]) for r in rl.store.db.all("SELECT ts FROM rl_events ORDER BY ts")]
    day = utc(2026, 3, 1)
    assert times == [day + 14_400_000, day + 43_200_000, day + 72_000_000], "spread through the day"


def test_bitly_every_group_custom_back_halves_daily_counts() -> None:
    router = Router(
        [
            (r"/v4/groups$", lambda u, i: {"groups": [{"guid": "G1"}, {"guid": "G2"}]}),
            (
                r"/groups/G1/bitlinks",
                lambda u, i: {
                    "links": [
                        {"id": "bit.ly/3abc", "link": "https://bit.ly/3abc", "long_url": "https://a.com/1", "title": "One", "created_at": "2026-01-01T00:00:00+0000", "custom_bitlinks": ["https://t.brand.com/one"]},  # noqa: E501
                        {"id": "bit.ly/gone", "link": "https://bit.ly/gone", "long_url": "https://a.com/x", "title": "Gone", "created_at": "2026-01-01T00:00:00+0000", "is_deleted": True},  # noqa: E501
                    ],
                    "pagination": {"search_after": ""},
                },
            ),
            (
                r"/groups/G2/bitlinks",
                lambda u, i: {"links": [{"id": "bit.ly/4def", "link": "https://bit.ly/4def", "long_url": "https://a.com/2", "title": None, "created_at": "2026-02-01T00:00:00+0000"}], "pagination": {}},
            ),
            (r"/bitlinks/bit\.ly%2F3abc/clicks", lambda u, i: {"link_clicks": [{"clicks": 5, "date": "2026-03-01T00:00:00+0000"}, {"clicks": 2, "date": "2026-03-02T00:00:00+0000"}]}),
            (r"/bitlinks/bit\.ly%2F4def/clicks", lambda u, i: (402, {"message": "UPGRADE_REQUIRED"})),
        ]
    )
    rl, totals, _ = run_all(router, "bitly", {"token": "bitly_test"})
    assert totals["links"] == 2, "the deleted link is skipped"
    assert totals["clicks"] == 7
    assert sorted([link["domain"], link["slug"]] for link in links(rl)) == [["", "4def"], ["t.brand.com", "one"]]


def test_short_io_every_domain_paged_with_daily_counts_in_either_shape() -> None:
    router = Router(
        [
            (r"api\.short\.io/api/domains", lambda u, i: [{"id": 7, "hostname": "s.brand.com"}]),
            (
                r"api/links\?.*pageToken=P2",
                lambda u, i: {"links": [{"idString": "lnk2", "id": 2, "path": "two", "originalURL": "https://a.com/2", "createdAt": "2026-02-01T00:00:00Z"}], "nextPageToken": None},
            ),
            (
                r"api/links\?domain_id=7",
                lambda u, i: {"links": [{"idString": "lnk1", "id": 1, "path": "one", "originalURL": "https://a.com/1", "title": "One", "createdAt": "2026-01-01T00:00:00Z"}], "nextPageToken": "P2"},
            ),
            (r"statistics/link/lnk1/by_interval", lambda u, i: {"clickStatistics": [{"x": "2026-03-01T00:00:00Z", "y": 4}]}),
            (r"statistics/link/lnk2/by_interval", lambda u, i: {"clickStatistics": {"datasets": [{"data": [{"x": utc(2026, 3, 2), "y": 1}]}]}}),
        ]
    )
    _, totals, _ = run_all(router, "shortio", {"apiKey": "sk_test"})
    assert totals["links"] == 2
    assert totals["clicks"] == 5


def test_rebrandly_links_only_paged_by_the_last_id() -> None:
    def page(start: int, n: int) -> list[dict[str, Any]]:
        return [
            {"id": f"r{i}", "slashtag": f"s{i}", "destination": f"https://a.com/{i}", "domain": {"fullName": "rebrand.ly"}, "createdAt": "2026-01-01T00:00:00Z"}
            for i in range(start, start + n)
        ]

    router = Router([(r"/links\?.*last=r24", lambda u, i: page(25, 3)), (r"rebrandly\.com/v1/links\?", lambda u, i: page(0, 25))])
    rl, totals, _ = run_all(router, "rebrandly", {"apiKey": "rb_test"})
    assert totals["links"] == 28
    assert totals["clicks"] == 0
    assert links(rl)[0]["domain"] == "", "rebrand.ly stays behind"


def test_umami_signs_in_with_a_username_and_password_and_re_runs_skip_what_is_there() -> None:
    router = Router(
        [
            (r"/api/auth/login", lambda u, i: {"token": "tok"} if _js.loads(i["body"])["password"] == "pw" else {}),
            (
                r"/api/links\?",
                lambda u, i: {
                    "data": [{"id": "u-1", "name": "Golden", "url": "https://a.com", "slug": "golden", "createdAt": "2026-01-01T00:00:00Z", "deletedAt": None, "customDomain": {"domain": "t.brand.com"}}],  # noqa: E501
                    "count": 1,
                },
            ),
            (
                r"/websites/u-1/events",
                lambda u, i: {
                    "data": [{"sessionId": "s1", "createdAt": "2026-03-01T00:00:00Z", "urlPath": "/golden", "urlQuery": "utm_source=newsletter", "referrerDomain": "", "referrerPath": "", "country": "GB", "city": "London", "device": "mobile", "os": "iOS", "browser": "ios"}],  # noqa: E501
                    "count": 1,
                },
            ),
            (r"/websites/u-1/sessions", lambda u, i: {"data": [{"id": "s1", "screen": "390x844", "language": "en-GB", "region": "ENG"}], "count": 1}),
        ]
    )
    rl = runlight(router)
    creds = {"url": "https://stats.example.com/", "username": "jon", "password": "pw"}
    first = import_step(rl, "default", "umami", creds, None, 0)
    assert first["links"] == 1
    assert first["clicks"] == 1
    assert router.calls[0].startswith("POST stats.example.com/api/auth/login")
    assert rl.store.db.all("SELECT region, source, browser FROM rl_sessions")[0] == {"region": "GB-ENG", "source": "Newsletter", "browser": "Safari"}
    again = import_step(rl, "default", "umami", creds, None, 0)
    assert again["skipped"] == 1
    with pytest.raises(ImportError, match="Umami address"):
        import_step(rl, "default", "umami", {"url": "nope"}, None, 0)
    with pytest.raises(ImportError, match="cannot import") as caught:
        import_step(rl, "default", "nowhere", {}, None, 0)
    assert caught.value.params == {"source": "nowhere"}


def test_umami_a_link_already_here_with_the_same_slug_and_destination_is_skipped_before_its_history_is_fetched() -> None:
    router = Router(
        [
            (
                r"/api/links\?",
                lambda u, i: {"data": [{"id": "u-9", "name": "Golden", "url": "https://a.com/", "slug": "golden", "createdAt": "2026-01-01T00:00:00Z", "deletedAt": None}], "count": 1},
            ),
            (r"/websites/u-9/", lambda u, i: {"data": [], "count": 0}),
        ]
    )
    rl = runlight(router)
    rl.init()
    # Brought in earlier some other way, such as a CSV, so it has no Umami id.
    rl.links.create("default", {"url": "https://a.com", "slug": "golden", "name": "Golden"})
    step = import_step(rl, "default", "umami", {"url": "https://stats.example.com/", "apiKey": "k"}, None, 0)
    assert step["skipped"] == 1
    assert step["links"] == 0
    assert [c for c in router.calls if "/websites/u-9/" in c] == [], "no history was fetched for it"


def test_umami_a_link_list_without_a_count_gives_no_total_and_pages_on_while_pages_are_full() -> None:
    def link(i: int) -> dict[str, Any]:
        return {"id": f"u{i}", "name": f"N{i}", "url": f"https://a.com/{i}", "slug": f"s{i}", "createdAt": "2026-01-01T00:00:00Z", "deletedAt": None}

    router = Router(
        [
            (r"/api/links\?page=1&", lambda u, i: {"data": [link(n) for n in range(5)]}),
            (r"/api/links\?page=2&", lambda u, i: {"data": [link(5)], "count": "six"}),
            (r"/websites/", lambda u, i: {"data": [], "count": 0}),
        ]
    )
    rl = runlight(router)
    creds = {"url": "https://stats.example.com", "apiKey": "k"}
    first = import_step(rl, "default", "umami", creds, None, 0)
    assert first["total"] is None
    assert first["cursor"] is not None, "a full page may have more after it"
    second = import_step(rl, "default", "umami", creds, first["cursor"], first["done"])
    assert [second["cursor"], second["done"], second["total"]] == [None, 6, None]
    empty = import_step(runlight(Router([(r"/api/links\?", lambda u, i: {"data": []})])), "default", "umami", creds, None, 0)
    assert [empty["cursor"], empty["done"], empty["total"]] == [None, 0, None]


def test_a_link_whose_slug_is_taken_or_unusable_is_reported_with_a_code() -> None:
    rl = runlight()
    rl.init()
    rl.links.create("default", {"url": "https://elsewhere.com", "slug": "taken", "name": "Other"})
    taken = write_link(rl, "default", "dub", {"sourceId": "x", "slug": "taken", "domain": "", "name": "X", "url": "https://a.com", "createdAt": 0}, {})
    assert taken == {
        "status": "failed", "clicks": 0, "reason": '/taken is already used by "Other"', "code": "import_slug_taken", "params": {"slug": "taken", "name": "Other"},
    }  # fmt: skip
    bad = write_link(rl, "default", "dub", {"sourceId": "y", "slug": "a/b", "domain": "", "name": "", "url": "https://a.com", "createdAt": 0}, {})
    assert bad["code"] == "import_slug_bad"
    made = write_link(
        rl,
        "default",
        "dub",
        {"sourceId": "z", "slug": "fine", "domain": "www.Go.Brand.com", "name": "", "url": "https://a.com/z", "createdAt": 0},
        {"clicks": [{"ts": 5_000, "visit": "v", "path": "/fine", "query": "?utm_campaign=c"}]},
    )
    assert made == {"status": "created", "clicks": 1}
    link = rl.store.link_by_slug("fine")
    assert [link["domain"], link["name"], link["id"]] == ["go.brand.com", "fine", imported_link_id("dub", "z")]
    assert rl.store.db.all("SELECT utm_campaign FROM rl_sessions")[0]["utm_campaign"] == "c"
    again = write_link(rl, "default", "dub", {"sourceId": "z", "slug": "fine", "domain": "", "name": "", "url": "https://a.com/z", "createdAt": 0}, {})
    assert again == {"status": "skipped", "clicks": 0}, "the same link again"
