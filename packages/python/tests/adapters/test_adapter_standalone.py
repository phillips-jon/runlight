"""The standalone server's own behaviour, as packages/server/test/server.test.ts checks the Node one's (and the PHP
port's StandaloneTest), then its WSGI app on a real socket."""

from __future__ import annotations

import http.client
import threading
import urllib.parse
from collections.abc import Iterator, Mapping
from typing import Any
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server

import pytest
from adapter_scenario import CHROME

from runlight import _js
from runlight.http import Request, Response, SearchParams
from runlight.server.standalone import RunlightServer, create_server, wsgi_app
from runlight.store import Stores

ORIGIN = "https://stats.example.com"
CODE = "one-time-code"
NOW = 1_791_374_400_000  # 2026-10-07 12:00 UTC
SECRET = "s" * 64


def make(**options: Any) -> RunlightServer:
    given: dict[str, Any] = {"store": Stores.sqlite(":memory:"), "secret": SECRET, "now": lambda: NOW, "setupCode": CODE}
    given.update(options)
    return create_server(given)


def req(path: str, method: str = "GET", headers: Mapping[str, str] | None = None, body: str = "", host: str | None = None) -> Request:
    return Request((f"https://{host}" if host is not None else ORIGIN) + path, method, dict(headers or {}), body)


def form(path: str, fields: Mapping[str, str], headers: Mapping[str, str] | None = None) -> Request:
    return req(path, "POST", {"content-type": "application/x-www-form-urlencoded", **(headers or {})}, SearchParams(dict(fields)).to_string())


def cookie_of(response: Response) -> str:
    return (response.headers.get("set-cookie") or "").split(";")[0]


def json(body: Any) -> str:
    return _js.dumps(body)


AUTH = {"authorization": "Bearer script-token", "content-type": "application/json"}


def test_a_new_server_is_locked_until_the_setup_code_makes_the_first_account() -> None:
    server = make(setupWhere="in setup.txt")
    # The dashboard waits for setup.
    assert server.handle(req("/")).status == 403
    assert "Open the setup link in setup.txt" in server.handle(req("/")).text()
    assert server.handle(req("/setup?code=wrong")).status == 403
    assert server.handle(form("/setup", {"code": "wrong", "email": "a@b.co", "password": "long enough pw"})).status == 403
    assert server.handle(req(f"/setup?code={CODE}")).status == 200
    mismatch = server.handle(form("/setup", {"code": CODE, "email": "a@b.co", "password": "a long password", "again": "a long pasword"}))
    # The password is asked twice.
    assert mismatch.status == 400
    made = server.handle(form("/setup", {"code": CODE, "email": "Jon@Example.com", "password": "a long password", "again": "a long password"}))
    assert made.status == 303
    assert made.headers.get("location") == "/"
    # Signed straight in.
    assert server.handle(req("/", "GET", {"cookie": cookie_of(made)})).status == 200
    # Setup closes once an account exists.
    assert server.handle(req(f"/setup?code={CODE}")).headers.get("location") == "/login"


def test_without_a_code_given_one_is_made_at_start_as_the_node_server_does() -> None:
    # PHP serves each request anew and can fall back to the token; a Python server runs on, as Node's does.
    server = make(setupCode=None, token="script-token")
    assert len(server.setup_code) >= 8
    assert server.setup_code != make(setupCode=None).setup_code
    token = form("/setup", {"code": "script-token", "email": "a@b.co", "password": "a long password", "again": "a long password"})
    assert server.handle(token).status == 403
    made = form("/setup", {"code": server.setup_code, "email": "a@b.co", "password": "a long password", "again": "a long password"})
    assert server.handle(made).status == 303


def test_sign_in_sign_out_and_sessions_that_end_with_a_password_change() -> None:
    server = make()
    server.accounts.set_password("jon@example.com", "a long password", NOW)
    away = server.handle(req("/?period=7d"))
    assert away.status == 303
    assert away.headers.get("location") == "/login?next=" + urllib.parse.quote("/?period=7d", safe="")
    assert server.handle(req("/api/sites")).status == 401
    assert server.handle(form("/login", {"email": "jon@example.com", "password": "nope nope nope"})).status == 401

    ok = server.handle(form("/login", {"email": "JON@example.com", "password": "a long password", "next": "//evil.example"}))
    assert ok.status == 303
    # A next address off this server is ignored.
    assert ok.headers.get("location") == "/"
    cookie = cookie_of(ok)
    assert server.handle(req("/api/sites", "GET", {"cookie": cookie})).status == 200
    assert 'data-sign-out="/logout"' in server.handle(req("/", "GET", {"cookie": cookie})).text()
    assert "Max-Age=0" in (server.handle(req("/logout")).headers.get("set-cookie") or "")

    server.accounts.set_password("jon@example.com", "another long password", NOW)
    # A new password signs out every browser.
    assert server.handle(req("/api/sites", "GET", {"cookie": cookie})).status == 401


def test_sites_are_added_counted_and_short_links_answer_on_their_own_domains() -> None:
    server = make(token="script-token")
    server.accounts.set_password("jon@example.com", "a long password", NOW)

    assert server.handle(req("/api/sites", "POST", AUTH, json({"name": "Blog", "hostnames": "blog.example.com"}))).status == 201
    assert server.handle(req("/s.js")).status == 200
    hit = server.handle(
        req(
            "/e",
            "POST",
            {"user-agent": CHROME, "x-forwarded-for": "203.0.113.9"},
            json({"k": "pageview", "u": "https://blog.example.com/post", "s": "blog.example.com"}),
        )
    )
    assert hit.status == 202
    stats = _js.loads(server.handle(req("/api/stats?site=blog.example.com&period=today", "GET", AUTH)).text())
    assert stats["stats"]["pageviews"] == 1

    added = server.handle(req("/api/link-domains?site=blog.example.com", "POST", AUTH, json({"domain": "go.example.com"})))
    assert added.status == 201
    made = _js.loads(
        server.handle(
            req(
                "/api/links?site=blog.example.com",
                "POST",
                AUTH,
                json({"url": "https://blog.example.com/launch", "slug": "launch", "domain": "go.example.com"}),
            )
        ).text()
    )
    assert made["link"]["slug"] == "launch"
    short = server.handle(req("/launch", host="go.example.com"))
    assert short.status == 302
    assert short.headers.get("location") == "https://blog.example.com/launch"
    # Every link also answers at /go/:slug on the server itself.
    assert server.handle(req("/go/launch")).status == 302

    health = server.handle(req("/healthz"))
    assert (health.status, health.text()) == (200, "ok")
    assert server.handle(req("/api/sites", "GET", {"authorization": "Bearer wrong"})).status == 401


def test_a_link_domain_never_takes_over_the_dashboards_own_name_sign_in_or_api() -> None:
    server = make(token="script-token")
    server.accounts.set_password("jon@example.com", "a long password", NOW)
    server.handle(req("/api/sites", "POST", AUTH, json({"name": "Blog", "hostnames": "blog.example.com"})))

    def add_domain(domain: str, host: str) -> Response:
        return server.handle(req("/api/link-domains?site=blog.example.com", "POST", AUTH, json({"domain": domain}), host))

    # Someone signs in at stats.example.com, so a caller naming another Host cannot add it afterwards.
    cookie = cookie_of(server.handle(form("/login", {"email": "jon@example.com", "password": "a long password"})))
    assert server.handle(req("/api/sites", "GET", {"cookie": cookie})).status == 200
    for host in ["decoy.example.org", "203.0.113.5", "stats.example.com."]:
        assert add_domain("stats.example.com", host).status == 400, host

    # Added anyway: its short links answer, and the server's own pages stay the server's.
    server.runlight.store.add_link_domain("stats.example.com", "blog.example.com", NOW)
    server.runlight.forget_link_domains()
    for slug, to in (("login", "https://blog.example.com/a"), ("sale", "https://blog.example.com/b")):
        server.handle(
            req("/api/links?site=blog.example.com", "POST", AUTH, json({"url": to, "slug": slug, "domain": "stats.example.com"}))
        )
    assert server.handle(req("/sale")).status == 302
    # Sign-in is still the sign-in page.
    assert server.handle(req("/login")).status == 200
    # The dashboard opens for someone signed in.
    assert server.handle(req("/", "GET", {"cookie": cookie})).status == 200
    assert server.handle(req("/")).status == 404
    # So it can be removed.
    removed = server.handle(req("/api/link-domains/stats.example.com?site=blog.example.com", "DELETE", {"cookie": cookie}))
    assert removed.status == 200
    assert server.handle(req("/sale")).status == 404

    # With the public address set, short links never answer there, and nobody can add it under any Host.
    named = make(token="script-token", url=ORIGIN)
    named.handle(req("/api/sites", "POST", AUTH, json({"name": "Blog", "hostnames": "blog.example.com"})))
    refused = named.handle(
        req("/api/link-domains?site=blog.example.com", "POST", AUTH, json({"domain": "stats.example.com"}), "decoy.example.org")
    )
    assert refused.status == 400
    named.runlight.store.add_link_domain("stats.example.com", "blog.example.com", NOW)
    named.runlight.forget_link_domains()
    named.handle(
        req(
            "/api/links?site=blog.example.com",
            "POST",
            AUTH,
            json({"url": "https://blog.example.com/b", "slug": "sale", "domain": "stats.example.com"}),
        )
    )
    assert named.handle(req("/sale")).status == 404
    # The dashboard, waiting for setup.
    assert named.handle(req("/")).status == 403


def test_only_the_owner_and_admins_teach_the_server_its_names() -> None:
    server = make()
    owner = server.accounts.set_password("jon@example.com", "a long password", NOW)
    viewer = server.accounts.set_password("viewer@example.com", "another long one", NOW, "viewer")

    def as_(user: dict[str, Any]) -> str:
        return "runlight_session=" + urllib.parse.quote(server.accounts.session_for(user, NOW), safe="")

    def names() -> list[str]:
        return _js.loads(server.runlight.store.setting("server-hosts") or "[]")

    for i in range(25):
        server.handle(req("/api/sites", "GET", {"cookie": as_(viewer), "x-forwarded-host": f"junk{i}.example.org"}))
    # A viewer's made-up forwarded names fill nothing.
    assert names() == []
    server.handle(req("/api/sites", "GET", {"cookie": as_(owner), "x-forwarded-host": "203.0.113.7:8080"}))
    server.handle(req("/api/sites", "GET", {"cookie": as_(owner)}))
    # An owner's are learned, if they are domain names.
    assert names() == ["stats.example.com"]

    # Another copy of the server reads them back from the database.
    again = create_server(store=server.runlight.store, secret=SECRET, now=lambda: NOW)
    headers = {"cookie": as_(owner), "content-type": "application/json"}
    again.handle(req("/api/sites", "POST", headers, json({"name": "Blog", "hostnames": "blog.example.com"})))
    refused = again.handle(
        req("/api/link-domains?site=blog.example.com", "POST", headers, json({"domain": "stats.example.com"}), "decoy.example.org")
    )
    assert refused.status == 400


def test_check_runs_the_scheduled_work() -> None:
    assert make().check() == {"ok": True, "reports": {"sent": 0, "failed": 0}}


class _Quiet(WSGIRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        pass


@pytest.fixture
def served() -> Iterator[tuple[RunlightServer, int]]:
    server = make(token="script-token")
    httpd = make_server("127.0.0.1", 0, wsgi_app(server), WSGIServer, _Quiet)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield server, httpd.server_address[1]
    httpd.shutdown()
    httpd.server_close()


def fetch(port: int, method: str, path: str, headers: Mapping[str, str] | None = None, body: bytes | None = None) -> Any:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(method, path, body=body, headers={"host": "stats.example.com", **(headers or {})})
    answer = connection.getresponse()
    data = answer.read()
    connection.close()
    return answer, data


def test_the_wsgi_app_on_a_real_socket(served: tuple[RunlightServer, int]) -> None:
    server, port = served
    auth = {"authorization": "Bearer script-token", "content-type": "application/json"}
    answer, _ = fetch(port, "POST", "/api/sites", auth, json({"name": "Blog", "hostnames": "blog.example.com"}).encode())
    assert answer.status == 201

    answer, data = fetch(port, "GET", "/s.js")
    assert answer.status == 200
    assert len(data) > 100
    answer, data = fetch(port, "HEAD", "/healthz")
    assert answer.status == 200
    assert data == b""

    hit = json({"k": "pageview", "u": "https://blog.example.com/post", "s": "blog.example.com"}).encode()
    answer, _ = fetch(port, "POST", "/e", {"user-agent": CHROME, "x-forwarded-for": "203.0.113.9"}, hit)
    assert answer.status == 202
    answer, data = fetch(port, "GET", "/api/stats?site=blog.example.com&period=today", auth)
    assert _js.loads(data)["stats"]["pageviews"] == 1

    answer, _ = fetch(port, "POST", "/e", {"content-type": "text/plain"}, b"x" * (20 * 1024))
    assert answer.status == 413

    made, _ = fetch(port, "POST", "/api/links?site=blog.example.com", auth, b'{"url":"https://blog.example.com/a","slug":"a"}')
    assert made.status == 201
    answer, _ = fetch(port, "GET", "/go/a")
    assert answer.status == 302
    assert answer.headers.get("location") == "https://blog.example.com/a"
