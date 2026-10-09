"""What every adapter does with a request, in the order the standalone server answers: a link domain added in
Settings first (it leaves the dashboard's own paths alone), then `{linkPath}/{slug}` on the app's own domain, then
the routes. The WSGI and ASGI adapters (and through them Django, Flask, and FastAPI) all go through here."""

from __future__ import annotations

import re
import sys
from collections.abc import Mapping
from typing import Any

from . import _js
from .http import Request, Response, Url

# The collect endpoint's limit; its payloads are under 8 KB.
MAX_COLLECT_BODY = 16 * 1024
# Everything else, such as a link import of 5,000 rows.
MAX_BODY = 10 * 1024 * 1024

# Headers about the connection rather than the answer, which PEP 3333 keeps from WSGI apps: there the server decides.
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"}


def body_limit(path: str) -> int:
    """How long a request's body may be: a tracker hit's is small."""
    return MAX_COLLECT_BODY if path.endswith("/e") else MAX_BODY


def too_large() -> Response:
    """A body past the limit, answered with 413 rather than passed on empty. An upload cut off part way leaves the
    connection unfit for another request."""
    return Response(
        _js.dumps({"error": "That request is too large"}),
        413,
        {"content-type": "application/json; charset=utf-8", "connection": "close"},
    )


def internal_error() -> Response:
    return Response(
        _js.dumps({"error": "Internal error", "code": "internal"}),
        500,
        {"content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff"},
    )


class Front:
    """Decides which requests are Runlight's and answers them: link domains, the app's short-link path, and the
    routes under their base path. Anything else is the app's, and `owns()` says so before the body is read."""

    def __init__(self, runlight: Any, routes: Any = None, observe: bool = True) -> None:
        self.runlight = runlight
        self.routes = routes if routes is not None else runlight.routes()
        self.observe = observe
        self._link = re.compile("^" + re.escape(runlight.link_path) + r"/[^/]+/?\Z")

    def bases(self) -> list[str]:
        return list(self.runlight.route_bases) or ["/runlight"]

    def link_domain(self, request: Request) -> Response | None:
        """The answer for a link domain, or None for every other host. Needs no body."""
        return self.runlight.link_domain_response(request, {"ip": request.remote_address})

    def owns(self, method: str, path: str) -> bool:
        """Whether a request on the app's own host is Runlight's: the short-link path, or under the routes' base."""
        if method == "GET" and self._link.match(path):
            return True
        for base in self.bases():
            if base == "/" or path == base or path.startswith(f"{base}/"):
                return True
        return False

    def answer(self, request: Request) -> Response:
        """The answer to a request owns() said is Runlight's."""
        try:
            path = Url(request.url).pathname
            if request.method == "GET" and self._link.match(path):
                return self.runlight.link_handler()(request, {"ip": request.remote_address})
            return self.routes.handle(request)
        except Exception as error:
            print(f"Runlight: {error!r}", file=sys.stderr)
            return internal_error()

    def watch(self, request: Request) -> None:
        """Records a page request that is the app's, when it comes from a known AI agent."""
        if self.observe and request.method == "GET":
            self.runlight.observe(request)


def request_url(scheme: str, host: str, raw_path: str) -> str:
    """The absolute URL a request was for, as `new URL(target, base)` makes it, falling back as the Node adapter
    does when it cannot be read."""
    target = raw_path if raw_path.startswith("/") else f"/{raw_path}"
    parsed = Url.parse(target, f"{'https' if scheme == 'https' else 'http'}://{host}")
    return parsed.href if parsed is not None else "http://localhost/"


def header_pairs(response: Response) -> list[tuple[str, str]]:
    """A response's headers as a server sends them: one pair per Set-Cookie, the rest joined."""
    out = []
    for name, values in response.headers.all().items():
        if name == "set-cookie":
            out.extend((name, v) for v in values)
        else:
            out.append((name, ", ".join(values)))
    return out


def merge(options: Mapping[str, Any] | None, kwargs: Mapping[str, Any]) -> dict[str, Any]:
    from .core import options_from

    return options_from(options, kwargs)
