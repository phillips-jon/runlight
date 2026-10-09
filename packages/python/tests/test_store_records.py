"""Sites, links, shares, tokens, reports, settings, salts, and the live view, at the store, on every database (PHP
RecordsTest)."""

from __future__ import annotations

from typing import Any

import pytest
from support.databases import kinds
from support.store import DAY, HOUR, MIN, NOW, event, goal, q, store, today, visit

KINDS = kinds()


@pytest.mark.parametrize("kind", KINDS)
def test_sites_are_kept_with_their_overrides_and_a_deleted_sites_records_go_with_it(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    shop = {"id": "shop", "name": "Shop", "hostnames": ["shop.example.com", "store.example.com"], "timezone": "Europe/London"}
    s.upsert_site(shop, NOW)
    # Unchanged, it is left alone; changed, it is updated, keeping when it was made.
    s.upsert_site(shop, NOW + 1)
    s.upsert_site({**shop, "name": "A shop", "hostnames": ["shop.example.com"]}, NOW + 2)
    assert s.sites() == [
        {"id": "shop", "name": "A shop", "hostnames": ["shop.example.com"], "timezone": "Europe/London"},
        {"id": "default", "name": "Example", "hostnames": ["example.com"], "timezone": "UTC"},
    ]
    assert [int(r["created_at"]) for r in s.db.all("SELECT created_at FROM rl_sites WHERE id = 'shop'")] == [NOW]
    s.set_site_overrides("shop", {"name": "Renamed", "timezone": "Asia/Tokyo"})
    s.set_site_overrides("default", {})
    assert s.site_overrides() == {"default": {}, "shop": {"name": "Renamed", "timezone": "Asia/Tokyo"}}
    assert s.db.all("SELECT overrides FROM rl_sites WHERE id = 'default'")[0]["overrides"] == "{}", "no overrides is an empty object"

    t = NOW - HOUR
    visit(s, "s1", "v1", t, {}, [("pageview", "/", t, "p1")], "shop")
    visit(s, "s2", "v2", t - 40 * DAY, {}, [("pageview", "/", t - 40 * DAY, "p2")], "shop")
    visit(s, "s3", "v3", t, {}, [("pageview", "/", t, "p3")])
    s.save_goal(goal("g1", site="shop", match="x"))
    s.insert_share({"id": "sh", "site": "shop", "name": "", "createdAt": 1})
    s.add_link_domain("go.shop.example", "shop", 1)
    s.build_rollup_day("shop", "2026-10-05", NOW - 36 * HOUR, NOW - 12 * HOUR)
    assert s.last_seen("shop") == t
    s.delete_site("shop")
    assert [x["id"] for x in s.sites()] == ["default"]
    for table in ("rl_events", "rl_sessions", "rl_goals", "rl_shares", "rl_link_domains", "rl_rollups", "rl_rollup_days"):
        assert int(s.db.all(f"SELECT COUNT(*) AS n FROM {table} WHERE site = 'shop'")[0]["n"]) == 0, table
    assert s.stats(today())["visits"] == 1, "the other site keeps its visits"
    assert s.last_seen("shop") is None


@pytest.mark.parametrize("kind", KINDS)
def test_short_links_and_their_clicks(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    link = {"id": "l" * 24, "site": "default", "domain": "", "slug": "launch", "name": "Launch", "url": "https://example.com/launch", "createdAt": NOW - DAY, "updatedAt": NOW - DAY}
    s.insert_link(link)
    assert s.link_by_slug("launch") == link
    # A slug is unique across every domain while its link lives.
    with pytest.raises(Exception):  # noqa: B017
        s.insert_link({**link, "id": "m" * 24, "domain": "go.example.com"})
    s.update_link({**link, "domain": "go.example.com", "name": "Moved", "updatedAt": NOW})
    moved = s.link_by_id(link["id"])
    assert moved is not None and [moved["domain"], moved["name"], moved["updatedAt"]] == ["go.example.com", "Moved", NOW]
    for i in range(40):
        ts = NOW - i * HOUR
        session = f"c{i}" if i % 4 else ""
        if session:
            visit(s, session, f"cv{i % 3}", ts, {"source": "Twitter" if i % 2 else "Direct", "country": "GB" if i % 2 else "US"})
        s.insert_event(event(ts=ts, kind="click", visitor=f"cv{i % 3}" if session else "", session=session, link=link["id"]))
        if session:
            s.touch_session(session, ts, "click", "")
    listed = s.links("default", NOW - 2 * DAY, NOW + 1)
    assert [listed[0]["clicks"], listed[0]["visitors"]] == [40, 3], "clicks imported as counts add to clicks only"
    buckets = [{"start": NOW - 44 * HOUR + h * HOUR, "end": NOW - 43 * HOUR + h * HOUR} for h in range(45)]
    series = s.link_series("default", link["id"], buckets)
    assert len(series) == 45, "more buckets than one statement takes"
    assert sum(p["clicks"] for p in series) == 40
    assert s.link_breakdown("default", link["id"], 0, NOW + 1, "source", 5) == [
        {"value": "Twitter", "visitors": 3, "events": 20},
        {"value": "Direct", "visitors": 3, "events": 10},
    ]
    assert s.stats(q(0, NOW + 1))["visits"] == 0, "a click alone is not a visit"

    s.delete_link(link["id"], NOW)
    assert s.link_by_slug("launch") is None
    assert s.link_by_id(link["id"]) is None
    assert s.links("default", 0, NOW + 1) == []
    s.insert_link({**link, "id": "n" * 24})
    again = s.link_by_slug("launch")
    assert again is not None and again["id"] == "n" * 24, "a deleted link frees its slug"

    s.add_link_domain("go.example.com", "default", 1)
    s.add_link_domain("go.example.com", "other", 2)
    s.add_link_domain("a.example.com", "default", 3)
    assert s.link_domains() == [{"domain": "a.example.com", "site": "default"}, {"domain": "go.example.com", "site": "default"}], "a domain stays with its first site"
    s.remove_link_domain("go.example.com")
    assert [d["domain"] for d in s.link_domains()] == ["a.example.com"]


@pytest.mark.parametrize("kind", KINDS)
def test_shares_tokens_reports_and_settings(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    s.insert_share({"id": "s1", "site": "default", "name": "Client", "createdAt": 1})
    s.insert_share({"id": "s2", "site": "default", "name": "", "createdAt": 2})
    s.rename_share("s1", "Renamed")
    assert [x["id"] for x in s.shares("default")] == ["s2", "s1"]
    assert s.share_by_id("s1") == {"id": "s1", "site": "default", "name": "Renamed", "createdAt": 1}
    s.delete_share("s1")
    assert s.share_by_id("s1") is None

    token = {"id": "t1", "name": "Script", "site": "", "scope": "read", "hash": "h" * 64, "hint": "abcd", "createdAt": 5, "lastUsedAt": None}
    s.insert_token(token)
    s.insert_token({**token, "id": "t2", "site": "default", "scope": "manage", "hash": "g" * 64, "createdAt": 6})
    s.touch_token("t1", 99)
    assert s.token_by_hash("h" * 64) == {**token, "lastUsedAt": 99}
    assert [x["id"] for x in s.tokens()] == ["t2", "t1"]
    assert s.delete_token("t1") is True, "a token that was there"
    assert s.delete_token("t1") is False, "and once it is gone"

    report = {"id": "r1", "site": "default", "email": "a@example.com", "frequency": "weekly", "lang": "en", "token": "q" * 32, "origin": "", "lastPeriod": "", "lastSentAt": None, "createdAt": 7}
    s.insert_report(report)
    assert s.claim_report("r1", "w:2026-09-28", 100) is True, "the first claim wins"
    assert s.claim_report("r1", "w:2026-09-28", 101) is False, "a second, at once, does not"
    assert s.report_by("token", "q" * 32) == {**report, "lastPeriod": "w:2026-09-28", "lastSentAt": 100}
    s.release_report("r1", "w:2026-09-28", "")
    released = s.report_by("id", "r1")
    assert released is not None and released["lastPeriod"] == ""
    assert len(s.reports()) == 1
    assert len(s.reports("default")) == 1
    assert s.reports("elsewhere") == []
    s.delete_report("r1")
    assert s.report_by("id", "r1") is None

    s.set_setting("remote:a", "1")
    s.set_setting("remote:a", "2")
    s.set_setting("remote_b", "3")
    s.set_setting("remote%c", "4")
    s.set_setting("remote\\d", "5")
    assert s.setting("remote:a") == "2"
    assert s.settings_starting_with("remote:") == [{"key": "remote:a", "value": "2"}]
    assert s.settings_starting_with("remote_") == [{"key": "remote_b", "value": "3"}], "an underscore is taken literally"
    assert s.settings_starting_with("remote%") == [{"key": "remote%c", "value": "4"}]
    assert s.settings_starting_with("remote\\") == [{"key": "remote\\d", "value": "5"}], "and a backslash, on MySQL too"
    s.set_setting("remote:a", None)
    assert s.setting("remote:a") is None


@pytest.mark.parametrize("kind", KINDS)
def test_salts_sessions_and_the_live_view(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    assert s.salt("2026-10-06", "first") == "first"
    assert s.salt("2026-10-06", "second") == "first", "two racing callers agree on one"
    s.salt("2026-10-05", "old")
    s.drop_salts_before("2026-10-06")
    assert s.salt_if_exists("2026-10-05") is None
    assert s.salt_if_exists("2026-10-06") == "first"

    t = NOW - 3 * MIN
    visit(s, "s1", "v1", t - HOUR, {"source": "Google", "country": "GB", "city": "London", "device": "Desktop"}, [("pageview", "/", t - HOUR, "old"), ("pageview", "/pricing", t, "p1"), ("event", "Signup", t + 1000, None)])
    visit(s, "s2", "v2", t, {"country": "US"}, [("pageview", "/", t, "p2")])
    assert s.open_session("default", ["v0", "v1"], t - 1) == {"id": "s1", "visitor": "v1"}
    assert s.open_session("default", ["v1"], t + 2000) is None
    assert s.open_session("default", [], 0) is None
    assert s.pageview("default", "p1") == {"session": "s1", "visitor": "v1", "path": "/pricing", "hostname": "example.com", "ts": t, "startedAt": t - HOUR, "lastAt": t + 1000}
    assert s.pageview("default", "nope") is None

    live = s.realtime("default", NOW)
    assert live["visitors"] == 2
    assert live["pages"] == [{"value": "/", "visitors": 1}, {"value": "/pricing", "visitors": 1}]
    assert live["sources"] == [{"value": "Google", "visitors": 1}]
    assert live["countries"] == [{"value": "GB", "visitors": 1}, {"value": "US", "visitors": 1}]
    assert len(live["minutes"]) == 30
    assert live["minutes"][26] == 2
    assert live["recent"][0] == {"ts": t + 1000, "kind": "event", "path": "/pricing", "name": "Signup", "country": "GB", "city": "London", "source": "Google", "device": "Desktop"}
    assert len(live["recent"]) == 3


@pytest.mark.parametrize("kind", KINDS)
def test_ai_agent_fetches_are_their_own_rows_outside_visits(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    for i, agent in enumerate(["GPTBot", "GPTBot", "ClaudeBot", "ClaudeBot", "Amazonbot"]):
        s.insert_event(event(ts=NOW - i * MIN, kind="fetch", path="/a" if i % 2 else "/b", hostname="example.com", name=agent, props={"company": "X", "kind": "crawler"}))
    assert s.breakdown(today(), "ai_agent", 10, 0) == [
        {"value": "ClaudeBot", "visitors": 0, "fetches": 2},
        {"value": "GPTBot", "visitors": 0, "fetches": 2},
        {"value": "Amazonbot", "visitors": 0, "fetches": 1},
    ]
    assert s.breakdown(today(), "ai_page", 1, 1) == [{"value": "/a", "visitors": 0, "fetches": 2}]
    assert s.stats(today())["visits"] == 0
    assert s.db.all("SELECT props FROM rl_events WHERE kind = 'fetch' LIMIT 1")[0]["props"] == '{"company":"X","kind":"crawler"}'
