"""Accounts on the web, through AccountsWeb.handle() as the routes call it, with a stand-in for the Runlight (PHP
tests/Accounts/WebTest.php), on every database at hand. The cases follow accounts.test.ts and the accounts
conformance scenario."""

from __future__ import annotations

import html
import re
import time
from typing import Any

import pytest

from runlight import _js
from runlight.accounts import SESSION_COOKIE, accounts_web, setup_code
from runlight.accounts.auth import Throttle, otpauth_uri, totp
from runlight.accounts.pages import AUTH_CSS, code_page, login_page, setup_locked_page, setup_page
from runlight.accounts.web import AccountsWeb
from runlight.http import Request, Response, SearchParams, Url
from runlight.mail import MailError
from runlight.store import SqlStore, Stores
from support.databases import kinds

NOW = 1_791_288_000_000
BASE = "/runlight"
FORGOT = "https://runlight.sh/docs/configuration/#accounts"


class StandIn:
    """The little of a Runlight that accounts on the web reach for: its store, its mail, and the client's address.
    Mail is kept in a list instead of sent; `mail_fails` makes sending raise."""

    def __init__(self, store: SqlStore) -> None:
        self.store = store
        self.sent: list[dict[str, Any]] = []
        self.mail: dict[str, Any] | None = None
        self.mail_fails: Exception | None = None

    def mail_settings(self) -> dict[str, Any] | None:
        return self.mail

    def send_mail(self, message: dict[str, Any]) -> None:
        if self.mail_fails is not None:
            raise self.mail_fails
        self.sent.append(message)

    def client_ip(self, request: Request, context: dict[str, Any] | None = None) -> str:
        """The last X-Forwarded-For entry, else the connection's address, as Runlight reads it by default."""
        header = request.headers.get("x-forwarded-for")
        if header and header.strip():
            parts = [p.strip() for p in header.split(",") if p.strip()]
            return parts[-1]
        return (context or {}).get("ip", "")


class Harness:
    def __init__(self, databases: Any, kind: str) -> None:
        self.now = NOW
        self.rl: StandIn | None = None
        self.databases = databases
        self.kind = kind

    def web(self, first: Any = None, home: str | None = None) -> AccountsWeb:
        store = Stores.from_db(self.databases.db(self.kind))
        store.migrate()
        self.rl = StandIn(store)
        options: dict[str, Any] = {
            "runlight": self.rl,
            "secret": "k" * 64,
            "base": BASE,
            "now": lambda: self.now,
            "firstAccount": {"token": "app-token"} if first is None else first,
            "forgot": FORGOT,
        }
        if home is not None:
            options["home"] = lambda: home
        return accounts_web(options)


@pytest.fixture(params=kinds())
def h(request, databases) -> Harness:
    """A harness on each database at hand; each web() it makes gets a fresh one."""
    return Harness(databases, request.param)


def req(path: str, method: str = "GET", headers: dict[str, str] | None = None, body: str = "") -> Request:
    return Request(f"https://example.com/runlight{path}", method, headers or {}, body)


def form(path: str, fields: dict[str, str], cookie: str = "") -> Request:
    headers = {"content-type": "application/x-www-form-urlencoded", **({"cookie": cookie} if cookie else {})}
    return req(path, "POST", headers, SearchParams(fields).to_string())


def json_req(cookie: str, method: str, path: str, body: Any = None) -> Request:
    return req(path, method, {"cookie": cookie, "content-type": "application/json"}, "" if body is None else _js.dumps(body))


def handle(web: AccountsWeb, request: Request) -> Response | None:
    return web.handle(request, Url(request.url).pathname[len(BASE) :] or "/")


def cookie_of(response: Response) -> str:
    cookies = response.headers.get_set_cookie()
    return (cookies[0] if cookies else "").split(";")[0]


def owner(web: AccountsWeb) -> str:
    made = handle(web, form("/setup", {"code": "app-token", "email": "jon@example.com", "password": "a long password", "again": "a long password"}))
    return cookie_of(made)


def test_an_app_makes_its_first_account_with_its_token(h):
    web = h.web()
    start = handle(web, req("/"))
    assert start.status == 303
    assert start.headers.get("location") == "/runlight/setup"
    assert start.headers.get("cache-control") == "no-store"
    page = handle(web, req("/setup"))
    assert page.text() == setup_page(BASE, {"code": "", "askCode": True})
    assert page.headers.get("content-security-policy") == (
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    )
    assert re.search(r'href="/runlight/auth\.css"', page.text())

    wrong = handle(web, form("/setup", {"code": "guess", "email": "jon@example.com", "password": "a long password", "again": "a long password"}))
    assert wrong.status == 403
    assert wrong.text() == setup_page(BASE, {"code": "", "askCode": True, "error": "That is not this app's RUNLIGHT_TOKEN.", "email": "jon@example.com"})
    typo = handle(web, form("/setup", {"code": "app-token", "email": "jon@example.com", "password": "a long password", "again": "a long passwore"}))
    assert typo.status == 400
    assert "The two passwords are not the same." in typo.text()
    short = handle(web, form("/setup", {"code": "app-token", "email": "jon@example.com", "password": "short", "again": "short"}))
    assert short.status == 400
    assert "Use a password of at least 10 characters" in short.text()

    made = handle(web, form("/setup", {"code": "app-token", "email": "jon@example.com", "password": "a long password", "again": "a long password"}))
    assert made.status == 303
    assert made.headers.get("location") == "/runlight/"
    cookies = made.headers.get_set_cookie()
    assert len(cookies) == 1
    assert re.fullmatch(r"runlight_session=[a-f0-9]{24}\.\d+\.[A-Za-z0-9_-]{43}; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=2592000; Secure", cookies[0])
    assert handle(web, req("/setup")).headers.get("location") == "/runlight/login", "setup closes once there is an account"

    signed = cookie_of(made)
    assert handle(web, req("/", "GET", {"cookie": signed})) is None, "signed in, the dashboard is the routes' to answer"
    assert web.access(req("/", "GET", {"cookie": signed})) is True
    assert web.access(req("/")) is False
    answer = handle(web, json_req(signed, "GET", "/api/account"))
    user = web.accounts.by_email("jon@example.com")
    assert answer.text() == _js.dumps({"account": {"id": user["id"], "email": "jon@example.com", "role": "owner", "createdAt": NOW, "twoFactor": False, "recoveryLeft": 0}})
    assert answer.headers.get("content-type") == "application/json; charset=utf-8"
    assert web.account_of(req("/", "GET", {"cookie": signed})) == user["id"]

    # Signed out, the dashboard sends you to sign in, and keeps where you were going.
    assert handle(web, req("/?period=7d")).headers.get("location") == "/runlight/login?next=%2Frunlight%2F%3Fperiod%3D7d"
    assert handle(web, req("/")).headers.get("location") == "/runlight/login"


def test_a_server_code_open_and_locked_setups(h):
    code = setup_code()
    assert re.fullmatch(r"[A-Za-z0-9_-]{12}", code)
    web = h.web({"code": code})
    assert handle(web, req("/")).status == 403, "a server with no account and no code in the link stays shut"
    assert handle(web, req("/setup?code=nope")).text() == setup_locked_page(BASE)
    assert handle(web, req(f"/setup?code={code}")).text() == setup_page(BASE, {"code": code})
    assert handle(web, req("/login")).status == 403
    assert handle(web, form("/setup", {"code": "nope", "email": "jon@example.com", "password": "a long password", "again": "a long password"})).status == 403

    opened = h.web("open")
    assert handle(opened, req("/")).headers.get("location") == "/runlight/setup"
    assert handle(opened, req("/login")).headers.get("location") == "/runlight/setup"
    assert "RUNLIGHT_TOKEN" not in handle(opened, req("/setup")).text()
    assert handle(opened, form("/setup", {"code": "", "email": "jon@example.com", "password": "a long password", "again": "a long password"})).status == 303

    locked = h.web("locked")
    shut = handle(locked, req("/setup"))
    assert shut.status == 403
    assert "Set RUNLIGHT_TOKEN" in shut.text()
    assert handle(locked, form("/setup", {"code": "", "email": "jon@example.com", "password": "a long password", "again": "a long password"})).status == 403

    css = handle(locked, req("/auth.css"))
    assert css.text() == AUTH_CSS
    assert css.headers.get("content-type") == "text/css; charset=utf-8"
    assert css.headers.get("cache-control") == "public, max-age=3600"
    assert handle(locked, req("/auth.js")).headers.get("content-type") == "application/javascript; charset=utf-8"
    assert handle(locked, req("/somewhere")) is None


def test_a_setup_link_can_say_where_it_is():
    store = Stores.sqlite(":memory:")
    store.migrate()
    where = "in the file setup.txt"
    web = accounts_web({
        "runlight": StandIn(store), "secret": "k" * 64, "base": "", "now": lambda: NOW, "firstAccount": {"code": "abc"},
        "forgot": FORGOT, "setupWhere": where,
    })  # fmt: skip
    assert web.handle(Request("https://example.com/setup"), "/setup").text() == setup_locked_page("", where)


def test_signing_in_and_out_never_leaves_the_app(h):
    web = h.web()
    owner(web)
    login = handle(web, req("/login?next=%2Frunlight%2F%3Fsite%3Dx"))
    assert login.text() == login_page(BASE, {"next": "/runlight/?site=x", "forgot": FORGOT})

    wrong = handle(web, form("/login", {"email": "jon@example.com", "password": "a wrong password"}))
    assert wrong.status == 401
    assert wrong.text() == login_page(BASE, {"error": "That email and password do not match an account.", "email": "jon@example.com", "next": "/runlight/", "forgot": FORGOT})

    back = handle(web, form("/login", {"email": "JON@example.com", "password": "a long password", "next": "/runlight/?period=7d"}))
    assert back.status == 303
    assert back.headers.get("location") == "/runlight/?period=7d"
    cookies = back.headers.get_set_cookie()
    assert len(cookies) == 2, "a session, and the mark that this browser signed in to the account"
    assert re.fullmatch(r"runlight_device=[a-f0-9]{24}\.[A-Za-z0-9_-]{43}; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=31536000; Secure", cookies[1])

    out = handle(web, req("/logout"))
    assert out.headers.get("location") == "/runlight/login"
    assert out.headers.get_set_cookie() == ["runlight_session=; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=0; Secure"]

    for nxt in ["//evil.example/", "/\\evil.example", "/\t/evil.example", "https://evil.example/", "", "runlight"]:
        assert web.safe_next(nxt) == "/runlight/", f"never sent off the app: {nxt}"
    assert web.safe_next(None) == "/runlight/"
    assert web.safe_next("/runlight/a/../x?y=1#z") == "/runlight/x?y=1#z"
    assert web.safe_next("/ a") == "/%20a"


def test_invites_people_and_roles(h):
    web = h.web()
    signed = owner(web)
    sent = handle(web, json_req(signed, "POST", "/api/people", {"email": "Mo@Example.com", "role": "member"}))
    assert sent.status == 201
    body = _js.loads(sent.text())
    assert list(body) == ["invite", "link", "emailed"]
    assert body["emailed"] is False, "no mail service here, so the link is for passing on"
    link = Url(body["link"])
    assert link.origin == "https://example.com"
    assert link.pathname == "/runlight/invite"
    code = link.search_params.get("code") or ""
    assert "as a member" in handle(web, req(f"/invite?code={code}")).text()
    assert handle(web, req("/invite?code=nope")).status == 410

    assert handle(web, json_req(signed, "POST", "/api/people", {"email": "jon@example.com", "role": "admin"})).status == 409
    no_role = handle(web, json_req(signed, "POST", "/api/people", {"email": "x@example.com", "role": "owner"}))
    assert no_role.text() == '{"error":"Pick admin, member, or viewer","code":"role_needed"}'
    assert no_role.headers.get("x-content-type-options") == "nosniff"
    bad_email = handle(web, json_req(signed, "POST", "/api/people", {"email": "nobody", "role": "admin"}))
    assert bad_email.text() == '{"error":"Enter an email address","code":"email_invalid","params":{}}'
    plain = handle(web, req("/api/people", "POST", {"cookie": signed, "content-type": "text/plain"}, "{}"))
    assert plain.status == 415, "a write must be JSON"
    assert handle(web, req("/api/people")).text() == '{"error":"Sign in first","code":"sign_in"}'

    typo = handle(web, form("/invite", {"code": code, "password": "another long one", "again": "another long two"}))
    assert typo.status == 400
    joined = handle(web, form("/invite", {"code": code, "password": "another long one", "again": "another long one"}))
    assert joined.status == 303
    assert joined.headers.get("location") == "/runlight/"
    member = cookie_of(joined)
    assert web.access(req("/", "GET", {"cookie": member})) == "member"
    assert handle(web, json_req(member, "GET", "/api/people")).status == 403
    assert handle(web, form("/invite", {"code": code, "password": "another long one", "again": "another long one"})).status == 410, "an invite works once"

    # A member's tokens go when they become a viewer.
    mo = web.accounts.by_email("mo@example.com")
    token = {"id": "b" * 24, "name": "Script", "site": "", "scope": "read", "hash": "c" * 64, "hint": "abcd", "createdAt": NOW, "lastUsedAt": None}
    h.rl.store.insert_token(token)
    assert web.token_made(token, mo["id"]) is True
    assert web.token_made(token, "d" * 24) is False, "nobody by that id makes tokens"
    changed = handle(web, json_req(signed, "PATCH", f"/api/people/{mo['id']}", {"role": "viewer"}))
    assert changed.text() == _js.dumps({"person": {"id": mo["id"], "email": "mo@example.com", "role": "viewer", "createdAt": NOW, "twoFactor": False, "recoveryLeft": 0}})
    assert h.rl.store.tokens() == []
    assert web.access(req("/", "GET", {"cookie": member})) == "read"
    assert web.token_made(token, mo["id"]) is False, "a viewer makes no tokens"

    jon = web.accounts.by_email("jon@example.com")
    refused = handle(web, json_req(signed, "PATCH", f"/api/people/{jon['id']}", {"role": "admin"}))
    assert refused.text() == '{"error":"Only the owner can change their own role, by handing ownership to an admin","code":"owner_protected","params":{}}'
    assert refused.status == 403
    assert handle(web, json_req(signed, "PATCH", f"/api/people/{'a' * 24}", {"role": "admin"})).status == 404
    assert _js.loads(handle(web, json_req(signed, "DELETE", f"/api/people/{jon['id']}")).text())["code"] == "remove_self"

    # Invites listed, resent, and cancelled.
    handle(web, json_req(signed, "POST", "/api/people", {"email": "zed@example.com", "role": "viewer"}))
    people = _js.loads(handle(web, json_req(signed, "GET", "/api/people")).text())
    assert sorted(p["email"] for p in people["people"]) == ["jon@example.com", "mo@example.com"]
    assert [i["email"] for i in people["invites"]] == ["zed@example.com"]
    id_ = people["invites"][0]["id"]
    resent = handle(web, json_req(signed, "POST", f"/api/invites/{id_}/resend"))
    assert resent.status == 200
    new_id = _js.loads(resent.text())["invite"]["id"]
    assert new_id != id_
    assert handle(web, json_req(signed, "DELETE", f"/api/invites/{id_}")).status == 404
    assert handle(web, json_req(signed, "DELETE", f"/api/invites/{new_id}")).text() == '{"ok":true}'

    assert handle(web, json_req(signed, "DELETE", f"/api/people/{mo['id']}")).text() == '{"ok":true}'
    assert web.signed_in(req("/", "GET", {"cookie": member})) is None, "someone removed is signed out"


def test_invites_are_emailed_when_there_is_a_mail_service(h):
    web = h.web({"token": "app-token"}, "https://stats.example.com")
    signed = owner(web)
    h.rl.mail = {"service": "smtp", "from": "runlight@example.com"}
    body = _js.loads(handle(web, json_req(signed, "POST", "/api/people", {"email": "mo@example.com", "role": "viewer"})).text())
    assert body["emailed"] is True
    assert body["link"].startswith("https://stats.example.com/runlight/invite?code="), "the install's own address, never the request's Host"
    assert h.rl.sent[0]["subject"] == "jon@example.com invited you to Runlight"
    assert h.rl.sent[0]["text"] == (
        "jon@example.com invited you to the Runlight at stats.example.com as a viewer, who can read every site's stats.\n\n"
        f"Choose a password to join:\n{body['link']}\n\nThe link works for seven days.\n"
    )

    h.rl.mail_fails = MailError("The server refused the password", "mail_auth", {"host": "smtp.example.com"})
    failed = _js.loads(handle(web, json_req(signed, "POST", "/api/people", {"email": "ada@example.com", "role": "admin"})).text())
    assert list(failed) == ["invite", "link", "emailed", "mailError", "mailCode", "mailParams"]
    assert failed["mailCode"] == "mail_auth"
    assert failed["mailParams"] == {"host": "smtp.example.com"}
    h.rl.mail_fails = RuntimeError("Something else")
    other = _js.loads(handle(web, json_req(signed, "POST", "/api/people", {"email": "zed@example.com", "role": "admin"})).text())
    assert list(other) == ["invite", "link", "emailed", "mailError"], "an error without a code of its own has none here"
    assert other["mailError"] == "Something else"


def test_two_factor_through_the_account_api_and_the_code_step(h):
    web = h.web()
    signed = owner(web)
    wrong = handle(web, json_req(signed, "POST", "/api/account/2fa/start", {"password": "a wrong password"}))
    assert wrong.text() == '{"error":"Your password is not right","code":"password_wrong"}'
    start = _js.loads(handle(web, json_req(signed, "POST", "/api/account/2fa/start", {"password": "a long password"})).text())
    assert start["uri"] == otpauth_uri(start["secret"], "jon@example.com", "example.com")
    recovery = handle(web, json_req(signed, "POST", "/api/account/2fa/recovery", {"password": "a long password"}))
    assert recovery.text() == '{"error":"Turn on two-factor sign-in first","code":"twofactor_off"}'

    code = totp(start["secret"], h.now // 30_000)
    confirmed = handle(web, json_req(signed, "POST", "/api/account/2fa/confirm", {"code": f"{code[:3]} {code[3:]}"}))
    assert confirmed.status == 200
    assert len(_js.loads(confirmed.text())["recovery"]) == 10
    assert web.signed_in(req("/", "GET", {"cookie": signed})) is None, "turning it on signs out every other browser"
    signed = cookie_of(confirmed)
    assert web.signed_in(req("/", "GET", {"cookie": signed}))["twoFactor"] is True

    # Signing in now earns only the code step.
    h.now += 60_000
    step = handle(web, form("/login", {"email": "jon@example.com", "password": "a long password", "next": "/runlight/?x=1"}))
    assert step.status == 200
    assert step.headers.get_set_cookie() == []
    found = re.search(r'name="pending" value="([^"]+)"', step.text())
    assert found
    pending = html.unescape(found.group(1))
    bad = handle(web, form("/login/code", {"pending": pending, "code": "12345x", "next": "/runlight/?x=1"}))
    assert bad.status == 401
    assert bad.text() == code_page(BASE, {"pending": pending, "next": "/runlight/?x=1", "error": "That code is not right. Check the time on your phone, or use a recovery code."})
    signed_in = handle(web, form("/login/code", {"pending": pending, "code": totp(start["secret"], h.now // 30_000), "next": "/runlight/?x=1"}))
    assert signed_in.status == 303
    assert signed_in.headers.get("location") == "/runlight/?x=1"
    made_up = handle(web, form("/login/code", {"pending": "made.up.ticket", "code": "123456"}))
    assert made_up.headers.get("location") == "/runlight/login?next=%2Frunlight%2F"

    # Turning it off keeps this browser signed in.
    off = handle(web, json_req(cookie_of(signed_in), "POST", "/api/account/2fa/disable", {"password": "a long password"}))
    assert off.text() == '{"ok":true}'
    assert web.signed_in(req("/", "GET", {"cookie": cookie_of(off)}))["twoFactor"] is False
    assert handle(web, json_req(cookie_of(off), "POST", "/api/account/2fa/other", {"password": "a long password"})).status == 404


def test_confirming_has_five_tries_and_then_starts_again(h):
    web = h.web()
    signed = owner(web)
    start = _js.loads(handle(web, json_req(signed, "POST", "/api/account/2fa/start", {"password": "a long password"})).text())
    right = totp(start["secret"], h.now // 30_000)
    wrong = "111111" if right == "000000" else "000000"
    for _ in range(5):
        assert _js.loads(handle(web, json_req(signed, "POST", "/api/account/2fa/confirm", {"code": wrong})).text())["code"] == "code_wrong"
    restart = handle(web, json_req(signed, "POST", "/api/account/2fa/confirm", {"code": right}))
    assert restart.status == 429
    assert _js.loads(restart.text())["code"] == "twofactor_restart"
    assert web.accounts.confirm_two_factor(web.accounts.by_email("jon@example.com")["id"], right, h.now) is None, "the set-up was dropped"
    # Starting again with the password opens five more tries.
    again = _js.loads(handle(web, json_req(signed, "POST", "/api/account/2fa/start", {"password": "a long password"})).text())
    code = totp(again["secret"], h.now // 30_000)
    assert handle(web, json_req(signed, "POST", "/api/account/2fa/confirm", {"code": code})).status == 200


def test_password_changes_end_other_sessions(h):
    web = h.web()
    signed = owner(web)
    wrong = handle(web, json_req(signed, "POST", "/api/account/password", {"current": "nope", "next": "a newer long one"}))
    assert wrong.text() == '{"error":"Your current password is not right","code":"password_current_wrong"}'
    short = handle(web, json_req(signed, "POST", "/api/account/password", {"current": "a long password", "next": "short"}))
    assert short.text() == '{"error":"Use a password of at least 10 characters","code":"password_short","params":{"min":"10"}}'
    changed = handle(web, json_req(signed, "POST", "/api/account/password", {"current": "a long password", "next": "a newer long one"}))
    assert changed.text() == '{"ok":true}'
    assert web.signed_in(req("/", "GET", {"cookie": signed})) is None
    assert web.signed_in(req("/", "GET", {"cookie": cookie_of(changed)})) is not None


def test_ten_wrong_passwords_from_one_address_wait(h):
    web = h.web()
    owner(web)
    headers = {"content-type": "application/x-www-form-urlencoded", "x-forwarded-for": "203.0.113.9"}
    body = SearchParams({"email": "jon@example.com", "password": "a wrong password"}).to_string()
    for _ in range(10):
        assert handle(web, req("/login", "POST", headers, body)).status == 401
    held = handle(web, req("/login", "POST", headers, body))
    assert held.status == 429
    assert "Too many tries. Wait fifteen minutes and try again." in held.text()
    right = SearchParams({"email": "jon@example.com", "password": "a long password"}).to_string()
    assert handle(web, req("/login", "POST", headers, right)).status == 429, "even the right password waits"
    elsewhere = {**headers, "x-forwarded-for": "203.0.113.10"}
    assert handle(web, req("/login", "POST", elsewhere, right)).status == 303, "another address is not held up"
    h.now += 15 * 60_000
    assert handle(web, req("/login", "POST", headers, right)).status == 303, "fifteen minutes later"


def test_an_account_held_up_by_others_gets_a_sign_in_link(h):
    web = h.web({"token": "app-token"}, "https://stats.example.com")
    owner(web)
    h.rl.mail = {"service": "smtp", "from": "runlight@example.com"}
    accounts = web.accounts
    # Fifty failures against the account from fifty addresses, counted as the throttle counts them.
    throttle = Throttle(h.rl.store, "account", 50)
    for _ in range(50):
        throttle.fail("jon@example.com", h.now)
    held = handle(web, form("/login", {"email": "jon@example.com", "password": "a long password", "next": "/runlight/?a=1"}))
    assert held.status == 429
    assert "a link to sign in is on its way" in held.text()
    # The link goes out without the answer waiting for it, as TypeScript sends it.
    waited = time.monotonic() + 5
    while not h.rl.sent and time.monotonic() < waited:
        time.sleep(0.01)
    assert len(h.rl.sent) == 1
    assert h.rl.sent[0]["subject"] == "Sign in to Runlight"
    found = re.search(r"(https://stats\.example\.com/runlight/login/link\?\S+)", h.rl.sent[0]["text"])
    assert found
    link = Url(found.group(1))
    assert link.search_params.get("next") == "/runlight/?a=1"
    handle(web, form("/login", {"email": "jon@example.com", "password": "a long password"}))
    time.sleep(0.2)
    assert len(h.rl.sent) == 1, "at most one link a minute"
    wrong_too = handle(web, form("/login", {"email": "jon@example.com", "password": "a wrong password"}))
    assert wrong_too.status == 429, "a wrong password gets the same answer"

    signed_in = handle(web, req(f"/login/link{link.search}"))
    assert signed_in.status == 303
    assert signed_in.headers.get("location") == "/runlight/?a=1"
    assert handle(web, req(f"/login/link{link.search}")).status == 410, "a link works once"
    assert accounts.by_email("jon@example.com") is not None


def test_a_broken_session_cookie_raises_as_decode_uri_component_throws(h):
    web = h.web()
    with pytest.raises(ValueError):
        web.signed_in(req("/", "GET", {"cookie": "runlight_session=%E0%A4%A"}))


def test_the_session_cookie_is_read_among_others(h):
    web = h.web()
    signed = owner(web)
    assert web.signed_in(req("/", "GET", {"cookie": f"a=b; {signed} ; c=d=e"})) is not None
    assert signed.split("=")[0] == SESSION_COOKIE
    plain = Request(
        "http://example.com/runlight/login",
        "POST",
        {"content-type": "application/x-www-form-urlencoded"},
        SearchParams({"email": "jon@example.com", "password": "a long password"}).to_string(),
    )
    assert "Secure" not in handle(web, plain).headers.get_set_cookie()[0], "Secure only over https"
    proxied = Request("http://example.com/runlight/logout", "GET", {"x-forwarded-proto": "https"})
    assert handle(web, proxied).headers.get_set_cookie()[0].endswith("; Secure")
