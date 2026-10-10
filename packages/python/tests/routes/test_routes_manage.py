"""manage.test.ts, ported: what a hub's manage token may change, link domains kept off the dashboard's own names,
and a hub that never shows an install's answer as a page."""

from __future__ import annotations

from typing import Any
from urllib.parse import urlsplit

from runlight import _js
from runlight.http import Request, Response
from support.routes import body, runlight


def _app() -> tuple[Any, Any, Any]:
    """An app with two sites and an owner token, as a hub would connect to."""
    rl = runlight({"sites": [{"id": "blog", "hostnames": ["blog.example.com"]}, {"id": "shop", "hostnames": ["shop.example.com"]}]})
    routes = rl.routes({"token": "owner", "origin": "https://app.example.com"})

    def call(method: str, path: str, auth: str, given: Any = None) -> dict[str, Any]:
        headers = {"authorization": f"Bearer {auth}"}
        if given is not None:
            headers["content-type"] = "application/json"
        answer = routes.handle(Request(f"https://app.example.com/runlight{path}", method, headers, "" if given is None else _js.dumps(given)))
        ok, parsed = _js.try_loads(answer.text())
        return {"status": answer.status, "body": parsed if ok else None}

    def make(scope: str, site: str) -> str:
        return call("POST", "/api/tokens", "owner", {"name": "Hub", "scope": scope, "site": site})["body"]["secret"]

    return rl, call, make


def test_a_manage_token_changes_its_own_sites_settings_and_nothing_else() -> None:
    _, call, make = _app()
    assert call("POST", "/api/tokens", "owner", {"name": "Hub", "scope": "manage"})["status"] == 400, "a manage token is for one site"
    manage = make("manage", "blog")

    assert call("GET", "/api/token", manage)["body"] == {"scope": "manage", "site": "blog"}
    assert call("POST", "/api/goals?site=blog", manage, {"name": "Signup", "kind": "event", "match": "Signup"})["status"] == 201
    assert call("POST", "/api/goals", manage, {"name": "No site given", "kind": "event", "match": "x"})["status"] == 201, "its site is assumed"
    assert len(call("GET", "/api/goals?site=blog", "owner")["body"]["goals"]) == 2
    assert call("POST", "/api/goals?site=shop", manage, {"name": "Elsewhere", "kind": "event", "match": "x"})["status"] == 404, "never another site"
    assert len(call("GET", "/api/goals?site=shop", "owner")["body"]["goals"]) == 0
    assert call("PATCH", "/api/sites/shop", manage, {"name": "Mine now"})["status"] == 404
    assert call("PATCH", "/api/sites/blog", manage, {"hostnames": "evil.example"})["status"] == 403

    # Everything beyond one site's settings stays the owner's.
    assert call("GET", "/api/tokens", manage)["status"] == 401
    assert call("POST", "/api/tokens", manage, {"name": "More", "site": "blog"})["status"] == 403
    assert call("PUT", "/api/mail", manage, {"service": "webhook"})["status"] == 403
    assert call("GET", "/api/mail?site=blog", manage)["status"] == 200, "it can see which mail service sends reports"
    assert call("POST", "/api/shares?site=blog", manage, {"name": "For the team"})["status"] == 201, "share links for its site are its to make"
    assert call("POST", "/api/shares?site=shop", manage, {"name": "x"})["status"] == 404
    assert call("DELETE", "/api/sites/blog", manage)["status"] == 403
    assert call("POST", "/api/links/import?site=blog", manage, {"rows": []})["status"] == 403

    assert call("POST", "/api/links?site=blog", manage, {"url": "https://example.org/", "slug": "hello"})["status"] == 201
    assert len(call("GET", "/api/links?site=blog", manage)["body"]["links"]) == 1
    assert call("POST", "/api/reports?site=blog", manage, {"email": "me@example.com"})["status"] == 201
    assert call("PATCH", "/api/sites/blog", manage, {"name": "The blog", "retentionMonths": 12})["status"] == 200


def test_a_read_token_still_only_reads() -> None:
    _, call, make = _app()
    read = make("read", "blog")
    assert call("GET", "/api/token", read)["body"] == {"scope": "read", "site": "blog"}
    assert call("POST", "/api/goals?site=blog", read, {"name": "Signup", "kind": "event", "match": "Signup"})["status"] == 403
    assert call("GET", "/api/stats?site=blog&period=today", read)["status"] == 200


def test_a_link_domain_can_never_be_where_the_dashboard_or_a_counted_site_lives() -> None:
    _, call, _ = _app()
    assert call("POST", "/api/link-domains?site=blog", "owner", {"domain": "app.example.com"})["status"] == 400, "the dashboard's own host"
    assert call("POST", "/api/link-domains?site=blog", "owner", {"domain": "shop.example.com"})["status"] == 400, "a site's domain"
    assert call("POST", "/api/link-domains?site=blog", "owner", {"domain": "go.example.com"})["status"] == 201


class MailCatcher:
    """A mail webhook that keeps what it is sent, standing in for the small HTTP server manage.test.ts starts."""

    def __init__(self) -> None:
        self.mail: list[dict[str, Any]] = []

    def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
        self.mail.append(_js.loads((init or {}).get("body") or "{}"))
        return Response("ok")


def test_link_domains_stay_off_the_configured_address_and_the_names_people_signed_in_from() -> None:
    sent = MailCatcher()
    rl = runlight({"sites": [{"id": "blog", "hostnames": ["blog.example.com"]}], "fetcher": sent, "secret": "k"})
    routes = rl.routes({"token": "owner", "origin": "https://stats.example.com", "ownHosts": lambda: ["dash.example.net:443"]})

    def call(method: str, path: str, auth: str = "owner", given: Any = None) -> Response:
        headers = {"authorization": f"Bearer {auth}", "content-type": "application/json"}
        return routes.handle(Request(f"https://decoy.example.org/runlight{path}", method, headers, "" if given is None else _js.dumps(given)))

    def add(domain: str) -> int:
        return call("POST", "/api/link-domains?site=blog", "owner", {"domain": domain}).status

    for taken in ("stats.example.com", "stats.example.com.", "www.stats.example.com", "dash.example.net", "decoy.example.org"):
        assert add(taken) == 400, taken
    # Names inside private networks, which the check would make the install fetch.
    for inside in ("metadata.google.internal", "db.corp", "printer.local", "nas.home.arpa", "router.lan", "10.0.0.5.nip.io", "app.localhost"):
        assert add(inside) == 400, inside
    assert add("go.example.org") == 201
    # One saved before that rule is never fetched.
    rl.store.add_link_domain("db.internal", "blog", 0)
    check = body(call("GET", "/api/link-domains/db.internal/check?site=blog"))
    assert "target" in check, "and where a domain should point"
    del check["target"]
    assert check == {"domain": "db.internal", "working": False, "reason": "is not a public domain name", "code": "check_not_public"}

    # A hub's reports link to the configured address, never to the Host it names, and its samples share one wait.
    rl.save_mail_settings({"service": "webhook", "url": "https://hooks.example.net/mail", "from": "reports@example.com"})
    manage = body(call("POST", "/api/tokens", "owner", {"name": "Hub", "scope": "manage", "site": "blog"}))["secret"]
    first = body(call("POST", "/api/reports?site=blog", manage, {"email": "a@example.com"}))["report"]
    second = body(call("POST", "/api/reports?site=blog", manage, {"email": "b@example.com"}))["report"]
    assert [r["origin"] for r in rl.store.reports("blog")] == ["https://stats.example.com/runlight", "https://stats.example.com/runlight"]
    assert call("POST", f"/api/reports/{first['id']}/send?site=blog", manage).status == 200, "the first sample goes out"
    assert len(sent.mail) == 1
    assert sent.mail[0]["to"] == "a@example.com"
    assert "https://stats.example.com/runlight" in sent.mail[0]["text"], "its links point at the configured address"
    waits = call("POST", f"/api/reports/{second['id']}/send?site=blog", manage)
    assert waits.status == 429, "another report waits too"
    assert body(waits)["code"] == "sample_soon_hub"
    call("DELETE", f"/api/reports/{second['id']}?site=blog", manage)
    again = body(call("POST", "/api/reports?site=blog", manage, {"email": "b@example.com"}))["report"]
    assert call("POST", f"/api/reports/{again['id']}/send?site=blog", manage).status == 429, "and so does one added again"
    assert len(sent.mail) == 1


def test_without_its_own_address_an_app_gives_a_hub_no_link_domains_or_reports() -> None:
    # As the quickstart sets it up: one site, no origin, and the app answers on more names than the site's.
    rl = runlight({"site": {"name": "example.com", "hostnames": ["example.com"]}})
    routes = rl.routes({"token": "owner"})

    def call(host: str, method: str, path: str, auth: str, given: Any = None) -> dict[str, Any]:
        headers = {"host": host, "authorization": f"Bearer {auth}"}
        if given is not None:
            headers["content-type"] = "application/json"
        answer = routes.handle(Request(f"https://{host}/runlight{path}", method, headers, "" if given is None else _js.dumps(given)))
        ok, parsed = _js.try_loads(answer.text())
        return {"status": answer.status, "body": parsed if ok else None}

    manage = call("app.example.com", "POST", "/api/tokens", "owner", {"name": "Hub", "site": "default", "scope": "manage"})["body"]["secret"]
    # From the deployment's other name, where the app's own name is not the request's Host.
    added = call("example-app.vercel.app", "POST", "/api/link-domains", manage, {"domain": "app.example.com"})
    assert added["status"] == 400
    assert added["body"]["code"] == "origin_needed"
    assert call("example-app.vercel.app", "POST", "/api/reports", manage, {"email": "cfo@example.com"})["body"]["code"] == "origin_needed"
    assert call("app.example.com", "POST", "/api/link-domains", "owner", {"domain": "go.example.com"})["status"] == 201, "the owner still adds them"

    # On a link domain the dashboard's paths pass to the app, so the owner can always reach it there.
    for path in ("/runlight", "/runlight/api/sites"):
        assert rl.link_domain_response(Request(f"https://go.example.com{path}", "GET", {"host": "go.example.com"})) is None, path
    nothing = rl.link_domain_response(Request("https://go.example.com/nothing", "GET", {"host": "go.example.com"}))
    assert nothing is not None and nothing.status == 404
    # Middleware that never made the routes leaves the default path alone too.
    apart = runlight({"store": rl.store, "site": {"name": "example.com", "hostnames": ["example.com"]}})
    assert apart.link_domain_response(Request("https://go.example.com/runlight", "GET", {"host": "go.example.com"})) is None


class _Evil:
    def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
        path = urlsplit(url).path
        if path.startswith("/runlight/api/sites"):
            return Response(_js.dumps({"sites": [{"id": "x", "name": "X", "timezone": "UTC", "hostnames": ["x.example.com"]}]}), 200, {"content-type": "application/json"})
        if path.startswith("/runlight/api/stats"):
            return Response("<script>alert(1)</script>", 200, {"content-type": "text/html"})
        if path.startswith("/runlight/api/series"):
            return Response("", 302, {"location": "http://169.254.169.254/"})
        if path.startswith("/runlight/api/rhythm"):
            said = {"error": "Your session ended. Sign in again at https://evil.example/login " + "x" * 1000, "code": "link_taken", "params": {"slug": "a", "n": 5}}
            return Response(_js.dumps(said), 400, {"content-type": "application/json"})
        return Response("{}", 404)


def test_the_hub_never_passes_on_an_installs_answer_as_a_page_nor_follows_its_redirects() -> None:
    hub = runlight({"managedSites": True, "secret": "k" * 32, "fetcher": _Evil(), "localInstalls": True})
    routes = hub.routes({"token": "owner"})

    def call(path: str, method: str = "GET", given: str | None = None) -> Response:
        headers = {"authorization": "Bearer owner", "content-type": "application/json"}
        return routes.handle(Request(f"https://hub.example.com/runlight{path}", method, headers, given or ""))

    added = call("/api/sites", "POST", _js.dumps({"remote": {"url": "http://127.0.0.1:9/runlight", "token": "rl_x"}}))
    id_ = body(added)["site"]["id"]
    page = call(f"/api/stats?site={id_}&period=today")
    assert (page.headers.get("content-type") or "").startswith("application/json")
    assert page.headers.get("x-content-type-options") == "nosniff"
    assert "default-src 'none'" in (page.headers.get("content-security-policy") or "")
    assert call(f"/api/series?site={id_}&period=today").status == 502, "a redirect is reported, not followed"
    # An install's error says where it came from, short, with only its code and string params.
    said = body(call(f"/api/rhythm?site={id_}&period=today"))
    assert said["error"].startswith("127.0.0.1:9: Your session ended")
    assert len(said["error"]) < 340
    assert said["code"] == "link_taken"
    assert said["params"] == {"slug": "a"}


def test_a_connected_install_is_on_the_public_internet_unless_code_allows_this_machine() -> None:
    class Recording:
        def __init__(self) -> None:
            self.urls: list[str] = []

        def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
            self.urls.append(url)
            return Response(b"{}", 200, {"content-type": "application/json"})

    fetcher = Recording()
    hub = runlight({"managedSites": True, "secret": "k" * 32, "fetcher": fetcher})
    routes = hub.routes({"token": "owner"})

    def add(url: str) -> dict[str, Any]:
        given = _js.dumps({"remote": {"url": url, "token": "rl_x"}})
        headers = {"authorization": "Bearer owner", "content-type": "application/json"}
        return body(routes.handle(Request("https://hub.example.com/runlight/api/sites", "POST", headers, given)))

    assert add("http://127.0.0.1:9/runlight")["code"] == "connect_url"
    assert add("http://localhost:9/runlight")["code"] == "connect_url"
    for url in ["https://127.0.0.1/runlight", "https://169.254.169.254/latest", "https://[::1]/runlight", "https://10.0.0.2", "https://localhost/runlight"]:
        assert add(url)["code"] == "unreachable", url
    assert fetcher.urls == [], "nothing is asked of an address off the public internet"
