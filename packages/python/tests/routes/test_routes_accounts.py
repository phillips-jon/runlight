"""accounts.test.ts's route-level tests: an app with routes({"accounts": True}), on every database at hand (PHP
tests/Accounts/RoutesAccountsTest.php)."""

from __future__ import annotations

import os
import re
from typing import Any

import pytest

from runlight import Runlight, _js
from runlight.http import Request, Response, SearchParams, Url
from runlight.store import Stores
from support.databases import kinds


def req(path: str, method: str = "GET", headers: dict[str, str] | None = None, body: str = "") -> Request:
    return Request(f"https://example.com{path}", method, headers or {}, body)


def form(path: str, fields: dict[str, str], cookie: str = "") -> Request:
    headers = {"content-type": "application/x-www-form-urlencoded", **({"cookie": cookie} if cookie else {})}
    return req(path, "POST", headers, SearchParams(fields).to_string())


def cookie_of(response: Response) -> str:
    return (response.headers.get("set-cookie") or "").split(";")[0]


def fresh(databases: Any, kind: str) -> Any:
    return Stores.from_db(databases.db(kind))


@pytest.mark.parametrize("kind", kinds())
def test_an_app_with_accounts_on_makes_its_first_account_with_its_token_then_invites_people_by_role(databases, kind):
    rl = Runlight({"store": fresh(databases, kind), "secret": "k" * 64})
    routes = rl.routes({"token": "app-token", "accounts": True})
    handler = routes.handle

    def json(cookie: str, method: str, path: str, body: Any = None) -> Response:
        payload = "" if body is None else _js.dumps(body)
        return handler(req(f"/runlight{path}", method, {"cookie": cookie, "content-type": "application/json"}, payload))

    # Nobody yet: the dashboard sends you to set up, which asks for the app's token.
    start = handler(req("/runlight/"))
    assert start.status == 303
    assert start.headers.get("location") == "/runlight/setup"
    page = handler(req("/runlight/setup")).text()
    assert re.search("RUNLIGHT_TOKEN", page)
    assert re.search(r'action="/runlight/setup"', page)
    assert re.search(r'href="/runlight/auth\.css"', page)
    wrong = handler(form("/runlight/setup", {"code": "guess", "email": "jon@example.com", "password": "a long password", "again": "a long password"}))
    assert wrong.status == 403
    made = handler(form("/runlight/setup", {"code": "app-token", "email": "jon@example.com", "password": "a long password", "again": "a long password"}))
    assert made.status == 303
    assert made.headers.get("location") == "/runlight/"
    assert re.search("Path=/runlight;", made.headers.get("set-cookie") or ""), "the session is for Runlight's paths only"
    owner = cookie_of(made)
    assert handler(req("/runlight/setup")).headers.get("location") == "/runlight/login", "setup closes once there is an account"

    # Signed in, the dashboard and its API answer; signed out, they do not.
    assert handler(req("/runlight/", "GET", {"cookie": owner})).status == 200
    assert re.search('data-accounts=""', handler(req("/runlight/", "GET", {"cookie": owner})).text())
    assert handler(req("/runlight/api/sites")).status == 401
    assert handler(req("/runlight/api/sites", "GET", {"cookie": owner})).status == 200
    assert handler(req("/runlight/api/sites", "GET", {"authorization": "Bearer app-token"})).status == 200, "a script's token still works"
    assert _js.loads(json(owner, "GET", "/api/account").text())["account"]["role"] == "owner"

    # The owner invites a member, who joins with their own password.
    sent = _js.loads(json(owner, "POST", "/api/people", {"email": "mo@example.com", "role": "member"}).text())
    assert sent["emailed"] is False, "no mail service here, so the link is for passing on"
    link = Url(sent["link"])
    assert link.pathname == "/runlight/invite"
    assert re.search("as a member", handler(req(link.pathname + link.search)).text())
    joined = handler(form("/runlight/invite", {"code": link.search_params.get("code") or "", "password": "another long one", "again": "another long one"}))
    assert joined.status == 303
    member = cookie_of(joined)

    # A member changes a site's settings, but not people, the mail service, or the assistant's settings.
    assert json(member, "POST", "/api/goals", {"name": "Signup", "kind": "page", "match": "/thanks"}).status == 201
    assert json(member, "GET", "/api/people").status == 403
    assert _js.loads(json(member, "PUT", "/api/mail", {}).text())["code"] == "admin_only"
    assert json(member, "PUT", "/api/assistant", {}).status == 403

    # Signing out ends the session; signing in again with the password starts one.
    out = handler(req("/runlight/logout"))
    assert out.headers.get("location") == "/runlight/login"
    assert handler(req("/runlight/")).headers.get("location") == "/runlight/login"
    back = handler(form("/runlight/login", {"email": "mo@example.com", "password": "another long one", "next": "/runlight/?period=7d"}))
    assert back.status == 303
    assert back.headers.get("location") == "/runlight/?period=7d"
    elsewhere = handler(form("/runlight/login", {"email": "mo@example.com", "password": "another long one", "next": "//evil.example/"}))
    assert elsewhere.headers.get("location") == "/runlight/", "never sent off the app"


def test_in_development_or_left_open_the_first_account_needs_no_proof_in_production_without_a_token_setup_stays_shut(databases):
    signup = {"code": "", "email": "jon@example.com", "password": "a long password", "again": "a long password"}
    os.environ["NODE_ENV"] = "development"
    dev = Runlight({"store": fresh(databases, "sqlite")}).routes({"accounts": True})
    assert not re.search("RUNLIGHT_TOKEN", dev.handle(req("/runlight/setup")).text())
    assert dev.handle(form("/runlight/setup", signup)).status == 303

    os.environ["NODE_ENV"] = "production"
    opened = Runlight({"store": fresh(databases, "sqlite")}).routes({"token": None, "accounts": True})
    assert opened.handle(req("/runlight/setup")).status == 200, "token: None leaves setup open, as it leaves everything"
    prod = Runlight({"store": fresh(databases, "sqlite"), "secret": "k" * 64}).routes({"accounts": True})
    shut = prod.handle(req("/runlight/setup"))
    assert shut.status == 403
    assert re.search("Set RUNLIGHT_TOKEN", shut.text())
    assert prod.handle(form("/runlight/setup", signup)).status == 403
