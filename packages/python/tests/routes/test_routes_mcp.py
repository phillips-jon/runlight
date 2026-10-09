"""mcp.test.ts, ported: API tokens and the MCP server through the routes, on every store."""

from __future__ import annotations

import calendar
import re
from typing import Any

import pytest

from runlight import _js
from runlight.http import Request
from runlight.store import Stores
from support.databases import kinds
from support.routes import body, owner, runlight

CHROME_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
SITES = [
    {"id": "a", "name": "Site A", "hostnames": ["a.com"], "timezone": "UTC"},
    {"id": "b", "name": "Site B", "hostnames": ["b.com"], "timezone": "UTC"},
]
NOW = calendar.timegm((2026, 10, 6, 12, 0, 0)) * 1000


def _make(databases: Any, kind: str) -> tuple[Any, Any, Any]:
    """A Runlight on a fresh store of this kind, its routes with the token "secret", and a way to send tracker hits."""
    rl = runlight({"store": Stores.from_db(databases.db(kind)), "sites": SITES, "now": lambda: NOW})
    routes = rl.routes({"token": "secret"})

    def send(given: dict[str, Any], ip: str = "203.0.113.1") -> None:
        headers = {"user-agent": CHROME_MAC, "x-forwarded-for": ip, "content-type": "text/plain;charset=UTF-8"}
        answer = routes.handle(Request("https://example.com/runlight/e", "POST", headers, _js.dumps(given)))
        assert answer.status == 202
        rl.idle()

    return rl, routes, send


@pytest.mark.parametrize("kind", kinds())
def test_api_tokens_read_cannot_write_can_be_limited_to_a_site_and_stop_at_revocation(databases: Any, kind: str) -> None:
    _, routes, send = _make(databases, kind)

    def make(given: Any) -> dict[str, Any]:
        answer = routes.handle(owner("/runlight/api/tokens", "POST", given))
        return {"status": answer.status, "body": body(answer)}

    assert make({"name": ""})["status"] == 400
    assert make({"name": "X", "site": "nope"})["status"] == 404
    all_ = make({"name": "Claude"})
    assert all_["status"] == 201
    secret = all_["body"]["secret"]
    assert re.fullmatch(r"rl_[a-f0-9]{40}", secret)
    assert all_["body"]["token"]["hint"] == secret[-4:]
    one = make({"name": "Client B", "site": "b"})["body"]

    listed_answer = routes.handle(owner("/runlight/api/tokens"))
    listed = body(listed_answer)
    assert sorted(t["name"] for t in listed["tokens"]) == ["Claude", "Client B"]
    assert secret not in listed_answer.text(), "a token is shown once, never listed"
    assert "hash" not in listed["tokens"][0], "nor its hash"

    send({"k": "pageview", "u": "https://a.com/", "i": "p1"})
    send({"k": "pageview", "u": "https://b.com/", "i": "p2"}, "203.0.113.2")

    def as_(path: str, token: str, method: str = "GET", given: Any = None):
        return routes.handle(owner(f"/runlight{path}", method, given, token))

    stats = as_("/api/stats?site=a&period=today", secret)
    assert stats.status == 200
    assert body(stats)["stats"]["visitors"] == 1
    assert as_("/api/links?site=a", secret).status == 200, "links can be read"

    # Nothing that writes, and nothing that manages access.
    assert as_("/api/goals?site=a", secret, "POST", {"name": "G", "kind": "page", "match": "/"}).status == 403
    assert as_("/api/links?site=a", secret, "POST", {"url": "https://x.com"}).status == 403
    assert as_("/api/tokens", secret).status == 401, "a token cannot list tokens"
    assert as_("/api/shares?site=a", secret).status == 401
    assert as_("/api/mail", secret).status == 401

    # A site's token sees only that site.
    assert [s["id"] for s in body(as_("/api/sites", one["secret"]))["sites"]] == ["b"]
    assert body(as_("/api/stats?period=today", one["secret"]))["site"] == "b", "and defaults to it"
    assert as_("/api/stats?site=a", one["secret"]).status == 404
    assert as_("/api/links?site=a", one["secret"]).status == 404

    used = body(routes.handle(owner("/runlight/api/tokens")))
    assert next(t for t in used["tokens"] if t["name"] == "Claude")["lastUsedAt"] == NOW

    id_ = all_["body"]["token"]["id"]
    assert as_(f"/api/tokens/{id_}", secret, "DELETE").status == 403, "a token cannot revoke"
    assert routes.handle(owner(f"/runlight/api/tokens/{id_}", "DELETE")).status == 200
    assert routes.handle(owner(f"/runlight/api/tokens/{id_}", "DELETE")).status == 404
    assert as_("/api/stats?site=a", secret).status == 401, "revoked at once"


@pytest.mark.parametrize("kind", kinds())
def test_the_mcp_server_answers_initialize_lists_its_tools_and_calls_them_with_the_tokens_reach(databases: Any, kind: str) -> None:
    from runlight.mcp import TOOLS

    _, routes, send = _make(databases, kind)
    secret = body(routes.handle(owner("/runlight/api/tokens", "POST", {"name": "B only", "site": "b"})))["secret"]
    send({"k": "pageview", "u": "https://b.com/pricing", "r": "https://news.ycombinator.com/", "i": "p1"})
    send({"k": "pageview", "u": "https://a.com/", "i": "p2"})

    ids = [0]

    def rpc(method: str, params: Any = None, auth: str | None = None) -> dict[str, Any]:
        ids[0] += 1
        message: dict[str, Any] = {"jsonrpc": "2.0", "id": ids[0], "method": method}
        if params is not None:
            message["params"] = params
        headers = {"authorization": f"Bearer {auth or secret}", "content-type": "application/json", "accept": "application/json, text/event-stream"}
        answer = routes.handle(Request("https://example.com/runlight/mcp", "POST", headers, _js.dumps(message)))
        return {"status": answer.status, "headers": answer.headers, "body": None if answer.status == 202 else body(answer)}

    refused = rpc("initialize", {}, "rl_" + "0" * 40)
    assert refused["status"] == 401
    assert (refused["headers"].get("www-authenticate") or "").startswith("Bearer")
    assert routes.handle(owner("/runlight/mcp")).status == 405, "no event stream"

    init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
    assert init["body"]["result"]["protocolVersion"] == "2025-06-18"
    assert init["body"]["result"]["serverInfo"]["name"] == "runlight"
    assert "tools" in init["body"]["result"]["capabilities"]
    assert rpc("initialize", {"protocolVersion": "1999-01-01"})["body"]["result"]["protocolVersion"] == "2025-11-25", "an unknown version gets the newest"

    note = routes.handle(
        Request("https://example.com/runlight/mcp", "POST", {"authorization": f"Bearer {secret}", "content-type": "application/json"}, _js.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}))
    )
    assert note.status == 202

    listed = rpc("tools/list")
    assert [t["name"] for t in listed["body"]["result"]["tools"]] == [t["name"] for t in TOOLS]
    for tool in listed["body"]["result"]["tools"]:
        assert tool["annotations"]["readOnlyHint"] is True

    def call(name: str, args: Any = None) -> dict[str, Any]:
        result = rpc("tools/call", {"name": name, "arguments": args if args is not None else {}})["body"]["result"]
        return {**result, "data": None if result.get("isError") else _js.loads(result["content"][0]["text"])}

    assert [s["id"] for s in call("list_sites")["data"]["sites"]] == ["b"]
    stats = call("get_stats", {"period": "today"})
    assert stats["data"]["site"] == "b"
    assert stats["data"]["stats"]["pageviews"] == 1
    assert call("get_stats", {"site": "a"})["isError"] is True, "another site is out of reach"
    sources = call("get_breakdown", {"period": "today", "dimension": "source", "limit": 500})
    assert sources["data"]["rows"][0]["value"] == "Hacker News"
    assert call("get_stats", {"period": "today", "filters": ["page:is:/nowhere"]})["data"]["stats"]["pageviews"] == 0
    bad = call("get_stats", {"filters": ["nonsense"]})
    assert bad["isError"] is True
    assert "Bad filter" in bad["content"][0]["text"]
    times = call("get_visit_times", {"period": "today"})
    assert len(times["data"]["grid"]) == 7
    assert "cells" not in times["data"], "trimmed to what an assistant needs"
    assert len(call("list_goals", {"period": "today"})["data"]["goals"]) == 0
    assert call("get_goal", {"goal_id": "f" * 24})["isError"] is True
    assert "isError" not in call("list_links")
    assert "isError" not in call("get_realtime")

    assert rpc("tools/call", {"name": "drop_tables"})["body"]["error"]["code"] == -32602
    assert rpc("resources/list")["body"]["error"]["code"] == -32601
    assert rpc("ping")["body"]["result"] == {}

    # The owner's own token works too, across every site.
    every = rpc("tools/call", {"name": "list_sites", "arguments": {}}, "secret")
    assert [s["id"] for s in _js.loads(every["body"]["result"]["content"][0]["text"])["sites"]] == ["a", "b"]
