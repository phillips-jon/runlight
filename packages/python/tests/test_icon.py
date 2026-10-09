"""A site's icon: the links picked as TypeScript picks them, and the fetches with their caps."""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from support import fixtures
from support.fake_fetcher import FakeFetcher

from runlight import icon
from runlight.http import Response
from runlight.icon import fetch_icon, icon_links


@pytest.fixture(autouse=True)
def empty_cache() -> Iterator[None]:
    icon._cache.clear()
    yield
    icon._cache.clear()


def urls(fetcher: FakeFetcher) -> list[str]:
    return [r["url"] for r in fetcher.requests]


def test_icon_links_match_typescript() -> None:
    for case in fixtures.load("outbound")["icons"]:
        assert icon_links(case["html"], case["base"]) == case["links"], case["html"]


def test_the_best_linked_icon_is_fetched_with_its_caps() -> None:
    # An address as the origin, so no name is looked up.
    origin = "https://93.184.215.14"
    answers = {
        "https://93.184.215.14/": lambda: Response(
            '<link rel="apple-touch-icon" href="/touch.png"><link rel="icon" href="/i.svg">',
            200,
            {"content-type": "text/html; charset=utf-8"},
        ),
        "https://93.184.215.14/touch.png": lambda: Response("<html>", 200, {"content-type": "text/html"}),
        "https://93.184.215.14/i.svg": lambda: Response("<svg/>", 200, {"content-type": "Image/SVG+xml; charset=utf-8"}),
    }
    fetcher = FakeFetcher(lambda url, init: answers[url]() if url in answers else Response("", 404))
    now = 1_791_471_600_000
    got = fetch_icon(origin, now, fetcher)
    assert got == {"body": b"<svg/>", "type": "image/svg+xml"}
    assert urls(fetcher) == ["https://93.184.215.14/", "https://93.184.215.14/touch.png", "https://93.184.215.14/i.svg"]
    assert fetcher.inits[0]["maxBytes"] == 200_000
    assert fetcher.inits[0]["truncate"] is True
    assert fetcher.inits[1]["maxBytes"] == 262_144
    # An image must arrive whole.
    assert "truncate" not in fetcher.inits[1]
    assert fetcher.inits[0]["headers"]["user-agent"] == "Runlight (+https://runlight.sh)"
    assert fetcher.inits[0]["timeoutMs"] <= 4000

    # Cached for a day.
    assert fetch_icon(origin, now + 86_399_000, fetcher) == got
    assert len(urls(fetcher)) == 3
    # And looked up again after it.
    fetch_icon(origin, now + 86_400_000, fetcher)
    assert len(urls(fetcher)) == 6


def test_favicon_is_the_fallback_and_no_icon_is_remembered_for_an_hour() -> None:
    origin = "https://1.1.1.1"
    fetcher = FakeFetcher(
        lambda url, init: Response("", 200, {"content-type": "image/x-icon"})
        if url == "https://1.1.1.1/favicon.ico"
        else Response("nope", 500)
    )
    now = 1_791_471_600_000
    # An empty image is no icon.
    assert fetch_icon(origin, now, fetcher) is None
    assert urls(fetcher) == ["https://1.1.1.1/", "https://1.1.1.1/favicon.ico"]
    assert fetch_icon(origin, now + 3_599_000, fetcher) is None
    assert len(urls(fetcher)) == 2
    fetch_icon(origin, now + 3_600_000, fetcher)
    assert len(urls(fetcher)) == 4


def test_an_image_longer_than_the_cap_is_no_icon() -> None:
    big = b"x" * (256 * 1024 + 1)
    fetcher = FakeFetcher(
        lambda url, init: Response(big, 200, {"content-type": "image/png"}) if url.endswith(".ico") else Response("", 404)
    )
    assert fetch_icon("https://1.1.1.1", 0, fetcher) is None


def test_a_private_origin_is_never_fetched() -> None:
    fetcher = FakeFetcher(lambda url, init: Response("x", 200, {"content-type": "image/png"}))
    assert fetch_icon("https://192.168.1.1", 0, fetcher) is None
    assert urls(fetcher) == []
