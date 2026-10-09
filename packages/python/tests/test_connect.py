"""Connecting an install through its consent page, as hub.test.ts tests it, with the install played by a router
(PHP tests/Core/ConnectTest.php)."""

from __future__ import annotations

import base64
import hashlib
import re
from collections.abc import Callable
from typing import Any

import pytest

from runlight import Runlight, _js
from runlight.connect import ConnectError, finish_connect, install_url, start_connect
from runlight.http import FetchError, Response, SearchParams, Url
from runlight.store import Stores

APP = "http://127.0.0.1:4100/runlight"


class Router:
    """A Fetcher that answers from a table of URL patterns, recording what was asked, as the TS tests' serve()
    replaces globalThis.fetch. Each answer is a body to send as JSON, or (status, body)."""

    def __init__(self, routes: list[tuple[str, Callable[[], Any]]]) -> None:
        self.routes = routes
        self.requests: list[dict[str, Any]] = []

    def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
        init = init or {}
        self.requests.append({"url": url, "init": init})
        for pattern, answer in self.routes:
            if re.search(pattern, Url(url).href):
                result = answer()
                status, body = result if isinstance(result, tuple) else (200, result)
                return Response(_js.dumps(body), status, {"content-type": "application/json"})
        return Response("{}", 404)


def install(meta: dict[str, Any] | None = None, registered: dict[str, Any] | None = None, register_status: int = 201) -> Router:
    """An install that speaks OAuth, as an app's Runlight does."""
    meta = meta or {
        "authorization_endpoint": "http://127.0.0.1:4100/runlight/oauth/authorize",
        "token_endpoint": "http://127.0.0.1:4100/runlight/oauth/token",
        "registration_endpoint": "http://127.0.0.1:4100/runlight/oauth/register",
        "scopes_supported": ["read", "manage"],
    }
    registered = {"client_id": "c1"} if registered is None else registered
    sites = [
        {"id": "shop", "name": "Shop", "timezone": "UTC", "hostnames": ["shop.example.com"]},
        {"id": "blog", "name": "Blog", "timezone": "Asia/Tokyo", "hostnames": ["blog.example.com"]},
    ]
    return Router([
        (r"/\.well-known/oauth-authorization-server\Z", lambda: meta),
        (r"/oauth/register\Z", lambda: (register_status, registered)),
        (r"/oauth/token\Z", lambda: {"access_token": "rl_manage", "site": "blog"}),
        (r"/api/sites\Z", lambda: {"sites": sites}),
        (r"/api/token\Z", lambda: {"scope": "manage", "site": "blog"}),
    ])  # fmt: skip


class Clock:
    def __init__(self) -> None:
        self.now = 1_791_288_000_000

    def hub(self, fetcher: Any) -> Runlight:
        return Runlight({"store": Stores.sqlite(":memory:"), "managedSites": True, "secret": "k" * 32, "fetcher": fetcher, "now": lambda: self.now})


@pytest.fixture
def clock() -> Clock:
    return Clock()


def refused(fn: Callable[[], Any], code: str) -> ConnectError:
    with pytest.raises(ConnectError) as caught:
        fn()
    assert caught.value.code == code
    return caught.value


def test_a_hub_connects_an_app_through_its_consent_page_for_the_one_site_the_owner_picked(clock):
    router = install()
    hub = clock.hub(router)
    hub.init()
    back = "http://localhost:4900/runlight/api/sites/connect/done"
    consent = Url(start_connect(hub, f"{APP}/", back))
    assert consent.origin + consent.pathname == "http://127.0.0.1:4100/runlight/oauth/authorize"
    q = consent.search_params
    assert [q.get("response_type"), q.get("client_id"), q.get("redirect_uri"), q.get("code_challenge_method"), q.get("scope")] == [
        "code", "c1", back, "S256", "manage",
    ]  # fmt: skip
    assert re.fullmatch(r"[a-f0-9]{32}", q.get("state") or "")
    assert q.get("site") is None
    assert _js.loads(router.requests[1]["init"]["body"]) == {"client_name": "Runlight at localhost:4900", "redirect_uris": [back]}

    pending = _js.loads(hub.store.setting(f"connect:{q.get('state')}"))
    hashed = base64.urlsafe_b64encode(hashlib.sha256(pending["verifier"].encode()).digest()).decode().rstrip("=")
    assert q.get("code_challenge") == hashed, "the challenge is the verifier hashed"
    assert pending["expires"] == clock.now + 15 * 60_000

    id_ = finish_connect(hub, SearchParams({"state": q.get("state") or "", "code": "the-code"}))
    assert id_ == "blog.example.com"
    assert hub.remote(id_) == {"url": APP, "token": "rl_manage", "site": "blog", "hostnames": ["blog.example.com"], "scope": "manage"}
    assert hub.site(id_) == {"id": "blog.example.com", "name": "Blog", "hostnames": [], "timezone": "Asia/Tokyo"}
    exchange = next(r for r in router.requests if r["url"].endswith("/oauth/token"))
    form = SearchParams(exchange["init"]["body"])
    assert [form.get("grant_type"), form.get("code"), form.get("client_id"), form.get("redirect_uri"), form.get("code_verifier")] == [
        "authorization_code", "the-code", "c1", back, pending["verifier"],
    ]  # fmt: skip

    # A code works once.
    refused(lambda: finish_connect(hub, SearchParams({"state": q.get("state") or "", "code": "the-code"})), "expired")


def test_what_went_wrong_comes_back_as_a_code(clock):
    hub = clock.hub(install())
    hub.init()

    def start(site: str = "") -> SearchParams:
        return Url(start_connect(hub, APP, "https://hub.example/done", site)).search_params

    assert start("blog").get("site") == "blog", "which of its sites to offer first"
    denied = start()
    refused(lambda: finish_connect(hub, SearchParams({"state": denied.get("state") or "", "error": "access_denied"})), "denied")
    other = start()
    error = refused(
        lambda: finish_connect(hub, SearchParams({"state": other.get("state") or "", "error": "server_error", "error_description": "Sign in again"})),
        "refused",
    )
    assert str(error) == "Sign in again"
    refused(lambda: finish_connect(hub, SearchParams({"state": "not-a-state"})), "expired")
    # An attempt nobody came back from in time.
    late = start()
    clock.now += 16 * 60_000
    refused(lambda: finish_connect(hub, SearchParams({"state": late.get("state") or ""})), "expired")
    # Starting again clears the ones that ran out.
    start()
    assert len(hub.store.settings_starting_with("connect:")) == 1


def test_a_hub_only_follows_an_installs_own_endpoints_when_connecting(clock):
    hostile = install({
        "authorization_endpoint": "http://127.0.0.1:1/authorize",
        "token_endpoint": "http://169.254.169.254/token",
        "registration_endpoint": "http://169.254.169.254/register",
        "scopes_supported": ["read", "manage"],
    })  # fmt: skip
    hub = clock.hub(hostile)
    error = refused(lambda: start_connect(hub, "http://127.0.0.1:4100", "https://hub.example/done"), "endpoints")
    assert re.search("named endpoints on another address", str(error))
    assert len(hostile.requests) == 1, "nothing else was asked"


def test_an_install_that_cannot_connect_says_why(clock):
    refused(lambda: start_connect(clock.hub(install()), "ftp://x", "https://hub.example/done"), "url")
    refused(lambda: start_connect(clock.hub(Router([])), APP, "https://hub.example/done"), "not_runlight")
    old = install({
        "authorization_endpoint": f"{APP}/oauth/authorize",
        "token_endpoint": f"{APP}/oauth/token",
        "registration_endpoint": f"{APP}/oauth/register",
        "scopes_supported": ["read"],
    })  # fmt: skip
    refused(lambda: start_connect(clock.hub(old), APP, "https://hub.example/done"), "old")
    error = refused(
        lambda: start_connect(clock.hub(install(None, {"error_description": "redirect_uris must use https"}, 400)), APP, "http://hub.example/done"),
        "register",
    )
    assert error.params == {"url": APP, "reason": "redirect_uris must use https."}
    error = refused(lambda: start_connect(clock.hub(install(None, {"nope": True}, 400)), APP, "http://hub.example/done"), "register")
    assert error.params["reason"] == "This server's address must use https."

    class Down:
        def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
            raise FetchError("refused")

    hub = Runlight({"store": Stores.sqlite(":memory:"), "fetcher": Down()})
    error = refused(lambda: start_connect(hub, APP, "https://hub.example/done"), "unreachable")
    assert error.params == {"host": "127.0.0.1:4100"}


def test_install_addresses():
    assert install_url("  https://example.com/runlight/// ") == "https://example.com/runlight"
    assert install_url("http://localhost:3000") == "http://localhost:3000"
    for bad in ["http://example.com", "http://localhost.evil.com", None, "", "example.com"]:
        refused(lambda bad=bad: install_url(bad), "url")
    assert isinstance(ConnectError("x", "url"), _js.RangeError), "a RangeError in TypeScript"


def test_an_address_the_url_parser_refuses_is_the_address_error():
    for url in ["https://[", "https://[::1", "https://a b"]:
        refused(lambda url=url: install_url(url), "url")
    assert install_url("https://example.com/runlight/") == "https://example.com/runlight"


def test_an_attempt_saved_without_an_expiry_has_expired(clock):
    router = Router([])
    hub = clock.hub(router)
    hub.init()
    state = "a" * 32
    attempt = {"url": APP, "client": "c", "verifier": "v", "redirect": "https://hub.example/done", "token": f"{APP}/oauth/token"}
    for stored in [attempt, None, 5, {"expires": "9999999999999"}]:
        hub.store.set_setting(f"connect:{state}", _js.dumps(stored))
        refused(lambda: finish_connect(hub, SearchParams({"state": state, "code": "c"})), "expired")
    assert router.requests == [], "nothing was fetched"
    # Starting clears every attempt that cannot be read or has no expiry.
    fresh = clock.hub(install())
    fresh.init()
    for letter, value in {"b": "null", "c": "5", "d": "not json", "e": '{"url":"x"}'}.items():
        fresh.store.set_setting(f"connect:{letter * 32}", value)
    start_connect(fresh, APP, "https://hub.example/done")
    assert len(fresh.store.settings_starting_with("connect:")) == 1
