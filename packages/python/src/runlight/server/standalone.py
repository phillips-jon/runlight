"""The standalone server: Runlight's routes at the root of their own domain, behind a sign-in, with sites managed in
the dashboard and short links answered on any domain pointed at it. A port of packages/server/src/server.ts."""

from __future__ import annotations

import re
import secrets
import sys
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

from .. import _js
from ..http import Request, Response, Url

# The server's own pages, which answer as the server on every name it is reached at, a link domain too.
SERVER_PATHS = {"/login", "/logout", "/setup", "/invite", "/healthz", "/auth.css", "/auth.js", "/api", "/mcp", "/s.js", "/pick.js", "/e"}

# The most names remembered as the server's own. The first ones stay and later ones are not learned, so a server
# reached at more names than this needs RUNLIGHT_URL to keep the rest from becoming link domains.
MAX_OWN_HOSTS = 20


class RunlightServer:
    """What create_server() gives: the Runlight, its accounts, the handler, and the setup code.

    Options (the TS ServerOptions names): store, secret (signs sessions and encrypts saved keys; keep it stable),
    token (also accepted as a bearer token on the API), url (the dashboard's public address, which can never
    become a link domain), trustProxy (default True), geo, geoCredit, now, and fetcher. setupCode replaces the
    one-time code made at start, for a server whose code is kept in a file."""

    def __init__(self, options: Mapping[str, Any]) -> None:
        from ..accounts.web import accounts_web, setup_code
        from ..core import Runlight
        from ..routes import host_name

        self._store = options["store"]
        now = options.get("now") or (lambda: time.time_ns() // 1_000_000)
        self.setup_code: str = options.get("setupCode") or setup_code()
        self._token: str | None = options.get("token") or None
        self._trust_proxy = options.get("trustProxy", True)
        url = options.get("url")
        self._public_url = Url(url) if url else None
        self._public_host = host_name(self._public_url.host) if self._public_url else None
        self._own_hosts: list[str] | None = None
        self._hosts_lock = threading.Lock()

        runlight: dict[str, Any] = {
            "store": self._store,
            "managedSites": True,
            "secret": options["secret"],
            "trustProxy": self._trust_proxy,
            "now": now,
        }
        if options.get("geo") is not None:
            runlight["geo"] = options["geo"]
        if options.get("fetcher") is not None:
            runlight["fetcher"] = options["fetcher"]
        self.runlight = rl = Runlight(runlight)

        # Accounts, shared with apps that turn them on. The first one is made with the code the server prints at
        # start, and emails link to its public address, or else the first name the owner or an admin signed in from.
        web_options: dict[str, Any] = {
            "runlight": rl,
            "secret": options["secret"],
            "base": "",
            "now": now,
            "firstAccount": {"code": self.setup_code},
            "home": self._home,
            "forgot": "https://runlight.sh/docs/python/#forgotten-passwords",
        }
        if options.get("setupWhere"):
            web_options["setupWhere"] = options["setupWhere"]
        self.web = accounts_web(web_options)
        self.accounts = self.web.accounts

        routes: dict[str, Any] = {
            "basePath": "",
            # Without a secret of its own, the cron route is never needed: the server runs the check itself.
            "cronSecret": options.get("cronSecret") or secrets.token_hex(32),
            "observeKey": options.get("observeKey") or "",
            "signOut": "/logout",
            "signIn": "/login",
            "geoCredit": bool(options.get("geoCredit", False)),
            "accounts": self.web,
            "authorize": self._authorize,
            "ownHosts": self._known_hosts,
        }
        if self._public_url is not None:
            routes["origin"] = self._public_url.origin
        self.routes = rl.routes(routes)
        self._links = rl.link_handler()

    def _home(self) -> str | None:
        if self._public_url is not None:
            return self._public_url.origin
        hosts = self._known_hosts()
        return f"https://{hosts[0]}" if hosts else None

    def _authorize(self, request: Request) -> Any:
        from ..accounts.crypto import same_text

        auth = request.headers.get("authorization") or ""
        if self._token and auth.lower().startswith("bearer ") and same_text(_js.trim(auth[7:]), self._token):
            return True
        access = self.web.access(request)
        if access is True:
            self._learn_host(request)
        return access

    def _host_of(self, request: Request) -> str:
        """The name a request came in on, read as link domains read it."""
        from ..routes import host_name

        forwarded = request.headers.get("x-forwarded-host") if self._trust_proxy is not False else None
        given = forwarded if forwarded is not None else request.headers.get("host")
        return host_name(given if given is not None else Url(request.url).host)

    def _saved_hosts(self) -> list[str]:
        self.runlight.init()
        ok, saved = _js.try_loads(self._store.setting("server-hosts") or "[]")
        return [h for h in saved if isinstance(h, str)] if ok and isinstance(saved, list) else []

    def _known_hosts(self) -> list[str]:
        """The names the owner and admins signed in from, kept in the database, so a link domain can never be one of
        them even when whoever adds it picks another Host header."""
        if self._own_hosts is None:
            self._own_hosts = self._saved_hosts()
        return list(self._own_hosts)

    def _learn_host(self, request: Request) -> None:
        """Only the owner and admins teach the server its names, since anyone else could fill the list with made-up
        ones, and only real domain names. Names that are already link domains are left out."""
        from ..routes import DOMAIN_NAME

        host = self._host_of(request)
        with self._hosts_lock:
            known = self._known_hosts()
            if not DOMAIN_NAME.match(host) or host in known or len(known) >= MAX_OWN_HOSTS:
                return
            if any(d["domain"] == host for d in self._store.link_domains()):
                return
            # Another copy of the server may have saved names since this one read them.
            for saved in self._saved_hosts():
                if saved not in known:
                    known.append(saved)
            known.append(host)
            self._own_hosts = known[:MAX_OWN_HOSTS]
            self._store.set_setting("server-hosts", _js.dumps(self._own_hosts))

    def handle(self, request: Request, context: Mapping[str, Any] | None = None) -> Response:
        """The answer to one request."""
        from ..core import LINK_DOMAIN_CHECK
        from ..routes import coded

        context = dict(context or {"ip": request.remote_address})
        path = Url(request.url).pathname
        try:
            # A domain pointed at this server for short links answers at its root, with links one segment deep. The
            # server's own pages and its public address never answer as links, and "/" stays the dashboard for
            # someone signed in, so a link domain added on the dashboard's own name can always be removed again.
            linkable = path == LINK_DOMAIN_CHECK or (
                re.fullmatch(r"/[^/]*", path) is not None
                and path not in SERVER_PATHS
                and not (path == "/" and self.web.signed_in(request))
            )
            if linkable and not (self._public_host is not None and self._host_of(request) == self._public_host):
                linked = self.runlight.link_domain_response(request, context)
                if linked is not None:
                    return linked
            if path == "/healthz":
                return Response("ok", 200, {"content-type": "text/plain", "cache-control": "no-store"})
            if request.method == "GET" and re.fullmatch(r"/go/[^/]+/?", path):
                return self._links(request, context)
            # Everything else, the sign-in pages and People included, is the routes'.
            return self.routes.handle(request)
        except Exception as error:
            print(f"Runlight: {error!r}", file=sys.stderr)
            return coded("Internal error", "internal", 500)

    def check(self) -> dict[str, Any]:
        """The scheduled work: salts, email reports that are due, retention, and rollups."""
        result = self.runlight.check()
        self.runlight.idle()
        return result


def create_server(options: Mapping[str, Any] | None = None, **kwargs: Any) -> RunlightServer:
    from ..core import options_from

    return RunlightServer(options_from(options, kwargs))


def wsgi_app(server: RunlightServer) -> Callable[..., Any]:
    """The server as a WSGI app, for gunicorn or any WSGI server."""
    from ..serve import too_large
    from ..wsgi import BodyTooLarge, _After, send, to_request

    def application(environ: Mapping[str, Any], start_response: Callable[..., Any]) -> Any:
        head = str(environ.get("REQUEST_METHOD", "")).upper() == "HEAD"
        try:
            request = to_request(environ)
        except BodyTooLarge:
            return send(too_large(), start_response, head)
        return _After(send(server.handle(request), start_response, head), server.runlight.idle)

    return application
