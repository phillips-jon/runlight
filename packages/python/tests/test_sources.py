"""The TypeScript SDK's sources tests, then the fixture written from it."""

from __future__ import annotations

from support import fixtures

from runlight import _js
from runlight.http import Url
from runlight.sources import attribute, parse_page, readable_path, recorded_path, source_for_alias, source_for_host
from runlight.sources import strip_www


def visit(url: str, referrer: str = "", internal: list[str] | None = None) -> dict:
    return attribute(parse_page(Url(url)), referrer, internal or [])


def test_no_referrer_and_no_tags_is_direct() -> None:
    assert visit("https://example.com/") == {"referrerHost": "", "referrerPath": "", "source": "", "channel": "Direct"}


def test_search_engines_are_organic_search_by_the_most_specific_host() -> None:
    assert visit("https://example.com/", "https://www.google.co.uk/")["channel"] == "Organic Search"
    assert visit("https://example.com/", "https://www.google.co.uk/")["source"] == "Google"
    assert source_for_host("mail.google.com")["name"] == "Gmail"
    assert source_for_host("gemini.google.com")["name"] == "Gemini"


def test_a_click_id_on_a_search_referrer_is_paid_search() -> None:
    assert visit("https://example.com/?gclid=abc", "https://www.google.com/")["channel"] == "Paid Search"
    assert visit("https://example.com/?utm_source=google&utm_medium=cpc")["channel"] == "Paid Search"


def test_ai_assistants_are_the_ai_channel_by_referrer_or_by_tag() -> None:
    assert visit("https://example.com/post", "https://chatgpt.com/") == {
        "referrerHost": "chatgpt.com",
        "referrerPath": "/",
        "source": "ChatGPT",
        "channel": "AI",
    }
    tagged = visit("https://example.com/post?utm_source=chatgpt.com")
    assert tagged["source"] == "ChatGPT"
    assert tagged["channel"] == "AI"
    assert visit("https://example.com/", "https://www.perplexity.ai/search/x")["source"] == "Perplexity"
    assert visit("https://example.com/", "https://claude.ai/")["channel"] == "AI"


def test_social_email_campaigns_and_referrals() -> None:
    assert visit("https://example.com/", "https://news.ycombinator.com/item?id=1")["source"] == "Hacker News"
    assert visit("https://example.com/", "https://t.co/abc")["channel"] == "Social"
    assert visit("https://example.com/?utm_source=weekly&utm_medium=email")["channel"] == "Email"
    assert visit("https://example.com/?utm_source=newsletter")["channel"] == "Email"
    assert visit("https://example.com/?utm_source=partner&utm_campaign=launch")["channel"] == "Campaign"
    assert visit("https://example.com/?utm_source=partner&utm_campaign=launch")["source"] == "partner"
    assert visit("https://example.com/", "https://someblog.net/post")["channel"] == "Referral"
    assert visit("https://example.com/", "https://someblog.net/post")["source"] == "someblog.net"
    assert visit("https://example.com/?ref=producthunt")["source"] == "Product Hunt"


def test_the_sites_own_hosts_are_not_a_referrer() -> None:
    assert visit("https://example.com/b", "https://www.example.com/a")["channel"] == "Direct"
    assert visit("https://example.com/b", "https://shop.example.com/a", ["shop.example.com"])["referrerHost"] == ""
    assert visit("https://example.com/b", "not a url")["channel"] == "Direct"


def test_only_the_path_and_campaign_parameters_are_kept_from_a_url() -> None:
    page = parse_page(Url("https://www.example.com/a/b?email=x@y.z&utm_campaign=spring&fbclid=123#top"))
    assert page["hostname"] == "example.com"
    assert page["path"] == "/a/b#top"
    assert page["utm"]["campaign"] == "spring"
    assert page["paid"] is True
    assert "x@y.z" not in _js.dumps(page)
    assert "123" not in _js.dumps(page)


def test_app_referrers_email_click_trackers_and_webmail_are_named() -> None:
    assert source_for_host("com.google.android.gm")["name"] == "Gmail"
    assert visit("https://example.com/", "android-app://com.google.android.gm/")["source"] == "Gmail"
    assert visit("https://example.com/", "https://com.google.android.gm/")["channel"] == "Email"
    assert visit("https://example.com/", "https://15a992bb.click.convertkit-mail4.com/x")["source"] == "Kit"
    assert visit("https://example.com/", "https://15a992bb.click.convertkit-mail4.com/x")["channel"] == "Email"
    assert visit("https://example.com/", "https://mail01.orange.fr/")["source"] == "mail01.orange.fr"
    assert visit("https://example.com/", "https://mail01.orange.fr/")["channel"] == "Email"
    assert visit("https://example.com/", "https://mail.aol.com/")["channel"] == "Email"
    # Only mail. or webmail. prefixes count.
    assert visit("https://example.com/", "https://mailbox.org/")["channel"] == "Referral"


def test_hosts_and_aliases() -> None:
    fixture = fixtures.load("sources")
    for case in fixture["hosts"]:
        assert source_for_host(case["host"]) == case["source"], fixtures.label(case["host"])
    for case in fixture["aliases"]:
        assert source_for_alias(case["alias"]) == case["source"], fixtures.label(case["alias"])
    for case in fixture["stripWww"]:
        assert strip_www(case["input"]) == case["host"], fixtures.label(case["input"])


def test_pages() -> None:
    for case in fixtures.load("sources")["pages"]:
        url = Url.parse(case["url"])
        got = None if url is None else parse_page(url)
        assert _js.dumps(got) == _js.dumps(case["page"]), fixtures.label(case["url"])


def test_visits() -> None:
    cases = fixtures.load("sources")["visits"]
    failures = []
    for case in cases:
        got = attribute(parse_page(Url(case["url"])), case["referrer"], case["internal"])
        if _js.dumps(got) != _js.dumps(case["attribution"]):
            failures.append(f"{fixtures.label([case['url'], case['referrer']])} gave {got} not {case['attribution']}")
    assert len(cases) > 300
    assert failures[:20] == []


def test_recorded_and_readable_paths() -> None:
    fixture = fixtures.load("sources")
    for case in fixture["recordedPaths"]:
        assert recorded_path(case["input"]) == case["path"], fixtures.label(case["input"])
    for case in fixture["readablePaths"]:
        assert readable_path(case["input"]) == case["path"], fixtures.label(case["input"])
