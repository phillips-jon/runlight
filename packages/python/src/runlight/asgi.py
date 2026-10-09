"""Runlight in an ASGI app (FastAPI, Starlette, Quart, Django under ASGI, or plain ASGI).

    from runlight.asgi import RunlightMiddleware

    app.add_middleware(RunlightMiddleware, runlight=rl)   # Starlette and FastAPI
    application = RunlightMiddleware(application, runlight=rl)   # any ASGI app

Requests under the routes' base path (default /runlight), `{linkPath}/{slug}` (default /go), and every request to
a link domain added in Settings are Runlight's; everything else goes on to the app, and a page fetched by a known
AI agent is recorded on the way (observe=False turns that off). Runlight's work is synchronous, like the database
drivers it uses, so each of its requests runs in a worker thread and never holds up the event loop.
"""

from __future__ import annotations

import asyncio
import urllib.parse
from collections.abc import Awaitable, Callable, Mapping, MutableMapping
from typing import Any

from .http import Request, Response
from .serve import Front, body_limit, header_pairs, request_url, too_large

Scope = MutableMapping[str, Any]
Receive = Callable[[], Awaitable[MutableMapping[str, Any]]]
Send = Callable[[MutableMapping[str, Any]], Awaitable[None]]
AsgiApp = Callable[[Scope, Receive, Send], Awaitable[None]]


def _headers(scope: Mapping[str, Any]) -> list[tuple[str, str]]:
    out = []
    for name, value in scope.get("headers", []):
        key = name.decode("latin-1").lower()
        try:
            text = value.decode("utf-8")
        except UnicodeDecodeError:
            text = value.decode("latin-1")
        out.append((key, text))
    return out


def _raw_path(scope: Mapping[str, Any]) -> str:
    raw = scope.get("raw_path")
    root = scope.get("root_path", "")
    if raw:
        path = raw.decode("latin-1")
        if root and not path.startswith(root):
            path = urllib.parse.quote(root) + path
    else:
        path = scope.get("path", "/")
        if root and not path.startswith(root):
            path = root + path
        path = urllib.parse.quote(path, safe="/:@!$&'()*+,;=-._~%")
    query = scope.get("query_string", b"").decode("latin-1")
    return path + (f"?{query}" if query else "")


def to_request(scope: Mapping[str, Any], body: bytes = b"") -> Request:
    """An ASGI HTTP scope and its body as a Request."""
    headers = _headers(scope)
    named = dict(headers)
    forwarded = (named.get("x-forwarded-proto") or "").split(",")[0].strip().lower()
    scheme = forwarded or scope.get("scheme", "http")
    server = scope.get("server")
    host = named.get("host") or (f"{server[0]}:{server[1]}" if server else "localhost")
    client = scope.get("client")
    return Request(
        request_url(scheme, host, _raw_path(scope)),
        scope.get("method", "GET"),
        headers,
        body,
        str(client[0]) if client else "",
    )


class _TooLarge(Exception):
    pass


async def _read_body(receive: Receive, limit: int) -> bytes | None:
    """The whole body, or None when the client went away first. Raises _TooLarge past the limit."""
    chunks = []
    size = 0
    while True:
        message = await receive()
        if message["type"] == "http.disconnect":
            return None
        chunk = message.get("body", b"")
        size += len(chunk)
        if size > limit:
            raise _TooLarge()
        chunks.append(chunk)
        if not message.get("more_body"):
            return b"".join(chunks)


async def send_response(send: Send, response: Response, head: bool = False) -> None:
    """Sends a Response over ASGI, streamed when Runlight streams it (exports)."""
    pairs = header_pairs(response)
    if not response.streamed and not any(name == "content-length" for name, _ in pairs):
        pairs.append(("content-length", str(len(response.content()))))
    headers = [(k.encode("latin-1"), v.encode("utf-8")) for k, v in pairs]
    await send({"type": "http.response.start", "status": response.status, "headers": headers})
    if head:
        await send({"type": "http.response.body", "body": b""})
        return
    if not response.streamed:
        await send({"type": "http.response.body", "body": response.content()})
        return
    chunks = iter(response.chunks())
    while True:
        chunk = await asyncio.to_thread(next, chunks, None)
        if chunk is None:
            break
        await send({"type": "http.response.body", "body": chunk, "more_body": True})
    await send({"type": "http.response.body", "body": b""})


class RunlightMiddleware:
    """An ASGI app that answers Runlight's requests and hands the rest to `app` (a 404 without one)."""

    def __init__(
        self,
        app: AsgiApp | None = None,
        runlight: Any = None,
        routes: Any = None,
        observe: bool = True,
        **routes_options: Any,
    ) -> None:
        if runlight is None:
            raise ValueError("Runlight: pass runlight=, the Runlight to serve")
        self.app = app
        self.runlight = runlight
        if routes is None:
            routes = runlight.routes(**routes_options)
        self.front = Front(runlight, routes, observe)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") != "http":
            if self.app is not None:
                await self.app(scope, receive, send)
            elif scope.get("type") == "lifespan":
                while True:
                    message = await receive()
                    if message["type"] == "lifespan.startup":
                        await send({"type": "lifespan.startup.complete"})
                    elif message["type"] == "lifespan.shutdown":
                        await send({"type": "lifespan.shutdown.complete"})
                        return
            return
        method = str(scope.get("method", "GET")).upper()
        head = method == "HEAD"
        bare = to_request(scope)
        linked = await asyncio.to_thread(self.front.link_domain, bare)
        if linked is not None:
            await send_response(send, linked, head)
            await asyncio.to_thread(self.runlight.idle)
            return
        path = urllib.parse.urlsplit(bare.url).path
        if not self.front.owns(method, path):
            if self.front.observe and method == "GET":
                await asyncio.to_thread(self.front.watch, bare)
            if self.app is not None:
                await self.app(scope, receive, send)
            else:
                await send_response(send, Response("Not found", 404, {"content-type": "text/plain; charset=utf-8"}), head)
            return
        body = b""
        if method not in ("GET", "HEAD"):
            try:
                read = await _read_body(receive, body_limit(path))
            except _TooLarge:
                await send_response(send, too_large(), head)
                return
            if read is None:
                return
            body = read
        response = await asyncio.to_thread(self.front.answer, to_request(scope, body))
        await send_response(send, response, head)
        await asyncio.to_thread(self.runlight.idle)


def app(runlight: Any, routes: Any = None, **routes_options: Any) -> RunlightMiddleware:
    """Runlight on its own as an ASGI app, such as for uvicorn."""
    return RunlightMiddleware(None, runlight, routes, observe=False, **routes_options)
