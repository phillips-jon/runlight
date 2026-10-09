"""Runlight in a Django project. Needs Django 5.2 or newer.

    # settings.py
    INSTALLED_APPS = [..., "runlight.django"]
    MIDDLEWARE = ["runlight.django.RunlightMiddleware", ...]
    RUNLIGHT = "myproject.analytics.rl"          # the Runlight, or a dotted path to it (or to a function making it)
    RUNLIGHT_ROUTES = {"token": os.environ["RUNLIGHT_TOKEN"]}   # optional: routes() options, TS names

    # myproject/analytics.py
    from runlight import Runlight
    from runlight.store import Stores
    rl = Runlight(store=Stores.sqlite(BASE_DIR / "data" / "runlight.db"), site={"hostnames": ["example.com"]})

    # crontab: the scheduled upkeep, every few minutes
    */5 * * * * cd /app && python manage.py runlight_check

The middleware answers the dashboard and API under /runlight, short links at /go/{slug}, and every request to a link
domain added in Settings (which must be in ALLOWED_HOSTS), before Django's URLs, and records page requests from known
AI agents. The URL is Django's (request.scheme, so SECURE_PROXY_SSL_HEADER applies), and the address is REMOTE_ADDR:
Runlight reads proxy headers itself, as its trustProxy option says.
"""

from __future__ import annotations

import importlib
import threading
from collections.abc import Callable
from typing import Any

try:
    import django  # noqa: F401
except ImportError as error:  # pragma: no cover
    raise ImportError("runlight.django needs Django: pip install django") from error

from ..http import Request, Response
from ..serve import HOP_BY_HOP, Front, body_limit, request_url, too_large

_lock = threading.Lock()
_front: Front | None = None


def _resolve(value: Any) -> Any:
    """The Runlight a setting names: itself, a dotted path ("pkg.mod.rl" or "pkg.mod:rl"), or a function making one."""
    if isinstance(value, str):
        module, _, name = value.rpartition(":") if ":" in value else value.rpartition(".")
        value = getattr(importlib.import_module(module), name)
    if callable(value) and not hasattr(value, "routes"):
        value = value()
    return value


def runlight() -> Any:
    """The project's Runlight, from settings.RUNLIGHT."""
    from django.conf import settings
    from django.core.exceptions import ImproperlyConfigured

    value = getattr(settings, "RUNLIGHT", None)
    if value is None:
        raise ImproperlyConfigured("Set RUNLIGHT in settings to your Runlight, or a dotted path to it")
    return _resolve(value)


def front() -> Front:
    """The routes and link handling the middleware serves, made once."""
    global _front
    with _lock:
        if _front is None:
            from django.conf import settings

            rl = runlight()
            options = dict(getattr(settings, "RUNLIGHT_ROUTES", None) or {})
            observe = bool(options.pop("observe", True))
            _front = Front(rl, rl.routes(options), observe)
        return _front


def reset() -> None:
    """Forgets the routes made from the settings, for tests that change them."""
    global _front
    with _lock:
        _front = None


def to_request(request: Any, with_body: bool = True) -> Request:
    """A Django HttpRequest as a Request."""
    meta = request.META
    raw = meta.get("RAW_URI") or meta.get("REQUEST_URI") or request.get_full_path()
    headers = [(name.lower(), value) for name, value in request.headers.items()]
    body = b""
    if with_body and request.method not in ("GET", "HEAD"):
        limit = body_limit(request.path)
        try:
            length = int(meta.get("CONTENT_LENGTH") or 0)
        except ValueError:
            length = 0
        if length > limit:
            raise _TooLarge()
        body = request.read(limit + 1)
        if len(body) > limit:
            raise _TooLarge()
    return Request(request_url(request.scheme, request.get_host(), raw), request.method, headers, body, meta.get("REMOTE_ADDR", ""))


class _TooLarge(Exception):
    pass


def to_response(response: Response) -> Any:
    """A Response as Django sends it, streamed when Runlight streams it (exports), each Set-Cookie as given."""
    from django.http import HttpResponse, StreamingHttpResponse

    class _Raw:
        """Set-Cookie lines sent as Runlight wrote them, after the other headers, as Django's handlers send items()."""

        raw_cookies: list[str] = []

        def items(self) -> Any:
            return [*super().items(), *(("Set-Cookie", c) for c in self.raw_cookies)]  # type: ignore[misc]

    base = StreamingHttpResponse if response.streamed else HttpResponse
    cls = type("RunlightResponse", (_Raw, base), {})
    out = cls(response.chunks(), status=response.status) if response.streamed else cls(response.content(), status=response.status)
    out.raw_cookies = response.headers.get_set_cookie()
    if "content-type" not in response.headers:
        del out["Content-Type"]
    for name, values in response.headers.all().items():
        # The connection is the server's: under WSGI a hop-by-hop header is refused (wsgiref answers 500 for one).
        if name != "set-cookie" and name not in HOP_BY_HOP:
            out[name] = ", ".join(values)
    return out


class RunlightMiddleware:
    """Answers Runlight's requests before Django's URLs, and records page requests from known AI agents."""

    def __init__(self, get_response: Callable[[Any], Any]) -> None:
        self.get_response = get_response

    def __call__(self, request: Any) -> Any:
        serving = front()
        head = request.method == "HEAD"
        bare = to_request(request, with_body=False)
        linked = serving.link_domain(bare)
        if linked is not None:
            return self._finish(serving, linked, head)
        if not serving.owns(request.method, request.path):
            serving.watch(bare)
            return self.get_response(request)
        try:
            full = to_request(request)
        except _TooLarge:
            return to_response(too_large())
        return self._finish(serving, serving.answer(full), head)

    @staticmethod
    def _finish(serving: Front, response: Response, head: bool) -> Any:
        from django.core.signals import request_finished

        out = to_response(response)
        rl = serving.runlight

        # The work a request starts after answering (a retention change's deletions) runs once Django has sent it.
        def idle(**_: Any) -> None:
            request_finished.disconnect(idle)
            rl.idle()

        request_finished.connect(idle, weak=False)
        return out
