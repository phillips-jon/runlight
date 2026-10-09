"""The MCP server at {base}/mcp: Streamable HTTP without sessions or a stream,
JSON-RPC in and JSON out. Every tool is a read of the HTTP API, made with
the caller's own credentials, so the MCP server can see exactly what the
token can and nothing more.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from . import _js
from .http import Request, Response
from .query import DIMENSIONS, MAX_FILTERS

# Newest first; a client asking for one we do not know is answered with the newest.
PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

INSTRUCTIONS = """Runlight is privacy friendly web analytics. These tools read one install's numbers: visitors, visits, pageviews, bounce rate, visit duration, where visitors came from, what they read, goals and revenue, AI assistants that sent visitors or fetched pages, and short links.

Start with list_sites when you do not know the site id; every other tool defaults to the first site. Dates are in the site's own timezone, which each answer includes. Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the period before unless compare is off.

Filters narrow any report to matching visits, written dimension:op:value with op one of is, not, contains, for example "channel:is:Organic Search" or "page:contains:/blog". Visitors are counted per day without cookies, so a visitor seen on two days counts twice across a long range."""  # noqa: E501

Json = dict[str, Any]
Params = list[tuple[str, str]]

# Reads one API path with the caller's credentials: (path, params) -> Response.
ApiRead = Callable[[str, Params], Response]

RANGE: Json = {
    "site": {"type": "string", "description": "Site id from list_sites. Defaults to the first site."},
    "period": {
        "type": "string",
        "enum": ["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"],
        "description": "The date range. Defaults to 30d. Ignored when from and to are given.",
    },
    "from": {"type": "string", "description": "First day, YYYY-MM-DD, with to."},
    "to": {"type": "string", "description": "Last day, YYYY-MM-DD, inclusive."},
    "filters": {
        "type": "array",
        "items": {"type": "string"},
        "maxItems": MAX_FILTERS,
        "description": f'Narrow to matching visits, up to {MAX_FILTERS} at once, each "dimension:op:value" with op is, not, or contains.',
    },
}

COMPARE: Json = {
    "compare": {
        "type": "string",
        "enum": ["previous", "year", "custom", "off"],
        "description": "What to compare with. Defaults to previous, the same length of time just before.",
    },
    "compare_from": {"type": "string", "description": "For compare custom: first day, YYYY-MM-DD."},
    "compare_to": {"type": "string", "description": "For compare custom: last day, YYYY-MM-DD."},
}


class McpError(Exception):
    """A JSON-RPC error with its code, as TS throws an Error with a `code` added."""

    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


def _range_params(args: Any, keys: list[str]) -> Params:
    params: Params = []
    for key in keys:
        value = _js.get(args, key)
        if key == "filters":
            if isinstance(value, list):
                for f in value:
                    params.append(("filter", _js.string(f)))
        elif value is not _js.UNDEFINED and value is not None and value != "":
            params.append((key, _js.string(value)))
    return params


def _read(path: str, keys: list[str], extra: Callable[[Any], Params] = lambda args: []) -> Callable[[Any], Json]:
    return lambda args: {"path": path, "params": [*_range_params(args, keys), *extra(args)]}


def _limit(fallback: int) -> Callable[[Any], Params]:
    """["limit", String(Math.min(100, Math.max(1, Number(args.limit) || fallback)))]"""

    def extra(args: Any) -> Params:
        n = _js.number(_js.get(args, "limit"))
        n = n if _js.truthy(n) else fallback
        return [("limit", _js.number_text(min(100, max(1, n))))]

    return extra


RANGE_KEYS = ["site", "period", "from", "to", "filters"]
COMPARE_KEYS = [*RANGE_KEYS, "compare", "compare_from", "compare_to"]


def _goal(args: Any) -> Json:
    goal = _js.get(args, "goal_id")
    text = _js.string("" if goal is None or goal is _js.UNDEFINED else goal)
    return {"path": f"/api/goals/{_js.encode_uri_component(text)}", "params": _range_params(args, RANGE_KEYS)}


def _visit_times(body: Any) -> Any:
    return {
        "site": _js.get(body, "site"),
        "range": _js.get(body, "range"),
        "weekdays": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        "grid": _js.get(body, "grid"),
    }


# Each tool: name, title, description, inputSchema, request (the API path and query to read, from the tool's
# arguments), and shape (trims an answer before it goes back, when the API's carries more than an assistant
# needs), or None.
TOOLS: list[Json] = [
    {
        "name": "list_sites",
        "title": "List sites",
        "description": "Every site this token can read, with its id, name, hostnames, timezone, and when it last had a visit.",
        "inputSchema": {"type": "object", "properties": {}},
        "request": lambda args: {"path": "/api/sites", "params": []},
        "shape": None,
    },
    {
        "name": "get_stats",
        "title": "Headline numbers",
        "description": "Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration (milliseconds) for a range, with the comparison range's numbers as previous.",  # noqa: E501
        "inputSchema": {"type": "object", "properties": {**RANGE, **COMPARE}},
        "request": _read("/api/stats", COMPARE_KEYS),
        "shape": None,
    },
    {
        "name": "get_timeseries",
        "title": "Numbers over time",
        "description": "The headline numbers for each hour, day, week, or month of a range, with the comparison range's points lined up by position.",  # noqa: E501
        "inputSchema": {
            "type": "object",
            "properties": {
                **RANGE,
                **COMPARE,
                "interval": {"type": "string", "enum": ["hour", "day", "week", "month"], "description": "Chosen from the range when left out."},
            },
        },
        "request": _read("/api/series", [*COMPARE_KEYS, "interval"]),
        "shape": None,
    },
    {
        "name": "get_breakdown",
        "title": "Top values of a dimension",
        "description": "Rows for one dimension, most visitors first: pages, entry and exit pages, referrers, sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags, countries, regions, cities, browsers, operating systems, devices, screens, languages, custom events, and AI agents that fetched pages (ai_agent, ai_page).",  # noqa: E501
        "inputSchema": {
            "type": "object",
            "properties": {
                **RANGE,
                "dimension": {"type": "string", "enum": [*DIMENSIONS]},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Rows to return. Defaults to 10."},
                "page": {"type": "integer", "minimum": 1, "description": "For more rows: 2 is the next limit rows."},
            },
            "required": ["dimension"],
        },
        "request": _read("/api/breakdown", [*RANGE_KEYS, "dimension", "page"], _limit(10)),
        "shape": None,
    },
    {
        "name": "list_funnels",
        "title": "Funnels",
        "description": "Every funnel with how many visits reached each step in order within the same visit. Divide a step by the one before it for that step's conversion rate.",  # noqa: E501
        "inputSchema": {"type": "object", "properties": {**RANGE}},
        "request": _read("/api/funnels", RANGE_KEYS),
        "shape": None,
    },
    {
        "name": "get_event_properties",
        "title": "An event's properties",
        "description": 'The properties sent with one custom event and the values each took, most common first. Automatic events have their own: "Outbound link" and "File download" carry url, and "404" carries path. Leave key out to see every property name and the values of the most used one.',  # noqa: E501
        "inputSchema": {
            "type": "object",
            "properties": {
                **RANGE,
                "event": {"type": "string", "description": "The event's name, as get_breakdown with dimension event lists it."},
                "key": {"type": "string", "description": "Which property. Defaults to the most used one."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Values to return. Defaults to 25."},
            },
            "required": ["event"],
        },
        "request": _read("/api/event-props", [*RANGE_KEYS, "event", "key"], _limit(25)),
        "shape": None,
    },
    {
        "name": "get_visit_times",
        "title": "When people visit",
        "description": "Visits by weekday and hour in the site's timezone: grid[weekday][hour], Monday first, hours 0 to 23.",
        "inputSchema": {"type": "object", "properties": {**RANGE}},
        "request": _read("/api/rhythm", RANGE_KEYS),
        "shape": _visit_times,
    },
    {
        "name": "get_realtime",
        "title": "Right now",
        "description": "People on the site in the last five minutes, the pages they are reading, where they came from, their countries, and the latest activity.",  # noqa: E501
        "inputSchema": {"type": "object", "properties": {"site": RANGE["site"]}},
        "request": _read("/api/realtime", ["site"]),
        "shape": None,
    },
    {
        "name": "list_goals",
        "title": "Goals and conversions",
        "description": "Every goal with its conversions, converted visitors, conversion rate (0 to 1), and revenue for a range, with the comparison range's numbers as previous.",  # noqa: E501
        "inputSchema": {"type": "object", "properties": {**RANGE, **COMPARE}},
        "request": _read("/api/goals", COMPARE_KEYS),
        "shape": None,
    },
    {
        "name": "get_goal",
        "title": "One goal in detail",
        "description": "One goal's conversions over time and by channel, source, and page. Find the goal_id with list_goals.",
        "inputSchema": {"type": "object", "properties": {**RANGE, "goal_id": {"type": "string"}}, "required": ["goal_id"]},
        "request": _goal,
        "shape": None,
    },
    {
        "name": "get_journeys",
        "title": "Paths through the site",
        "description": "The paths visits take, page by page: the top pages at each step, how many went no further, the flows between steps, and the commonest whole paths. A refresh counts once. start and end follow only paths from or to a page.",  # noqa: E501
        "inputSchema": {
            "type": "object",
            "properties": {
                **RANGE,
                "steps": {"type": "integer", "minimum": 2, "maximum": 8, "description": "How many pages of each path. Defaults to 5."},
                "start": {"type": "string", "description": "Only paths from this page, such as /pricing."},
                "end": {"type": "string", "description": "Only paths that reach this page, cut there."},
            },
        },
        "request": _read("/api/journeys", [*RANGE_KEYS, "steps", "start", "end"]),
        "shape": None,
    },
    {
        "name": "list_links",
        "title": "Short links",
        "description": "Every short link with its destination and its clicks in the range.",
        "inputSchema": {
            "type": "object",
            "properties": {"site": RANGE["site"], "period": RANGE["period"], "from": RANGE["from"], "to": RANGE["to"]},
        },
        "request": _read("/api/links", ["site", "period", "from", "to"]),
        "shape": None,
    },
]


def _rpc_error(id: Any, code: Any, message: str) -> Json:
    return {"jsonrpc": "2.0", "id": None if id is None or id is _js.UNDEFINED else id, "error": {"code": code, "message": message}}


def call_tool(params: Any, read_api: ApiRead) -> Json:
    """Runs one tool by name, as the MCP server does; the dashboard's assistant calls it too."""
    name = _js.get(params, "name")
    tool = next((t for t in TOOLS if isinstance(name, str) and t["name"] == name), None)
    if tool is None:
        raise McpError(f'Unknown tool "{_js.string(name)}"', -32602)
    given = _js.get(params, "arguments")
    args = given if _js.truthy(given) and _js.is_object(given) else {}
    request = tool["request"](args)
    answer = read_api(request["path"], request["params"])
    ok, body = _js.try_loads(answer.content())
    if not ok:
        body = {}
    # Any body that is not an object (null included) carries no words of its own.
    obj = body if isinstance(body, dict) else None
    if not answer.ok:
        error = _js.UNDEFINED if obj is None else _js.get(obj, "error")
        text = f"Runlight answered {answer.status}" if error is None or error is _js.UNDEFINED else error
        return {"content": [{"type": "text", "text": _js.string(text)}], "isError": True}
    shape = tool["shape"]
    return {"content": [{"type": "text", "text": _js.dumps(shape(obj) if shape and obj is not None else body)}]}


def _answer(message: Any, read_api: ApiRead) -> Json | None:
    # A batch element that is not an object is an invalid request, answered with a null id.
    if not isinstance(message, dict):
        return _rpc_error(None, -32600, "Invalid request")
    id = _js.get(message, "id")
    is_notification = id is _js.UNDEFINED
    method = _js.get(message, "method")
    if _js.get(message, "jsonrpc") != "2.0" or not isinstance(method, str):
        return None if is_notification else _rpc_error(id, -32600, "Invalid request")
    # A notification is never answered, so it never runs anything either.
    if is_notification:
        return None
    given = _js.get(message, "params")
    params = given if _js.truthy(given) and _js.is_object(given) else {}
    try:
        if method == "initialize":
            asked = _js.get(params, "protocolVersion")
            asked = _js.string("" if asked is None or asked is _js.UNDEFINED else asked)
            from . import version

            result: Any = {
                "protocolVersion": asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "runlight", "title": "Runlight", "version": version.VERSION},
                "instructions": INSTRUCTIONS,
            }
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": t["name"],
                        "title": t["title"],
                        "description": t["description"],
                        "inputSchema": t["inputSchema"],
                        "annotations": {"readOnlyHint": True, "openWorldHint": False},
                    }
                    for t in TOOLS
                ]
            }
        elif method == "tools/call":
            result = call_tool(params, read_api)
        else:
            return _rpc_error(id, -32601, f'Unknown method "{method}"')
        return {"jsonrpc": "2.0", "id": id, "result": result}
    except Exception as error:
        code = getattr(error, "code", None)
        return _rpc_error(id, -32603 if code is None else code, str(error) if _js.truthy(code) else "Internal error")


def mcp_response(request: Request, read_api: ApiRead) -> Response:
    """Answers one POST to the MCP endpoint, already authorised."""
    headers = {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"}
    ok, body = _js.try_loads(request.body())
    if not ok or not _js.is_object(body):
        return Response(_js.dumps(_rpc_error(None, -32700, "Send a JSON-RPC message")), 400, headers)
    # Batches were in the 2025-03-26 protocol; answering them costs nothing.
    if isinstance(body, list):
        answers = [a for a in (_answer(m, read_api) for m in body) if a is not None]
        return Response(_js.dumps(answers), 200, headers) if answers else Response(None, 202)
    one = _answer(body, read_api)
    return Response(_js.dumps(one), 200, headers) if one is not None else Response(None, 202)
