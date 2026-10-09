"""The ASGI middleware, called as an ASGI server calls it, and through httpx's ASGI transport."""

from __future__ import annotations

import asyncio
from collections.abc import Mapping
from typing import Any

import httpx
from adapter_scenario import APP_PAGE, CHROME, Answer, check_everything, make_runlight, routes_for

from runlight import _js
from runlight.asgi import RunlightMiddleware, app, to_request


async def hello_app(scope: Any, receive: Any, send: Any) -> None:
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
    await send({"type": "http.response.start", "status": 200, "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": APP_PAGE.encode()})


def asgi_client(application: Any, chunk: int = 4096) -> Any:
    def call(method: str, path: str, headers: Mapping[str, str] | None = None, body: bytes = b"", host: str = "example.com") -> Answer:
        target, _, query = path.partition("?")
        scope = {
            "type": "http",
            "asgi": {"version": "3.0"},
            "http_version": "1.1",
            "method": method,
            "scheme": "https",
            "path": target,
            "raw_path": target.encode(),
            "root_path": "",
            "query_string": query.encode(),
            "headers": [(b"host", host.encode()), *((k.lower().encode(), v.encode()) for k, v in (headers or {}).items())],
            "client": ("203.0.113.9", 50000),
            "server": (host, 443),
        }
        # The body arrives in pieces, as servers send it.
        pieces = [body[i : i + chunk] for i in range(0, len(body), chunk)] or [b""]
        messages = [
            {"type": "http.request", "body": piece, "more_body": i < len(pieces) - 1} for i, piece in enumerate(pieces)
        ]
        sent: list[dict[str, Any]] = []

        async def receive() -> dict[str, Any]:
            if messages:
                return messages.pop(0)
            await asyncio.sleep(3600)
            return {"type": "http.disconnect"}

        async def send(message: dict[str, Any]) -> None:
            sent.append(message)

        asyncio.run(application(scope, receive, send))
        start = next(m for m in sent if m["type"] == "http.response.start")
        data = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
        pairs = [(k.decode("latin-1"), v.decode("utf-8")) for k, v in start["headers"]]
        return Answer(start["status"], pairs, data)

    return call


def test_everything_through_the_middleware() -> None:
    rl = make_runlight()
    check_everything(rl, asgi_client(RunlightMiddleware(hello_app, runlight=rl, routes=routes_for(rl))))


def test_runlight_on_its_own_answers_404_elsewhere_and_observes_nothing() -> None:
    rl = make_runlight()
    check_everything(rl, asgi_client(app(rl, routes_for(rl))), passes_through=False, observes=False)


def test_the_request_keeps_its_path_query_and_address() -> None:
    scope = {
        "type": "http",
        "method": "GET",
        "scheme": "http",
        "path": "/runlight/api/café",
        "raw_path": b"/runlight/api/caf%C3%A9",
        "query_string": b"site=a&b=%2F",
        "headers": [(b"host", b"example.com"), (b"x-forwarded-proto", b"https"), (b"x-forwarded-for", b"198.51.100.4")],
        "client": ("203.0.113.9", 1234),
    }
    request = to_request(scope)
    assert request.url == "https://example.com/runlight/api/caf%C3%A9?site=a&b=%2F"
    assert request.remote_address == "203.0.113.9"
    assert request.headers.get("x-forwarded-for") == "198.51.100.4"


def test_lifespan_is_answered_without_an_app() -> None:
    rl = make_runlight()
    messages = [{"type": "lifespan.startup"}, {"type": "lifespan.shutdown"}]
    sent: list[str] = []

    async def receive() -> dict[str, Any]:
        return messages.pop(0)

    async def send(message: dict[str, Any]) -> None:
        sent.append(message["type"])

    asyncio.run(app(rl)({"type": "lifespan"}, receive, send))
    assert sent == ["lifespan.startup.complete", "lifespan.shutdown.complete"]


def test_through_httpx() -> None:
    rl = make_runlight()
    middleware = RunlightMiddleware(hello_app, runlight=rl, routes=routes_for(rl))

    async def run() -> None:
        transport = httpx.ASGITransport(app=middleware, client=("203.0.113.9", 1234))
        async with httpx.AsyncClient(transport=transport, base_url="https://example.com") as client:
            cookies = await client.get("/runlight/cookies")
            assert cookies.headers.get_list("set-cookie") == [
                "a=1; Path=/; HttpOnly; SameSite=Lax",
                "b=2; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT",
            ]
            body = _js.dumps({"k": "pageview", "u": "https://example.com/post"})
            hit = await client.post("/runlight/e", content=body, headers={"user-agent": CHROME})
            assert hit.status_code == 202
            page = await client.get("/hello")
            assert page.text == APP_PAGE

    asyncio.run(run())
