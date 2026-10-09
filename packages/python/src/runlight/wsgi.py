"""Runlight in a WSGI app (Flask, Django, Bottle, Pyramid, or plain WSGI), as the Node adapter (node.ts) serves it
from Node's http module.

    from runlight.wsgi import RunlightMiddleware

    application = RunlightMiddleware(application, rl)   # rl.routes() under /runlight, /go/{slug}, link domains

Requests under the routes' base path (default /runlight), `{linkPath}/{slug}` (default /go), and every request
to a link domain added in Settings are Runlight's; everything else goes on to the app, and a page fetched by a
known AI agent is recorded on the way (observe=False turns that off). Without an app, anything else is a 404.
The work a request starts after answering (a retention change's deletions) runs once the answer is sent.
"""

from __future__ import annotations

import http
import urllib.parse
from collections.abc import Callable, Iterable, Iterator, Mapping
from typing import Any

from .http import Request, Response
from .serve import HOP_BY_HOP, Front, body_limit, header_pairs, request_url, too_large

WsgiApp = Callable[[Mapping[str, Any], Callable[..., Any]], Iterable[bytes]]



class BodyTooLarge(Exception):
    """A body past the limit, answered with 413."""


def _raw_path(environ: Mapping[str, Any]) -> str:
    """The path and query as the client sent them: RAW_URI or REQUEST_URI when the server keeps them, else
    SCRIPT_NAME and PATH_INFO (which WSGI gives as latin-1 text of the decoded bytes) percent-encoded again."""
    raw = environ.get("RAW_URI") or environ.get("REQUEST_URI")
    if raw:
        raw = str(raw)
        if raw.startswith(("http://", "https://")):
            parts = urllib.parse.urlsplit(raw)
            raw = parts.path + (f"?{parts.query}" if parts.query else "")
        return raw
    path = (str(environ.get("SCRIPT_NAME", "")) + str(environ.get("PATH_INFO", ""))).encode("latin-1", "replace")
    quoted = urllib.parse.quote(path, safe="/:@!$&'()*+,;=-._~%")
    query = str(environ.get("QUERY_STRING", ""))
    return quoted + (f"?{query}" if query else "")


def _host(environ: Mapping[str, Any]) -> str:
    host = environ.get("HTTP_HOST")
    if host:
        return str(host)
    name = str(environ.get("SERVER_NAME", "localhost"))
    port = str(environ.get("SERVER_PORT", ""))
    scheme = environ.get("wsgi.url_scheme", "http")
    if not port or (scheme == "https" and port == "443") or (scheme == "http" and port == "80"):
        return name
    return f"{name}:{port}"


def to_request(environ: Mapping[str, Any], with_body: bool = True) -> Request:
    """A WSGI environ as a Request. The URL is the one the browser asked for; the address is the connection's,
    since Runlight reads proxy headers itself, only when trustProxy allows. Raises BodyTooLarge for a body past
    the limit."""
    headers: list[tuple[str, str]] = []
    for key, value in environ.items():
        if key.startswith("HTTP_"):
            headers.append((key[5:].replace("_", "-").lower(), _text(value)))
    if environ.get("CONTENT_TYPE"):
        headers.append(("content-type", _text(environ["CONTENT_TYPE"])))
    if environ.get("CONTENT_LENGTH"):
        headers.append(("content-length", _text(environ["CONTENT_LENGTH"])))
    forwarded = (dict(headers).get("x-forwarded-proto") or "").split(",")[0].strip().lower()
    scheme = forwarded or str(environ.get("wsgi.url_scheme", "http"))
    raw = _raw_path(environ)
    url = request_url(scheme, _host(environ), raw)
    method = str(environ.get("REQUEST_METHOD", "GET")).upper()
    body = b""
    if with_body and method not in ("GET", "HEAD"):
        body = _read_body(environ, body_limit(raw.split("?")[0]))
    return Request(url, method, headers, body, str(environ.get("REMOTE_ADDR", "")))


def _text(value: Any) -> str:
    """A header value as text: WSGI gives latin-1 text of the bytes sent, which are UTF-8 in practice."""
    text = str(value)
    try:
        return text.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text


def _read_body(environ: Mapping[str, Any], limit: int) -> bytes:
    stream = environ.get("wsgi.input")
    if stream is None:
        return b""
    length = environ.get("CONTENT_LENGTH")
    if length:
        try:
            size = int(length)
        except ValueError:
            size = 0
        if size > limit:
            raise BodyTooLarge()
        return stream.read(size) if size > 0 else b""
    if environ.get("wsgi.input_terminated") or "chunked" in str(environ.get("HTTP_TRANSFER_ENCODING", "")).lower():
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise BodyTooLarge()
        return data
    return b""


def send(response: Response, start_response: Callable[..., Any], head: bool = False) -> Iterable[bytes]:
    """Starts a WSGI response and gives its body, streamed when Runlight streams it (exports)."""
    try:
        phrase = http.HTTPStatus(response.status).phrase
    except ValueError:
        phrase = "Unknown"
    # WSGI leaves the connection to the server, which refuses hop-by-hop headers (wsgiref answers 500 for one), so
    # the 413's "connection: close" is the server's to decide.
    pairs = [(name, value) for name, value in header_pairs(response) if name not in HOP_BY_HOP]
    if not response.streamed and not any(name == "content-length" for name, _ in pairs):
        pairs.append(("content-length", str(len(response.content()))))
    start_response(f"{response.status} {phrase}", pairs)
    if head:
        return []
    return response.chunks()


class _After:
    """A response body that runs `then` once the server has sent it."""

    def __init__(self, body: Iterable[bytes], then: Callable[[], None]) -> None:
        self._body = body
        self._then = then

    def __iter__(self) -> Iterator[bytes]:
        return iter(self._body)

    def close(self) -> None:
        try:
            close = getattr(self._body, "close", None)
            if close is not None:
                close()
        finally:
            self._then()


class RunlightMiddleware:
    """A WSGI app that answers Runlight's requests and hands the rest to `app` (a 404 without one)."""

    def __init__(
        self,
        app: WsgiApp | None,
        runlight: Any,
        routes: Any = None,
        observe: bool = True,
        **routes_options: Any,
    ) -> None:
        self.app = app
        self.runlight = runlight
        if routes is None:
            routes = runlight.routes(**routes_options)
        self.front = Front(runlight, routes, observe)

    def __call__(self, environ: Mapping[str, Any], start_response: Callable[..., Any]) -> Iterable[bytes]:
        method = str(environ.get("REQUEST_METHOD", "GET")).upper()
        head = method == "HEAD"
        bare = to_request(environ, with_body=False)
        linked = self.front.link_domain(bare)
        if linked is not None:
            return _After(send(linked, start_response, head), self.runlight.idle)
        path = urllib.parse.urlsplit(bare.url).path
        if not self.front.owns(method, path):
            self.front.watch(bare)
            if self.app is not None:
                return self.app(environ, start_response)
            return send(Response("Not found", 404, {"content-type": "text/plain; charset=utf-8"}), start_response, head)
        try:
            request = to_request(environ)
        except BodyTooLarge:
            return send(too_large(), start_response, head)
        response = self.front.answer(request)
        return _After(send(response, start_response, head), self.runlight.idle)


def app(runlight: Any, routes: Any = None, **routes_options: Any) -> RunlightMiddleware:
    """Runlight on its own as a WSGI app, such as for gunicorn: `gunicorn 'myapp:application'` with
    `application = runlight.wsgi.app(rl)`."""
    return RunlightMiddleware(None, runlight, routes, observe=False, **routes_options)
