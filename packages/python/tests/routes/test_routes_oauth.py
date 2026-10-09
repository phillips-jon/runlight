"""oauth.test.ts, ported: an app connecting to the MCP server over OAuth, through the routes."""

from __future__ import annotations

import base64
import calendar
import hashlib
import re
import secrets
from typing import Any

from runlight import _js
from runlight.http import Request, Response, SearchParams, Url
from support.routes import body, runlight


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _at(url: str, method: str = "GET", headers: dict[str, str] | None = None, given: str | None = None) -> Request:
    all_headers = dict(headers or {})
    if given is not None and "content-type" not in all_headers:
        all_headers["content-type"] = "text/plain;charset=UTF-8"
    return Request(url, method, all_headers, given or "")


def _form(fields: dict[str, str]) -> str:
    return SearchParams(fields).to_string()


def _register(routes: Any, name: str, redirect: str, context: dict[str, Any] | None = None) -> Response:
    given = _js.dumps({"client_name": name, "redirect_uris": [redirect]})
    return routes.handle(_at("https://x.com/runlight/oauth/register", "POST", {"content-type": "application/json"}, given), context)


def test_an_app_connects_to_the_mcp_server_over_oauth() -> None:
    rl = runlight({"sites": [{"id": "a", "name": "Site A", "hostnames": ["a.com"]}, {"id": "b", "name": "Site B", "hostnames": ["b.com"]}]})
    routes = rl.routes({"token": "secret"})
    origin = "https://x.com"
    owner = {"authorization": "Bearer secret"}
    form = {"content-type": "application/x-www-form-urlencoded"}

    # The MCP endpoint points at the metadata.
    refused = routes.handle(_at(f"{origin}/runlight/mcp", "POST", {"content-type": "application/json"}, "{}"))
    assert refused.status == 401
    m = re.search(r'resource_metadata="([^"]+)"', refused.headers.get("www-authenticate") or "")
    assert m and m.group(1) == f"{origin}/runlight/.well-known/oauth-protected-resource"
    resource = body(routes.handle(_at(m.group(1))))
    assert resource["authorization_servers"] == [f"{origin}/runlight"]
    assert resource["resource"] == f"{origin}/runlight/mcp"
    server = body(routes.handle(_at(f"{origin}/.well-known/oauth-authorization-server/runlight")))
    assert server["token_endpoint"] == f"{origin}/runlight/oauth/token"
    assert server["code_challenge_methods_supported"] == ["S256"]

    # Registration.
    evil = _js.dumps({"redirect_uris": ["http://evil.example/cb"]})
    assert routes.handle(_at(f"{origin}/runlight/oauth/register", "POST", {"content-type": "application/json"}, evil)).status == 400
    registered = _register(routes, "Claude", "https://claude.ai/api/mcp/auth_callback")
    assert registered.status == 201
    client_id = body(registered)["client_id"]

    # Consent: signed out it says so; signed in it asks; allowing sends a code back.
    verifier = _b64url(secrets.token_bytes(32))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    params = _form(
        {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": "https://claude.ai/api/mcp/auth_callback",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": "xyz",
        }
    )
    assert routes.handle(_at(f"{origin}/runlight/oauth/authorize?{params}")).status == 401
    wrong = SearchParams(params)
    wrong.set("redirect_uri", "https://evil.example/cb")
    assert routes.handle(_at(f"{origin}/runlight/oauth/authorize?{wrong}", "GET", owner)).status == 400, "never sends a code to an address the app did not register"
    consent = routes.handle(_at(f"{origin}/runlight/oauth/authorize?{params}", "GET", owner))
    assert consent.status == 200
    page = consent.text()
    assert re.search(r"Claude</strong> wants to read your Runlight stats", page)
    assert re.search(r"sends you back to <strong>claude\.ai</strong>", page), "the page shows where the answer goes"
    deny = routes.handle(_at(f"{origin}/runlight/oauth/authorize", "POST", {**owner, **form}, f"{params}&decision=deny"))
    assert "error=access_denied&state=xyz" in (deny.headers.get("location") or "")
    forged = routes.handle(_at(f"{origin}/runlight/oauth/authorize", "POST", {**owner, "origin": "https://evil.example", **form}, f"{params}&decision=allow"))
    assert forged.status == 403
    allow = routes.handle(_at(f"{origin}/runlight/oauth/authorize", "POST", {**owner, "origin": origin, **form}, f"{params}&decision=allow&site=b"))
    back = Url(allow.headers.get("location") or "")
    assert back.origin + back.pathname == "https://claude.ai/api/mcp/auth_callback"
    assert back.search_params.get("state") == "xyz"
    code = back.search_params.get("code") or ""

    # The token: PKCE checked, the code good once.
    def exchange(code: str, used: str) -> Response:
        fields = {"grant_type": "authorization_code", "code": code, "client_id": client_id, "redirect_uri": "https://claude.ai/api/mcp/auth_callback", "code_verifier": used}
        return routes.handle(_at(f"{origin}/runlight/oauth/token", "POST", form, _form(fields)))

    assert body(exchange(code, "wrong-verifier"))["error"] == "invalid_grant"
    assert body(exchange(code, verifier))["error"] == "invalid_grant", "a code that failed once is spent"

    # Again, properly this time.
    second = routes.handle(_at(f"{origin}/runlight/oauth/authorize", "POST", {**owner, "origin": origin, **form}, f"{params}&decision=allow&site=b"))
    code2 = Url(second.headers.get("location") or "").search_params.get("code") or ""
    issued = body(exchange(code2, verifier))
    assert issued["token_type"] == "Bearer"
    assert issued["scope"] == "read"
    assert issued["site"] == "b"

    message = _js.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "list_sites", "arguments": {}}})
    call = routes.handle(_at(f"{origin}/runlight/mcp", "POST", {"authorization": f"Bearer {issued['access_token']}", "content-type": "application/json"}, message))
    sites = _js.loads(body(call)["result"]["content"][0]["text"])["sites"]
    assert [s["id"] for s in sites] == ["b"], "the token reads only the site chosen at consent"
    tokens = body(routes.handle(_at(f"{origin}/runlight/api/tokens", "GET", owner)))
    assert [[t["name"], t["site"]] for t in tokens["tokens"]] == [["Claude (OAuth)", "b"]]


def test_registering_stores_nothing_so_a_flood_of_registrations_never_keeps_a_real_app_out() -> None:
    now = [calendar.timegm((2026, 10, 7, 12, 0, 0)) * 1000]
    rl = runlight({"sites": [{"id": "a", "name": "Site A", "hostnames": ["a.com"]}], "now": lambda: now[0]})
    routes = rl.routes({"token": "secret"})
    owner = {"authorization": "Bearer secret"}

    def register(name: str, ip: str = "", redirect: str = "https://app.example/cb") -> Response:
        return _register(routes, name, redirect, {"ip": ip})

    for i in range(500):
        assert register(f"flood {i}").status == 201
    assert len(rl.store.settings_starting_with("oauth-client:")) == 0
    assert len(rl.store.settings_starting_with("oauth-used:")) == 0

    # A real app still registers, and its id names it and its address, signed, so nobody can change them.
    claude = register("Claude", "", "https://claude.ai/cb")
    assert claude.status == 201
    client_id = body(claude)["client_id"]
    verifier = _b64url(secrets.token_bytes(32))
    fields = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": "https://claude.ai/cb",
        "code_challenge": _b64url(hashlib.sha256(verifier.encode()).digest()),
        "code_challenge_method": "S256",
    }
    params = _form(fields)
    assert re.search(r"Claude</strong> wants to read", routes.handle(_at(f"https://x.com/runlight/oauth/authorize?{params}", "GET", owner)).text())
    payload, signature = client_id.split(".")
    forged = _b64url(_js.dumps({"n": "Claude", "r": ["https://evil.example/cb"], "t": now[0]}).encode()) + f".{signature}"
    assert forged.split(".")[0] != payload
    forged_params = _form({**fields, "client_id": forged, "redirect_uri": "https://evil.example/cb"})
    assert routes.handle(_at(f"https://x.com/runlight/oauth/authorize?{forged_params}", "GET", owner)).status == 400

    # Allowed and swapped for a token, the app gets its first row.
    allow = routes.handle(
        _at("https://x.com/runlight/oauth/authorize", "POST", {**owner, "origin": "https://x.com", "content-type": "application/x-www-form-urlencoded"}, f"{params}&decision=allow")
    )
    code = Url(allow.headers.get("location") or "").search_params.get("code") or ""
    token_fields = {"grant_type": "authorization_code", "code": code, "client_id": client_id, "redirect_uri": "https://claude.ai/cb", "code_verifier": verifier}
    issued = routes.handle(_at("https://x.com/runlight/oauth/token", "POST", {"content-type": "application/x-www-form-urlencoded"}, _form(token_fields)))
    assert issued.status == 200
    assert len(rl.store.settings_starting_with("oauth-used:")) == 1

    # An app stored before ids were signed still works, and one that never connected goes after a day.
    rl.store.set_setting("oauth-client:" + "a" * 32, _js.dumps({"name": "Old", "redirects": ["https://old.example/cb"], "createdAt": now[0]}))
    old = _form({**fields, "client_id": "a" * 32, "redirect_uri": "https://old.example/cb"})
    assert routes.handle(_at(f"https://x.com/runlight/oauth/authorize?{old}", "GET", owner)).status == 200
    now[0] += 86_400_000
    register("Another")
    assert len(rl.store.settings_starting_with("oauth-client:")) == 0

    # One address registers at most ten a minute.
    for i in range(10):
        assert register(f"app {i}", "203.0.113.9").status == 201
    assert register("one more", "203.0.113.9").status == 429
    assert register("one more", "203.0.113.10").status == 201


def test_before_an_owner_has_allowed_an_app_once_a_request_it_got_wrong_ends_on_a_page() -> None:
    rl = runlight({"sites": [{"id": "a", "name": "Site A", "hostnames": ["a.com"]}]})
    routes = rl.routes({"signIn": "/login", "authorize": lambda r: False})
    client_id = body(_register(routes, "x", "https://evil.example/landing"))["client_id"]
    for asked in ({"response_type": "token"}, {"response_type": "code", "code_challenge_method": "plain", "code_challenge": "a" * 43}):
        query = _form({"client_id": client_id, "redirect_uri": "https://evil.example/landing", "state": "x", **asked})
        answer = routes.handle(_at(f"https://x.com/runlight/oauth/authorize?{query}"))
        assert answer.status == 400
        assert answer.headers.get("location") is None


def test_a_signed_in_viewer_is_told_only_an_owner_can_connect_never_sent_to_sign_in_again() -> None:
    rl = runlight({"sites": [{"id": "a", "name": "Site A", "hostnames": ["a.com"]}]})
    routes = rl.routes({"signIn": "/login", "authorize": lambda r: "read" if r.headers.get("cookie") == "viewer" else False})
    client_id = body(_register(routes, "Claude", "https://claude.ai/cb"))["client_id"]
    params = _form({"response_type": "code", "client_id": client_id, "redirect_uri": "https://claude.ai/cb", "code_challenge": "a" * 43, "code_challenge_method": "S256"})
    signed_out = routes.handle(_at(f"https://x.com/runlight/oauth/authorize?{params}"))
    assert signed_out.status == 303
    assert (signed_out.headers.get("location") or "").startswith("/login?next=%2Frunlight%2Foauth%2Fauthorize%3Fresponse_type%3Dcode")
    viewer = routes.handle(_at(f"https://x.com/runlight/oauth/authorize?{params}", "GET", {"cookie": "viewer"}))
    assert viewer.status == 403
    assert "only an owner of this Runlight can connect Claude" in viewer.text()


def test_a_manage_grant_names_one_site_and_records_the_hubs_origin() -> None:
    from runlight.oauth import s256

    rl = runlight({"sites": [{"id": "a", "name": "Site A", "hostnames": ["a.com"]}, {"id": "b", "name": "Site B", "hostnames": ["b.com"]}]})
    routes = rl.routes({"token": "secret"})
    owner = {"authorization": "Bearer secret"}
    client_id = body(_register(routes, "Hub", "https://hub.example.net/cb"))["client_id"]
    verifier = _b64url(secrets.token_bytes(32))
    params = _form(
        {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": "https://hub.example.net/cb",
            "code_challenge": s256(verifier),
            "code_challenge_method": "S256",
            "scope": "read manage",
            "site": "b",
        }
    )
    page = routes.handle(_at(f"https://x.com/runlight/oauth/authorize?{params}", "GET", owner)).text()
    assert '<option value="b" selected>Site B</option>' in page, "the site asked for is offered first"
    assert "Every site" not in page
    form = {**owner, "origin": "https://x.com", "content-type": "application/x-www-form-urlencoded"}
    no_site = routes.handle(_at("https://x.com/runlight/oauth/authorize", "POST", form, params.replace("site=b", "site=") + "&decision=allow"))
    assert no_site.headers.get("location") == "https://hub.example.net/cb?error=invalid_request&error_description=Pick+the+site+to+manage"
    allow = routes.handle(_at("https://x.com/runlight/oauth/authorize", "POST", form, params.replace("site=b", "site=a") + "&decision=allow"))
    code = Url(allow.headers.get("location") or "").search_params.get("code")
    given = _js.dumps({"grant_type": "authorization_code", "code": code, "client_id": client_id, "redirect_uri": "https://hub.example.net/cb", "code_verifier": verifier})
    issued = body(routes.handle(_at("https://x.com/runlight/oauth/token", "POST", {"content-type": "application/json"}, given)))
    assert [issued["scope"], issued["site"]] == ["manage", "a"]
    tokens = body(routes.handle(_at("https://x.com/runlight/api/tokens", "GET", owner)))["tokens"]
    assert rl.store.setting(f"token-origin:{tokens[0]['id']}") == "https://hub.example.net"
