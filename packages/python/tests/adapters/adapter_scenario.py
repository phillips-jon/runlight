"""What every adapter test checks, through a client of its own: the tracker script and a hit, the stats that hit
makes, short links on the app's path and on a link domain, the app's own pages passed through, a body too large,
several Set-Cookie lines, HEAD, and AI agent page fetches."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any, Protocol

from runlight import Runlight, _js
from runlight.http import Request, Response, Url
from runlight.store import Stores

NOW = 1_791_374_400_000
TOKEN = "app-token"
CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
CHATGPT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot"
LINK_DOMAIN = "links.example.org"
APP_PAGE = "hello from the app"
# Two cookies, one with a comma in its date, which must arrive as two lines and never be joined or split.
COOKIES = [
    "a=1; Path=/; HttpOnly; SameSite=Lax",
    "b=2; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT",
]


@dataclass
class Answer:
    status: int
    headers: list[tuple[str, str]] = field(default_factory=list)
    body: bytes = b""

    def header(self, name: str) -> str | None:
        found = [v for k, v in self.headers if k.lower() == name]
        return ", ".join(found) if found else None

    def cookies(self) -> list[str]:
        return [v for k, v in self.headers if k.lower() == "set-cookie"]

    def json(self) -> Any:
        return _js.loads(self.body)


class Client(Protocol):
    def __call__(
        self, method: str, path: str, headers: Mapping[str, str] | None = None, body: bytes = b"", host: str = "example.com"
    ) -> Answer: ...


def make_runlight() -> Runlight:
    return Runlight(
        store=Stores.sqlite(":memory:"),
        site={"name": "example.com", "hostnames": ["example.com"]},
        now=lambda: NOW,
    )


class CookieRoutes:
    """The routes, plus /runlight/cookies, which answers with several Set-Cookie lines."""

    def __init__(self, routes: Any) -> None:
        self.routes = routes

    def handle(self, request: Request) -> Response:
        if Url(request.url).pathname == "/runlight/cookies":
            return Response("{}", 200, [("content-type", "application/json"), *(("set-cookie", c) for c in COOKIES)])
        return self.routes.handle(request)


def routes_for(rl: Runlight) -> CookieRoutes:
    return CookieRoutes(rl.routes({"token": TOKEN}))


def owner(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    return {"authorization": f"Bearer {TOKEN}", "content-type": "application/json", **(extra or {})}


def agent_fetches(rl: Runlight) -> list[dict[str, Any]]:
    return rl.store.db.all("SELECT name, path, hostname FROM rl_events WHERE kind = 'fetch' ORDER BY ts")


def check_everything(rl: Runlight, call: Client, passes_through: bool = True, observes: bool = True) -> None:
    """Runs every check through `call`. `passes_through` says whether an app sits behind Runlight (else other paths
    are a 404), and `observes` whether page fetches by AI agents are recorded."""
    script = call("GET", "/runlight/s.js")
    assert script.status == 200
    assert "javascript" in (script.header("content-type") or "")
    assert len(script.body) > 100

    # The routes answer GET only, as TS's do, so HEAD is their JSON 404, sent with no body.
    head = call("HEAD", "/runlight/s.js")
    assert head.status == 404
    assert (head.header("content-type") or "").startswith("application/json")
    assert head.body == b""

    hit = call(
        "POST",
        "/runlight/e",
        {"user-agent": CHROME, "content-type": "text/plain;charset=UTF-8"},
        _js.dumps({"k": "pageview", "u": "https://example.com/post", "s": "default"}).encode(),
    )
    assert hit.status == 202, hit.body

    stats = call("GET", "/runlight/api/stats?period=today", {"authorization": f"Bearer {TOKEN}"})
    assert stats.status == 200, stats.body
    assert stats.json()["stats"]["pageviews"] == 1

    made = call("POST", "/runlight/api/links", owner(), b'{"url":"https://example.org/sale","slug":"sale"}')
    assert made.status == 201, made.body
    go = call("GET", "/go/sale")
    assert go.status == 302
    assert go.header("location") == "https://example.org/sale"

    rl.store.add_link_domain(LINK_DOMAIN, "default", NOW)
    rl.forget_link_domains()
    made = call(
        "POST", "/runlight/api/links", owner(), _js.dumps({"url": "https://example.org/x", "slug": "x", "domain": LINK_DOMAIN}).encode()
    )
    assert made.status == 201, made.body
    linked = call("GET", "/x", host=LINK_DOMAIN)
    assert linked.status == 302
    assert linked.header("location") == "https://example.org/x"
    checked = call("GET", "/.well-known/runlight-link-domain", host=LINK_DOMAIN)
    assert checked.status == 200
    assert checked.json() == {"runlight": True, "domain": LINK_DOMAIN}
    assert call("GET", "/hello", host=LINK_DOMAIN).status == 404

    page = call("GET", "/hello")
    if passes_through:
        assert page.status == 200
        assert page.body.decode() == APP_PAGE
    else:
        assert page.status == 404

    large = call("POST", "/runlight/e", {"content-type": "text/plain"}, b"x" * (20 * 1024))
    assert large.status == 413

    cookies = call("GET", "/runlight/cookies")
    assert cookies.status == 200
    assert cookies.cookies() == COOKIES

    fetched = call("GET", "/hello", {"user-agent": CHATGPT})
    assert fetched.status == (200 if passes_through else 404)
    call("GET", "/style.css", {"user-agent": CHATGPT})
    if observes:
        assert agent_fetches(rl) == [{"name": "ChatGPT-User", "path": "/hello", "hostname": "example.com"}]
    else:
        assert agent_fetches(rl) == []


