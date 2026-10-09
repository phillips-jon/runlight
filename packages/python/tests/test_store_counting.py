"""What the reports count, at the store: the store-level parts of counting.test.ts, filters.test.ts, goals.test.ts,
funnels.test.ts, journeys.test.ts, props.test.ts, and mysql.test.ts (PHP CountingTest). Visits are written through
the store as the tracker writes them."""

from __future__ import annotations

from typing import Any

import pytest
from support.databases import kinds
from support.store import DAY, HOUR, MIN, NOW, build_days, event, goal, q, store, today, utc, visit

from runlight import _js
from runlight.funnels import FunnelError, funnel_from
from runlight.goals import click_rules, goal_from
from runlight.sources import recorded_path
from runlight.store import JOURNEY_VISITS, SqlStore

KINDS = kinds()


def _pick(stats: dict[str, Any], *keys: str) -> list[Any]:
    return [stats[k] for k in keys]


@pytest.mark.parametrize("kind", KINDS)
def test_goals_funnels_and_event_properties_count_visits_by_when_they_started_with_or_without_a_filter(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    # Two people start at 23:50 on the 5th and sign up at 00:10 on the 6th; a third visits on the 6th.
    start = NOW - 12 * HOUR - 10 * MIN
    for i in (1, 2):
        visit(s, f"s{i}", f"v{i}", start, {"country": "GB"}, [("pageview", "/signup", start, f"p{i}"), ("event", "Signup", start + 20 * MIN, {"plan": "pro"})])
    visit(s, "s3", "v3", start + 80 * MIN, {}, [("pageview", "/", start + 80 * MIN, "q")])
    g = goal("a" * 24, name="Signup", match="Signup")
    s.save_goal(g)
    funnel = {"id": "b" * 24, "site": "default", "name": "Signup", "steps": [{"kind": "page", "match": "/signup"}, {"kind": "event", "match": "Signup"}], "createdAt": 0}
    s.save_funnel(funnel)
    day5 = utc(2026, 10, 5)
    for filters in ([], [("country", "not", "ZZ")], [("page", "contains", "/")]):

        def read(from_: int, filters: list[tuple[str, str, str]] = filters) -> list[Any]:
            query = q(from_, from_ + DAY, *filters)
            totals = s.goal_totals(query, g)
            visitors = s.visitors(query)
            events = [f"{r['value']}:{r['events']}" for r in s.breakdown(query, "event", 10, 0)]
            return [totals["conversions"], totals["visitors"] / visitors if visitors > 0 else 0, s.funnel_counts(query, funnel), len(s.event_prop_keys(query, "Signup")), events]

        assert read(day5) == [2, 1, [2, 2], 1, ["Signup:2"]], f"the visits that started on the 5th {filters}"
        assert read(day5 + DAY) == [0, 0, [0, 0], 0, []], f"nothing that started on the 6th converted {filters}"


@pytest.mark.parametrize("kind", KINDS)
def test_contains_finds_capitals_beyond_ascii_and_two_page_filters_count_both_pages(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    visit(s, "s1", "v1", t, {"utmCampaign": "Über"}, [("pageview", "/a", t, "a"), ("pageview", "/b", t + MIN, "b")])
    for value in ("über", "Über", "ÜBER", "ber"):
        assert s.stats(today(("utm_campaign", "contains", value)))["visits"] == 1, f"contains {value}"
    both = s.stats(today(("page", "is", "/a"), ("page", "is", "/b")))
    assert _pick(both, "visits", "pageviews") == [1, 2]


@pytest.mark.parametrize("kind", KINDS)
def test_a_page_goal_funnel_or_filter_written_in_plain_letters_matches_the_encoded_path(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    visit(s, "s1", "v1", t, {}, [("pageview", recorded_path("/café"), t, "a")])
    g = goal_from({"name": "Café", "kind": "page", "match": "/café"}, "default", [], NOW)
    s.save_goal(g)
    assert s.goal_totals(today(), g)["conversions"] == 1
    assert s.stats(today(("page", "is", "/café")))["visits"] == 1


@pytest.mark.parametrize("kind", KINDS)
def test_an_event_that_joins_a_visit_already_ended_counts_without_reopening_it(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - 6 * HOUR
    visit(s, "s1", "v1", t, {}, [("pageview", "/", t, "p1")])
    s.insert_event(event(ts=t + 2 * HOUR, kind="event", visitor="v1", session="s1", pageview="p1", path="/", hostname="example.com", name="Late"))
    s.touch_session("s1", t + 2 * HOUR, "event", "/", False)
    assert s.open_session("default", ["v1"], t + HOUR) is None, "still ended"
    assert s.breakdown(today(), "event", 10, 0) == [{"value": "Late", "visitors": 1, "events": 1}]
    assert s.stats(today())["bounceRate"] == 0


@pytest.mark.parametrize("kind", KINDS)
def test_time_on_page_is_over_every_pageview_counting_quick_ones_as_none(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    for i in range(4):
        rows: list[tuple] = [("pageview", "/a", t, f"v{i}")]
        if i == 0:
            rows.append(("engagement", "v0", t + 1000, 60_000, 50))
        visit(s, f"s{i}", f"v{i}", t, {}, rows)
    row = s.breakdown(today(), "page", 10, 0)[0]
    assert [row["timeOnPage"], row["scrollDepth"]] == [15_000, 50]


def test_journeys_applies_a_filter_before_its_cap_on_visits_and_says_when_the_cap_was_reached(databases: Any) -> None:
    s = store(databases, "sqlite")
    start = utc(2026, 10, 6)

    # Ten visits from Britain early in the day, then more from the US than journeys reads.
    def fill(tx: SqlStore) -> None:
        for i in range(10 + JOURNEY_VISITS):
            ts = start + i
            tx.db.run(
                "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, country) VALUES (?, 'default', ?, ?, ?, 1, '/', '/', ?)",
                [f"s{i}", f"v{i}", ts, ts, "GB" if i < 10 else "US"],
            )
            tx.db.run("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, ?, '/', 'example.com')", [ts, f"v{i}", f"s{i}", f"p{i}"])

    s.transaction(fill)

    def sessions(answer: dict[str, Any]) -> int:
        return len({r["session"] for r in answer["rows"]})

    britain = s.journey_pages(q(start, start + DAY, ("country", "is", "GB")), 5)
    assert sessions(britain) == 10, "every British visit, though they are older than the newest visits read"
    assert britain["sampled"] is False
    all_ = s.journey_pages(q(start, start + DAY), 5)
    assert sessions(all_) == JOURNEY_VISITS
    assert all_["sampled"] is True


@pytest.mark.parametrize("kind", KINDS)
def test_a_page_goal_or_funnel_step_for_a_hash_route_counts_that_route_only(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    for i in range(5):
        rows: list[tuple] = [("pageview", "/", t, f"h{i}")]
        if i < 2:
            rows.extend([("pageview", "/#/cart", t + 1000, f"c{i}"), ("pageview", "/#/thanks", t + 2000, f"t{i}")])
        visit(s, f"s{i}", f"v{i}", t, {}, rows)
    g = goal_from({"name": "Thanks", "kind": "page", "match": "/#/thanks"}, "default", [], NOW)
    funnel = funnel_from({"name": "Checkout", "steps": [{"kind": "page", "match": "/#/cart"}, {"kind": "page", "match": "https://example.com/#/thanks"}]}, "default", [], NOW)
    totals = s.goal_totals(today(), g)
    assert [g["match"], totals["conversions"], totals["visitors"]] == ["/#/thanks", 2, 2]
    assert [x["match"] for x in funnel["steps"]] == ["/#/cart", "/#/thanks"]
    assert s.funnel_counts(today(), funnel) == [2, 2]


@pytest.mark.parametrize("kind", KINDS)
def test_page_and_hostname_filters_together_count_pageviews_matching_both(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    visit(s, "s1", "v1", t, {}, [("pageview", "/pricing", t, "a", "example.com"), ("pageview", "/start", t + 1000, "b", "docs.example.com"), ("pageview", "/pricing", t + 2000, "c", "docs.example.com")])
    query = today(("page", "is", "/pricing"), ("hostname", "is", "docs.example.com"))
    assert s.stats(query)["pageviews"] == 1
    assert [[r["value"], r["pageviews"]] for r in s.breakdown(query, "page", 10, 0)] == [["/pricing", 1]]


@pytest.mark.parametrize("kind", KINDS)
def test_contains_ignores_case_in_any_mix_in_paths_too_and_filters_take_paths_as_the_browser_writes_them(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    visit(s, "s1", "v1", t, {"utmCampaign": "ÉcoleÉté"}, [("pageview", recorded_path("/Über-uns"), t, "a")])
    visit(s, "s2", "v2", t, {}, [("pageview", recorded_path("/a^b"), t, "b")])
    visit(s, "s3", "v3", t, {}, [("pageview", recorded_path("/#/x{y}"), t, "c")])

    def visits(d: str, op: str, v: str) -> int:
        return s.stats(today((d, op, v)))["visits"]

    for value in ("écoleété", "ÉCOLEÉTÉ", "eÉté"):
        assert visits("utm_campaign", "contains", value) == 1, value
    for value in ("über", "ÜBER", "Über-Uns"):
        assert visits("page", "contains", value) == 1, value
    assert visits("page", "is", "/a^b") == 1
    assert visits("page", "is", "/#/x{y}") == 1


@pytest.mark.parametrize("kind", KINDS)
def test_time_on_page_leaves_out_imported_views_which_can_report_no_time(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    # Nine pageviews written as the Umami import writes them: no pageview id, never any engaged time.
    day = utc(2026, 10, 5, 10)
    for i in range(9):
        s.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, imported) VALUES (?, 'default', ?, ?, ?, 1, '/pricing', '/pricing', 1)", [f"i{i}", f"v{i}", day + i, day + i])
        s.db.run("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, '', '/pricing', 'example.com')", [day + i, f"v{i}", f"i{i}"])
    t = NOW - HOUR
    visit(s, "live", "lv", t, {}, [("pageview", "/pricing", t, "live"), ("engagement", "live", t + 1000, 60_000, None)])
    week = q(NOW - 7 * DAY, NOW + DAY)

    def row() -> dict[str, Any]:
        return next(r for r in s.breakdown(week, "page", 10, 0) if r["value"] == "/pricing")

    assert [row()["pageviews"], row()["timeOnPage"]] == [10, 60_000]
    build_days(s, "default", NOW - 7 * DAY, NOW + DAY)
    assert row()["timeOnPage"] == 60_000, "the same once the days are built"


@pytest.mark.parametrize("kind", KINDS)
def test_a_filter_picks_visits_and_the_numbers_describe_those_whole_visits(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - 3 * HOUR
    # Visit A: two pages and a Signup. Visit B: one page, no Signup.
    visit(s, "a", "va", t, {}, [("pageview", "/", t, "a1"), ("pageview", "/pricing", t + 30_000, "a2"), ("event", "Signup", t + 60_000, None)])
    visit(s, "b", "vb", t + 60_000, {}, [("pageview", "/blog", t + 60_000, "b1")])

    def stats(*f: tuple[str, str, str]) -> dict[str, Any]:
        return s.stats(today(*f))

    assert _pick(stats(("event", "is", "Signup")), "visitors", "visits", "pageviews") == [1, 1, 2], "the visits with a Signup, and all their pageviews"
    assert _pick(stats(("page", "is", "/pricing")), "visits", "pageviews") == [1, 1], "a page filter counts that page's views"
    assert stats(("page", "is", "/pricing"), ("event", "is", "Signup"))["visits"] == 1, "a page and an event in the same visit"
    assert _pick(stats(("event", "not", "Signup")), "visits", "pageviews") == [1, 1], "is not means visits that never had one"

    buckets = [{"start": NOW - 12 * HOUR + h * HOUR, "end": NOW - 11 * HOUR + h * HOUR} for h in range(24)]
    points = s.series({"site": "default", "filters": [{"dimension": "event", "op": "is", "value": "Signup"}]}, buckets)
    assert [sum(p["visits"] for p in points), sum(p["pageviews"] for p in points)] == [1, 2], "the chart agrees"
    pages = sorted(r["value"] for r in s.breakdown(today(("event", "is", "Signup")), "page", 10, 0))
    assert pages == ["/", "/pricing"], "the pages of the visits that signed up"
    assert [r["value"] for r in s.breakdown(today(("page", "is", "/pricing")), "event", 10, 0)] == ["Signup"]


@pytest.mark.parametrize("kind", KINDS)
def test_goals_count_events_page_patterns_and_revenue_including_visits_from_before_the_goal(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    visit(s, "a", "v1", t, {"source": "Google"}, [("pageview", "/pricing", t, "a1"), ("event", "Purchase", t + 1, {"revenue": 49}), ("pageview", "/thanks", t + 2, "a2")])
    visit(s, "b", "v2", t, {}, [("pageview", "/pricing", t, "b1"), ("event", "Purchase", t + 1, {"revenue": "19.50"}), ("pageview", "/thanks/pro", t + 2, "b2")])
    visit(s, "c", "v3", t, {}, [("pageview", "/", t, "c1"), ("event", "Purchase", t + 1, {"revenue": "not a number"})])

    purchase = goal_from({"name": "Purchase", "kind": "event", "match": "Purchase", "valueMode": "prop", "valueProp": "revenue", "currency": "usd"}, "default", [], NOW)
    thanks = goal_from({"name": "Thank you page", "kind": "page", "match": "https://example.com/thanks*", "valueMode": "fixed", "value": 9.99}, "default", [purchase], NOW)
    button = goal_from({"name": "Buy button", "kind": "click", "clickBy": "selector", "match": ".buy"}, "default", [purchase, thanks], NOW)
    for g in (purchase, thanks, button):
        s.save_goal(g)
    assert s.visitors(today()) == 3
    all_ = s.goal_totals_all(today(), s.goals("default"))
    assert all_[purchase["id"]] == {"conversions": 3, "visitors": 3, "revenue": 68.5}, "numbers and numeric strings add up; anything else counts as nothing"
    assert purchase["currency"] == "USD"
    assert thanks["match"] == "/thanks*", "a pasted URL keeps only its path"
    assert all_[thanks["id"]]["conversions"] == 2
    assert all_[thanks["id"]]["revenue"] == pytest.approx(19.98, abs=1e-9), "a decimal fixed value works on every database, Postgres too"
    assert all_[button["id"]]["conversions"] == 0
    assert _js.dumps(s.goal_totals(today(), thanks)) == _js.dumps(all_[thanks["id"]])

    pages = s.goal_breakdown(today(), purchase, "path")
    assert [[r["value"], r["conversions"]] for r in pages] == [["/pricing", 2], ["/", 1]]
    assert s.goal_totals(today(), purchase)["revenue"] == 68.5
    series = s.goal_series({"site": "default", "filters": []}, purchase, [{"start": NOW - 12 * HOUR, "end": NOW}, {"start": NOW, "end": NOW + 12 * HOUR}])
    assert sum(p["conversions"] for p in series) == 3
    assert click_rules(s.sites(), s.goals())["default"] == [["s", ".buy", "Buy button"]]


@pytest.mark.parametrize("kind", KINDS)
def test_renaming_a_click_goal_renames_its_past_clicks(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    visit(s, "a", "v1", t, {}, [("pageview", "/", t, "a1"), ("event", "Buy", t + 1, None)])
    before = goal("c" * 24, name="Buy", kind="click", clickBy="selector", match=".buy")
    s.save_goal(before)
    after = {**before, "name": "Buy now"}
    s.save_goal(after, before)
    assert s.goal_totals(today(), after)["conversions"] == 1
    found = s.goal_by_id(before["id"])
    assert found is not None and found["name"] == "Buy now"
    s.delete_goal(before["id"])
    assert s.goals("default") == []


@pytest.mark.parametrize("kind", KINDS)
def test_funnel_steps_in_the_same_millisecond_both_count_and_one_row_never_counts_as_two_steps(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - MIN
    visit(s, "a", "v1", t, {}, [("pageview", "/pricing", t, "a1"), ("event", "Signup", t, None)])
    same = funnel_from({"name": "Same moment", "steps": [{"kind": "page", "match": "/pricing"}, {"kind": "event", "match": "Signup"}]}, "default", [], NOW)
    twice = funnel_from({"name": "Twice", "steps": [{"kind": "page", "match": "/pricing"}, {"kind": "page", "match": "/pricing"}]}, "default", [same], NOW)
    assert s.funnel_counts(today(), same) == [1, 1]
    assert s.funnel_counts(today(), twice) == [1, 0], "one pageview is not two steps"


@pytest.mark.parametrize("kind", KINDS)
def test_a_funnel_counts_visits_that_took_each_step_in_order_within_one_visit(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    n = 0

    def add(steps: list[tuple[str, str | None]]) -> None:
        nonlocal n
        n += 1
        t = NOW - 3 * HOUR + n * 10 * MIN
        rows: list[tuple] = []
        for i, (path, name) in enumerate(steps):
            rows.append(("pageview", path, t + i * MIN, f"p{n}x{i}") if name is None else ("event", name, t + i * MIN, None, path))
        visit(s, f"s{n}", f"v{n}", t, {}, rows)

    # All three steps in order; two steps, then gone; the right pages in the wrong order; never on pricing.
    add([("/pricing", None), ("/signup", "Signup"), ("/welcome", None)])
    add([("/pricing", None), ("/signup", "Signup")])
    add([("/welcome", None), ("/pricing", None)])
    add([("/blog", None), ("/welcome", None)])

    with pytest.raises(FunnelError) as raised:
        funnel_from({"name": "One step", "steps": [{"kind": "page", "match": "/pricing"}]}, "default", [], NOW)
    assert raised.value.code == "funnel_short"
    funnel = funnel_from(
        {"name": "Signup", "steps": [{"kind": "page", "match": "https://example.com/pricing*"}, {"kind": "event", "match": "Signup"}, {"kind": "page", "match": "welcome"}]},
        "default",
        [],
        NOW,
    )
    assert [x["match"] for x in funnel["steps"]] == ["/pricing*", "Signup", "/welcome"], "a pasted URL keeps its path; a bare path gains its slash"
    s.save_funnel(funnel)
    assert s.funnel_counts(today(), s.funnels("default")[0]) == [3, 2, 1]
    # Filters choose which visits enter. The Signup events were sent from /signup, so a page filter finds them.
    assert s.funnel_counts(today(("page", "is", "/signup")), funnel) == [2, 2, 1]
    changed = funnel_from({"name": "Signup flow", "steps": [{"kind": "page", "match": "/pricing"}, {"kind": "page", "match": "/welcome"}]}, "default", [funnel], NOW + 1, funnel["id"])
    assert changed["createdAt"] == funnel["createdAt"]
    s.save_funnel(changed)
    assert s.funnel_counts(today(), s.funnels("default")[0]) == [3, 1]
    s.delete_funnel(funnel["id"])
    assert s.funnels("default") == []


@pytest.mark.parametrize("kind", KINDS)
def test_journey_pages_reads_each_visits_pages_in_order(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    for i, pages in enumerate([["/", "/pricing", "/signup"], ["/", "/pricing", "/pricing", "/about"], ["/blog"]]):
        visit(s, f"s{i}", f"v{i}", t + i * MIN, {}, [("pageview", page, t + i * MIN + j * 10_000, f"p{i}x{j}") for j, page in enumerate(pages)])
    answer = s.journey_pages(today(), 3)
    assert answer["sampled"] is False
    assert answer["rows"] == [
        {"session": "s0", "path": "/"}, {"session": "s0", "path": "/pricing"}, {"session": "s0", "path": "/signup"},
        {"session": "s1", "path": "/"}, {"session": "s1", "path": "/pricing"}, {"session": "s1", "path": "/about"},
        {"session": "s2", "path": "/blog"},
    ], "a refresh is not a step"  # fmt: skip
    assert s.journey_pages(q(0, 1), 3) == {"rows": [], "sampled": False}


@pytest.mark.parametrize("kind", KINDS)
def test_an_events_properties_and_their_values_filtered_like_everything_else(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - HOUR
    visit(s, "a", "v1", t, {}, [
        ("pageview", "/", t, "a1"),
        ("event", "Outbound link", t + 1, {"url": "https://github.com/x"}),
        ("event", "Outbound link", t + 2, {"url": "https://news.ycombinator.com/"}),
        ("event", "Signup", t + 3, {"plan": "pro", "seats": 3}),
        ("event", "Signup", t + 4, {"plan": "team"}),
        ("event", "404", t + 5, {"path": "/missing"}),
    ])  # fmt: skip
    visit(s, "b", "v2", t, {}, [("pageview", "/blog", t, "b1"), ("event", "Outbound link", t + 1, {"url": "https://github.com/x"}, "/blog")])

    assert s.event_prop_keys(today(), "Outbound link") == [{"key": "url", "events": 3}]
    assert s.event_prop_values(today(), "Outbound link", "url", 10) == [
        {"value": "https://github.com/x", "events": 2, "visitors": 2},
        {"value": "https://news.ycombinator.com/", "events": 1, "visitors": 1},
    ]
    assert [r["key"] for r in s.event_prop_keys(today(), "Signup")] == ["plan", "seats"]
    assert s.event_prop_values(today(), "Signup", "seats", 10) == [{"value": "3", "events": 1, "visitors": 1}]
    assert [r["value"] for r in s.event_prop_values(today(("page", "is", "/blog")), "Outbound link", "url", 10)] == ["https://github.com/x"]
    assert s.event_prop_keys(today(), "Nothing") == []


@pytest.mark.parametrize("kind", KINDS)
def test_the_longest_values_the_tracker_accepts_are_kept_whole(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    t = NOW - 3 * HOUR
    path = "/" + "p" * 999

    def utm(c: str) -> str:
        return c * 200

    visit(s, "a", "v1", t, {
        "referrerHost": "r" * 60 + ".example.org", "referrerPath": "/" + "q" * 499,
        "utmSource": utm("s"), "utmMedium": utm("m"), "utmCampaign": utm("c"), "utmTerm": utm("t"), "utmContent": utm("o"),
    }, [("pageview", path, t, "a1")])  # fmt: skip
    props = {f"{i}" + "k" * 59: "v" * 500 for i in range(8)}
    s.insert_event(event(ts=t + 1, kind="pageview", visitor="v1", session="a", pageview="a2", path="/x", hostname="example.com", title="t" * 500))
    visit(s, "b", "v2", t, {}, [("pageview", "/", t, "b1"), ("event", "n" * 120, t + 1, props)])

    assert path in [r["value"] for r in s.breakdown(today(), "page", 10, 0)]
    for dimension, c in (("utm_source", "s"), ("utm_medium", "m"), ("utm_campaign", "c"), ("utm_term", "t"), ("utm_content", "o")):
        assert [r["value"] for r in s.breakdown(today(), dimension, 10, 0)] == [utm(c)]
    assert s.breakdown(today(), "event", 10, 0)[0]["value"] == "n" * 120
    assert len(s.event_prop_keys(today(), "n" * 120)) == 8
    assert [r["value"] for r in s.event_prop_values(today(), "n" * 120, "0" + "k" * 59, 10)] == ["v" * 500]
    # A day of them adds up the same way.
    build_days(s, "default", NOW - DAY, NOW + 12 * HOUR)
    assert path in [r["value"] for r in s.breakdown(q(NOW - 7 * DAY, NOW + DAY), "page", 10, 0)]


@pytest.mark.parametrize("kind", KINDS)
def test_text_is_compared_exactly_and_sorted_by_code_point_case_and_trailing_spaces_included(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    values = ["a", "a ", "A", "b", "é", "É", "\U0001f600", "�", "a\t"]
    t = NOW - HOUR
    for i, value in enumerate(values):
        visit(s, f"s{i}", f"v{i}", t, {"utmCampaign": value}, [("pageview", "/", t, f"x{i}"), ("event", "Pick", t + 1, {"choice": value})])
    # By bytes of UTF-8, which is code point order, as PHP's sort(SORT_STRING) puts them.
    ordered = sorted(values, key=lambda v: v.encode("utf-8"))
    rows = s.event_prop_values(today(), "Pick", "choice", 20)
    assert [r["value"] for r in rows] == ordered
    assert [r["events"] for r in rows] == [1] * len(values), "no two values counted as one"
    assert [r["value"] for r in s.breakdown(today(), "utm_campaign", 20, 0)] == ordered
    assert s.stats(today(("utm_campaign", "is", "a ")))["visits"] == 1, "a trailing space is part of the value"


@pytest.mark.parametrize("kind", KINDS)
def test_short_link_clicks_are_not_visits_in_the_heatmap_raw_or_rolled_up_nor_the_first_visit(databases: Any, kind: str) -> None:
    s = store(databases, kind)
    day = utc(2026, 10, 5, 15)
    # A session opened only by a short link click, then a real visit.
    s.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'default', 'v1', ?, ?, 0, 0, 0)", [day - HOUR, day - HOUR])
    s.db.run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'default', 'v2', ?, ?, 1, 0, 0)", [day, day])
    assert s.first_own_visit("default") == day
    assert s.first_seen("default") == day - HOUR
    query = q(utc(2026, 10, 1), utc(2026, 10, 7))
    assert sum(r["visits"] for r in s.hourly(query)) == 1, "raw"
    build_days(s, "default", query["from"], query["to"])
    assert sum(r["visits"] for r in s.hourly(query)) == 1, "rolled up"
