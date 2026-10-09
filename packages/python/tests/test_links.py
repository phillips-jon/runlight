"""Short links made, changed, removed, and imported through Links, over a store, without the core's routes."""

from __future__ import annotations

import re
from typing import Any

import pytest
from support.store import NOW

from runlight.links import SLUG_PATTERN, LinkError, Links, random_slug
from runlight.store import Stores


class _Runlight:
    """What Links asks of the core: its store, init(), and the clock."""

    def __init__(self) -> None:
        self.store = Stores.sqlite(":memory:")
        self.store.migrate()
        self.clock = NOW

    def init(self) -> None:
        pass

    def now(self) -> int:
        return self.clock


def _code(fn: Any) -> str:
    with pytest.raises(LinkError) as raised:
        fn()
    return raised.value.code


def test_random_slugs_use_an_alphabet_without_look_alikes() -> None:
    for _ in range(50):
        slug = random_slug()
        assert re.fullmatch(r"[abcdefghijkmnpqrstuvwxyz23456789]{6}", slug)
        assert SLUG_PATTERN.match(slug)


def test_links_are_made_changed_and_removed_with_the_rules_every_route_shares() -> None:
    rl = _Runlight()
    links = Links(rl)
    made = links.create("default", {"url": " https://www.example.com/launch?x=1 ", "slug": "launch"})
    assert made["slug"] == "launch"
    assert made["url"] == "https://www.example.com/launch?x=1"
    assert made["name"] == "example.com/launch", "named after its host and path"
    assert made["domain"] == ""
    assert rl.store.link_by_slug("launch") == made

    assert _code(lambda: links.create("default", {"url": "ftp://example.com/"})) == "link_protocol"
    assert _code(lambda: links.create("default", {"url": "example.com"})) == "link_url"
    assert _code(lambda: links.create("default", {"url": "https://example.com/" + "a" * 2000})) == "link_long"
    assert _code(lambda: links.create("default", {"url": "https://example.com/", "slug": "launch"})) == "link_taken"
    assert _code(lambda: links.create("default", {"url": "https://example.com/", "slug": "-bad"})) == "link_slug"
    assert _code(lambda: links.create("default", {"url": "https://example.com/", "domain": "go.example.com"})) == "link_domain"
    rl.store.add_link_domain("go.example.com", "default", 1)
    on_domain = links.create("default", {"url": "https://example.com/", "domain": "www.go.example.com", "name": "  Home  "})
    assert [on_domain["domain"], on_domain["name"], len(on_domain["slug"])] == ["go.example.com", "Home", 6]

    rl.clock = NOW + 5
    changed = links.update(made["id"], {"name": "", "slug": "launch"})
    assert [changed["name"], changed["slug"], changed["updatedAt"]] == ["example.com/launch", "launch", NOW + 5]
    assert _code(lambda: links.update(made["id"], {"slug": on_domain["slug"]})) == "link_taken"
    links.remove(made["id"])
    assert rl.store.link_by_id(made["id"]) is None
    with pytest.raises(ValueError, match="Unknown link"):
        links.remove(made["id"])


def test_an_import_reports_the_rows_that_fail_and_keeps_the_rest() -> None:
    rl = _Runlight()
    answer = Links(rl).import_(
        "default",
        [
            {"link_name": "One", "destination_url": "https://example.com/1", "link_slug": "one"},
            {"url": "nope"},
            {"name": "Two", "url": "https://example.com/2", "slug": "one"},
            {"url": "https://example.com/3", "slug": "  "},
        ],
    )
    assert answer["created"] == 2
    assert [(f["row"], f["code"]) for f in answer["failed"]] == [(2, "link_url"), (3, "link_taken")]
    assert answer["failed"][1]["params"] == {"slug": "one"}
