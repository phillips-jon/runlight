"""The MCP server against tests/fixtures/mcp.json: the TypeScript's API reads and answers for the same JSON-RPC
messages and tool arguments, over canned API answers. The parts of mcp.test.ts that need no store are here too."""

from __future__ import annotations

from typing import Any

import pytest
from support import fixtures

from runlight import _js
from runlight.http import Request, Response
from runlight.mcp import McpError, call_tool, mcp_response


def read_api(log: list[Any], name: str = "mcp"):
    """A readApi that logs each read and answers from the fixture's canned API."""
    api = fixtures.load(name)["api"]

    def read(path: str, params: list[tuple[str, str]]) -> Response:
        log.append({"path": path, "params": params})
        canned = api.get(path) or {"status": 404, "body": '{"error":"Not found: ' + path.replace('"', "") + '"}'}
        return Response(canned["body"], canned["status"], {"content-type": "application/json"})

    return read


def test_tool_calls_read_the_same_api_and_answer_the_same() -> None:
    for case in fixtures.load("mcp")["calls"]:
        label = _js.dumps(case["params"])
        log: list[Any] = []
        try:
            result = call_tool(case["params"], read_api(log))
        except McpError as error:
            assert "throws" in case, f"{label} threw {error}"
            assert str(error) == case["message"], label
            continue
        assert "throws" not in case, f"{label} should throw"
        assert _js.dumps(log) == _js.dumps(case["requests"]), label
        assert _js.dumps(result) == _js.dumps(case["value"]), label


def test_json_rpc_answers_match() -> None:
    for case in fixtures.load("mcp")["rpcs"]:
        body = bytes.fromhex(case["bodyHex"]) if "bodyHex" in case else case["body"]
        log: list[Any] = []
        request = Request("https://example.com/runlight/mcp", "POST", {}, body)
        if "throws" in case:
            with pytest.raises(TypeError):
                mcp_response(request, read_api(log))
            continue
        answer = mcp_response(request, read_api(log))
        label = repr(body)
        assert answer.status == case["status"], label
        assert dict(answer.headers.items()) == case["headers"], label
        assert answer.text() == case["text"], label
        assert _js.dumps(log) == _js.dumps(case["requests"]), label


def test_tools_are_listed_read_only_in_order() -> None:
    log: list[Any] = []
    answer = mcp_response(Request("https://x.com/mcp", "POST", {}, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'), read_api(log))
    tools = _js.loads(answer.text())["result"]["tools"]
    assert [t["name"] for t in tools] == fixtures.load("mcp")["tools"]
    assert all(t["annotations"]["readOnlyHint"] is True for t in tools)
    assert '"properties":{}' in answer.text(), "an empty schema is an object"


def test_initialize_answers_the_asked_version_or_the_newest() -> None:
    log: list[Any] = []

    def ask(version: str) -> Any:
        message = _js.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": version}})
        return _js.loads(mcp_response(Request("https://x.com/mcp", "POST", {}, message), read_api(log)).text())["result"]

    assert ask("2025-06-18")["protocolVersion"] == "2025-06-18"
    assert ask("2025-06-18")["serverInfo"]["name"] == "runlight"
    assert ask("1999-01-01")["protocolVersion"] == "2025-11-25", "an unknown version gets the newest"
    note = mcp_response(Request("https://x.com/mcp", "POST", {}, '{"jsonrpc":"2.0","method":"notifications/initialized"}'), read_api(log))
    assert note.status == 202
    assert note.text() == ""


def test_an_answer_that_is_not_an_object_is_passed_on_as_it_is() -> None:
    """As edges.test.ts: a body that is fine but not an object passes as it is, even through a tool that reshapes."""
    for body in ["null", "[1]", "5"]:
        result = call_tool({"name": "get_visit_times"}, lambda path, params, body=body: Response(body, 200))
        assert result["content"][0]["text"] == body, body
        refused = call_tool({"name": "list_sites"}, lambda path, params, body=body: Response(body, 403))
        assert refused == {"content": [{"type": "text", "text": "Runlight answered 403"}], "isError": True}, body
