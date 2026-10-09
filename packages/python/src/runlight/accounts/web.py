"""Accounts on the web: sign-in, the code step, invites, first-run setup, and the Account and People APIs, under
the base path the routes answer at. The standalone server and an app with routes({"accounts": True}) share it.

Who may create the first account (`firstAccount`): the server's printed one-time code ({"code": ...}), the app's
token ({"token": ...}), anyone ("open", for development), or nobody yet ("locked").
"""

from __future__ import annotations

import re
import sys
import threading
from collections.abc import Callable, Mapping
from typing import Any

from .. import _js
from ..http import Headers, Request, Response, SearchParams, Url
from .auth import SESSION_COOKIE, SESSION_MS, AccountError, Accounts, Throttle, otpauth_uri
from .crypto import base64url, random_bytes, same_text
from .pages import (
    AUTH_CSS,
    AUTH_JS,
    code_page,
    invite_gone_page,
    invite_page,
    login_page,
    role_text,
    setup_locked_page,
    setup_needs_token_page,
    setup_page,
)

HTML = {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    "x-frame-options": "DENY",
    "referrer-policy": "same-origin",
}

DEVICE_COOKIE = "runlight_device"
# Who made each token, kept beside it as a setting, so removing someone or making them a viewer deletes them.
MADE_BY = "token-by:"
# When each account was last sent a sign-in link, at most one a minute; a setting, so every worker process
# shares it.
LINK_SENT = "login-link-sent:"

_CONTROL = re.compile("[\u0000-\u001f\u007f\\\\]")
_RESET = re.compile(r"/api/people/([a-f0-9]{24})/2fa\Z")
_HAND_OVER = re.compile(r"/api/people/([a-f0-9]{24})/owner\Z")
_INVITE = re.compile(r"/api/invites/([a-f0-9]{24})(/resend)?\Z")
_PERSON = re.compile(r"/api/people/([a-f0-9]{24})\Z")
_ESCAPES = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}


def _esc(s: str) -> str:
    return re.sub("[&<>\"']", lambda m: _ESCAPES[m.group(0)], s)


def _read_cookie(request: Request, name: str) -> str:
    for part in (request.headers.get("cookie") or "").split(";"):
        key, *rest = _js.trim(part).split("=")
        if key == name:
            return "=".join(rest)
    return ""


def _is_secure(request: Request) -> bool:
    return Url(request.url).protocol == "https:" or request.headers.get("x-forwarded-proto") == "https"


def _coded(error: str, code: str, status: int, params: Mapping[str, str] | None = None) -> Response:
    """An error the dashboard words in its own language, as the routes send them."""
    body: dict[str, Any] = {"error": error, "code": code}
    if params is not None:
        body["params"] = dict(params)
    return Response(
        _js.dumps(body),
        status,
        {"content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff"},
    )


def _html(body: str, status: int = 200, extra: Mapping[str, str] | None = None) -> Response:
    return Response(body, status, {**HTML, **(extra or {})})


def _redirect(location: str, extra: Mapping[str, str] | None = None) -> Response:
    return Response("", 303, {"location": location, "cache-control": "no-store", **(extra or {})})


def _reply(body: Any, status: int = 200, extra: Mapping[str, str] | None = None) -> Response:
    return Response(_js.dumps(body), status, {"content-type": "application/json; charset=utf-8", "cache-control": "no-store", **(extra or {})})


def _person(u: dict[str, Any]) -> dict[str, Any]:
    return {"id": u["id"], "email": u["email"], "role": u["role"], "createdAt": u["createdAt"], "twoFactor": u["twoFactor"], "recoveryLeft": u["recoveryLeft"]}


def _invite_view(i: dict[str, Any]) -> dict[str, Any]:
    return {"id": i["id"], "email": i["email"], "role": i["role"], "invitedBy": i["invitedBy"], "createdAt": i["createdAt"], "expiresAt": i["expiresAt"]}


def _media_type(request: Request) -> str:
    """The media type of a request's body, as a cross-site form cannot send application/json."""
    return _js.trim((request.headers.get("content-type") or "").split(";")[0]).lower()


def _body(request: Request) -> dict[str, Any] | None:
    """A JSON body by its media type, which a cross-site form cannot send."""
    if _media_type(request) != "application/json":
        return None
    ok, parsed = _js.try_loads(request.text())
    return parsed if ok and isinstance(parsed, dict) else None


def _field(input: Mapping[str, Any], field: str) -> str:  # noqa: A002
    """`String(input[field] ?? "")`."""
    value = input.get(field)
    return "" if value is None or value is _js.UNDEFINED else _js.string(value)


def _role_of(value: Any) -> str | None:
    """Nobody is invited as, or made, the owner: there is one, and they hand it over themselves."""
    return value if value in ("admin", "member", "viewer") and isinstance(value, str) else None


class AccountsWeb:
    """What accounts_web() hands back: `accounts`, and signed_in(), access(), account_of(), token_made(),
    has_account(), and handle()."""

    def __init__(self, options: Mapping[str, Any]) -> None:
        self.rl = options["runlight"]
        self.store = self.rl.store
        self.base: str = options["base"]
        self._now: Callable[[], int] = options["now"]
        self.first: Any = options["firstAccount"]
        self._home: Callable[[], str | None] | None = options.get("home")
        self.forgot: str = options["forgot"]
        # Where to find the setup link with the one-time code, when it is not in a log (HTML).
        self.setup_where: str | None = options.get("setupWhere")
        self.accounts = Accounts(self.store, options["secret"])
        self.cookie_path = self.base or "/"
        self.home_path = f"{self.base}/"
        self.asks_for_token = isinstance(self.first, Mapping) and "token" in self.first
        self._existing = False
        # Wrong passwords are counted twice. Per account and address, ten tries;
        # per account from anywhere, fifty, so a caller who invents a new address
        # for every try still cannot guess on and on. Addresses come from
        # forwarding headers a client can write, so they never stand alone.
        # Each try counts before the password is checked, and a right one is taken back.
        self.per_address = Throttle(self.store, "address", 10)
        self.per_account = Throttle(self.store, "account", 50)
        # Six-digit codes: five wrong tries an account every fifteen minutes, and five to confirm the first one.
        # Password re-checks in Account: ten.
        self.code_tries = Throttle(self.store, "code", 5)
        self.confirm_tries = Throttle(self.store, "confirm", 5)
        self.rechecks = Throttle(self.store, "recheck", 10)

    def now(self) -> int:
        return self._now()

    def _home_origin(self) -> str | None:
        return None if self._home is None else self._home()

    def has_account(self) -> bool:
        self._existing = self._existing or self.accounts.count() > 0
        return self._existing

    def safe_next(self, value: str | None) -> str:
        """Only a path on this install, so a sign-in can never send someone elsewhere.
        Browsers drop tabs and newlines from a URL and read a backslash as a slash,
        so "/\\t/evil.example" would leave; anything with those is refused outright,
        and what is left must resolve to this origin."""
        if not value or not value.startswith("/") or _CONTROL.search(value):
            return self.home_path
        url = Url.parse(value, "http://runlight.invalid")
        return f"{url.pathname}{url.search}{url.hash}" if url is not None and url.origin == "http://runlight.invalid" else self.home_path

    def signed_in(self, request: Request) -> dict[str, Any] | None:
        value = _read_cookie(request, SESSION_COOKIE)
        if not value:
            return None
        decoded = _js.decode_uri_component(value)
        if decoded is None:
            # decodeURIComponent throws a URIError here in TypeScript.
            raise ValueError("URI malformed")
        return self.accounts.from_session(decoded, self.now())

    def _drop_tokens_of(self, id_: str) -> None:
        for setting in self.store.settings_starting_with(MADE_BY):
            if setting["value"] != id_:
                continue
            self.store.delete_token(setting["key"][len(MADE_BY) :])
            self.store.set_setting(setting["key"], None)

    def _session_cookie(self, request: Request, value: str, max_age: int) -> str:
        secure = "; Secure" if _is_secure(request) else ""
        return f"{SESSION_COOKIE}={_js.encode_uri_component(value)}; Path={self.cookie_path}; HttpOnly; SameSite=Lax; Max-Age={max_age}{secure}"

    def _signed_in_to(self, request: Request, user: dict[str, Any], next_: str) -> Response:
        """The redirect after signing in: a session, and the mark that this browser has signed in to the account."""
        headers = Headers({"location": next_, "cache-control": "no-store"})
        headers.append("set-cookie", self._session_cookie(request, self.accounts.session_for(user, self.now()), SESSION_MS // 1000))
        secure = "; Secure" if _is_secure(request) else ""
        device = _js.encode_uri_component(self.accounts.device_for(user))
        headers.append("set-cookie", f"{DEVICE_COOKIE}={device}; Path={self.cookie_path}; HttpOnly; SameSite=Lax; Max-Age={365 * 86_400}{secure}")
        return Response("", 303, headers)

    def _fresh(self, request: Request, user: dict[str, Any]) -> dict[str, str]:
        return {"set-cookie": self._session_cookie(request, self.accounts.session_for(user, self.now()), SESSION_MS // 1000)}

    def _setup_ok(self, given: str) -> bool:
        """The first account's gate: what the setup form must carry."""
        if self.first == "open":
            return True
        if self.first == "locked":
            return False
        return same_text(given, str(self.first["code"] if "code" in self.first else self.first["token"]))

    def _setup_locked(self) -> Response:
        """Why there is no setup form."""
        return _html(setup_needs_token_page(self.base) if self.first == "locked" else setup_locked_page(self.base, self.setup_where), 403)

    def _send_invite(self, request: Request, invite: dict[str, Any], code: str) -> dict[str, Any]:
        """Emails an invite through the mail service when there is one. The link
        always comes back too, for the inviter to pass on another way."""
        origin = self._home_origin()
        if origin is None:
            origin = Url(request.url).origin
        link = f"{origin}{self.base}/invite?code={code}"
        host = Url(origin).host
        what = role_text(invite["role"])
        if not self.rl.mail_settings():
            return {"link": link, "emailed": False}
        try:
            self.rl.send_mail({
                "to": invite["email"],
                "subject": f"{invite['invitedBy']} invited you to Runlight",
                "text": f"{invite['invitedBy']} invited you to the Runlight at {host} as {what}.\n\nChoose a password to join:\n{link}\n\nThe link works for seven days.\n",
                "html": f"""<div style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px"><p>{_esc(invite['invitedBy'])} invited you to the Runlight at {_esc(host)} as {what}.</p><p><a href="{_esc(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Choose a password and join</a></p><p style="color:#6b7280;font-size:13px">The link works for seven days. If you were not expecting this, you can ignore it.</p></div>""",
            })  # fmt: skip
            return {"link": link, "emailed": True}
        except Exception as error:  # noqa: BLE001
            # The mail service's code and its details too, so the dashboard can say what went wrong in its own
            # language. Only a string `code` counts, as TypeScript reads `typeof failed.code === "string"`.
            out: dict[str, Any] = {"link": link, "emailed": False, "mailError": getattr(error, "message", str(error))}
            code_ = getattr(error, "code", None)
            if isinstance(code_, str):
                out["mailCode"] = code_
                params = getattr(error, "params", None)
                out["mailParams"] = dict(params) if isinstance(params, Mapping) else {}
            return out

    def _send_link(self, user: dict[str, Any], next_: str) -> bool:
        """Emails a sign-in link to an account held up by others' failed tries, at
        most once a minute. Only to the install's own address, never the Host of
        the request, so without one known there is no link."""
        origin = self._home_origin()
        if not origin:
            return False
        key = f"{LINK_SENT}{user['id']}"
        if self.now() - _js.number(self.store.setting(key) or 0) < 60_000:
            return True
        self.store.set_setting(key, _js.string(self.now()))
        query = SearchParams({"ticket": self.accounts.link_for(user, self.now()), "next": next_}).to_string()
        link = f"{origin}{self.base}/login/link?{query}"
        host = Url(origin).host
        self.rl.send_mail({
            "to": user["email"],
            "subject": "Sign in to Runlight",
            "text": f"Someone, most likely you, signed in to Runlight at {host} with your password while your account was held up by too many failed tries.\n\nSign in with this link within fifteen minutes:\n{link}\n\nIf this was not you, change your password, since someone knows it.\n",
            "html": f"""<div style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px"><p>Someone, most likely you, signed in to Runlight at {_esc(host)} with your password while your account was held up by too many failed tries.</p><p><a href="{_esc(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Sign in</a></p><p style="color:#6b7280;font-size:13px">The link works for fifteen minutes. If this was not you, change your password, since someone knows it.</p></div>""",
        })  # fmt: skip
        return True

    def _send_link_later(self, user: dict[str, Any], next_: str) -> None:
        """Sends the link without waiting for it, as TypeScript does, so how long the answer takes never tells a
        right password from a wrong one."""

        def run() -> None:
            try:
                self._send_link(user, next_)
            except Exception as error:  # noqa: BLE001
                print(f"Runlight: could not send a sign-in link {error}", file=sys.stderr)

        threading.Thread(target=run, daemon=True).start()

    def _pages(self, request: Request, path: str, context: Mapping[str, Any]) -> Response | None:
        url = Url(request.url)
        query = url.search_params
        method = request.method
        base = self.base
        if path == "/auth.css":
            return Response(AUTH_CSS, 200, {"content-type": "text/css; charset=utf-8", "cache-control": "public, max-age=3600"})
        if path == "/auth.js":
            return Response(AUTH_JS, 200, {"content-type": "application/javascript; charset=utf-8", "cache-control": "public, max-age=3600"})

        if path == "/setup":
            if self.has_account():
                return _redirect(f"{base}/login")
            if method == "GET":
                code = query.get("code") or ""
                if self.first == "locked":
                    return self._setup_locked()
                # The app's token is typed in; the server's code comes in the link it printed.
                if self.asks_for_token or self.first == "open":
                    return _html(setup_page(base, {"code": "", "askCode": self.asks_for_token}))
                return _html(setup_page(base, {"code": code})) if self._setup_ok(code) else self._setup_locked()
            if method == "POST":
                form = SearchParams(request.text())
                code = form.get("code") or ""
                if not self._setup_ok(code):
                    if self.asks_for_token:
                        return _html(setup_page(base, {"code": "", "askCode": True, "error": "That is not this app's RUNLIGHT_TOKEN.", "email": form.get("email") or ""}), 403)
                    return self._setup_locked()

                def again(error: str) -> dict[str, Any]:
                    return {"code": "" if self.asks_for_token else code, "askCode": self.asks_for_token, "error": error, "email": form.get("email") or ""}

                # Asked twice, since a typo here would lock the first owner out.
                if (form.get("password") or "") != (form.get("again") or ""):
                    return _html(setup_page(base, again("The two passwords are not the same.")), 400)
                try:
                    user = self.accounts.set_password(form.get("email") or "", form.get("password") or "", self.now())
                    self._existing = True
                    return _redirect(self.home_path, self._fresh(request, user))
                except _js.RangeError as error:
                    return _html(setup_page(base, again(str(error))), 400)

        if path == "/login":
            if not self.has_account():
                if self.first == "locked":
                    return self._setup_locked()
                return _redirect(f"{base}/setup") if self.first == "open" or self.asks_for_token else self._setup_locked()
            if method == "GET":
                return _html(login_page(base, {"next": self.safe_next(query.get("next")), "forgot": self.forgot}))
            if method == "POST":
                return self._login(request, context)

        # The link a locked account's owner is emailed: the code step with two-factor on, else straight in.
        if path == "/login/link" and method == "GET":
            next_ = self.safe_next(query.get("next"))
            user = self.accounts.from_link(query.get("ticket") or "", self.now())
            if user is None:
                return _html(login_page(base, {"error": "That sign-in link has run out. Sign in again.", "next": next_, "forgot": self.forgot}), 410)
            if user["twoFactor"]:
                return _html(code_page(base, {"pending": self.accounts.pending_for(user, self.now()), "next": next_}))
            return self._signed_in_to(request, user, next_)

        if path == "/login/code" and method == "POST":
            form = SearchParams(request.text())
            next_ = self.safe_next(form.get("next"))
            pending = self.accounts.from_pending(form.get("pending") or "", self.now())
            if pending is None:
                return _redirect(f"{base}/login?next={_js.encode_uri_component(next_)}")
            user, real = pending["user"], pending["real"]
            # Counted before the check, so a burst cannot get past five.
            if not self.code_tries.take(user["id"], self.now()):
                return _html(code_page(base, {"pending": form.get("pending") or "", "next": next_, "error": "Too many tries. Wait fifteen minutes and try again."}), 429)
            if not real or not self.accounts.check_second_factor(user["id"], form.get("code") or "", self.now()):
                return _html(
                    code_page(base, {"pending": form.get("pending") or "", "next": next_, "error": "That code is not right. Check the time on your phone, or use a recovery code."}),
                    401,
                )
            self.code_tries.clear(user["id"])
            return self._signed_in_to(request, user, next_)

        if path == "/logout":
            return _redirect(f"{base}/login", {"set-cookie": self._session_cookie(request, "", 0)})

        if path == "/invite":
            if method == "GET":
                code = query.get("code") or ""
                invite = self.accounts.invite_by_code(code, self.now())
                if invite is None:
                    return _html(invite_gone_page(base), 410)
                return _html(invite_page(base, {"code": code, "email": invite["email"], "role": invite["role"], "host": url.host}))
            if method == "POST":
                form = SearchParams(request.text())
                code = form.get("code") or ""
                invite = self.accounts.invite_by_code(code, self.now())
                if invite is None:
                    return _html(invite_gone_page(base), 410)

                def again_page(error: str) -> Response:
                    return _html(invite_page(base, {"code": code, "email": invite["email"], "role": invite["role"], "host": url.host, "error": error}), 400)

                if (form.get("password") or "") != (form.get("again") or ""):
                    return again_page("The two passwords are not the same.")
                try:
                    user = self.accounts.accept_invite(code, form.get("password") or "", self.now())
                    self._existing = True
                    return _redirect(self.home_path, self._fresh(request, user))
                except _js.RangeError as error:
                    return again_page(str(error))
        return None

    def _login(self, request: Request, context: Mapping[str, Any]) -> Response:
        base = self.base
        form = SearchParams(request.text())
        email = form.get("email") or ""
        password = form.get("password") or ""
        next_ = self.safe_next(form.get("next"))
        account = _js.lower(_js.trim(email))
        ip = self.rl.client_ip(request, context)
        pair = f"{account}\n{ip or 'unknown'}"

        def login(opts: dict[str, Any]) -> str:
            return login_page(base, {**opts, "next": next_, "forgot": self.forgot})

        def too_many() -> Response:
            return _html(login({"error": "Too many tries. Wait fifteen minutes and try again.", "email": email}), 429)

        if not self.per_address.take(pair, self.now()):
            return too_many()
        # A browser that signed in to the account before is never held up by others' failures.
        known = self.accounts.by_email(account)
        trusted = known is not None and self.accounts.trusts_device(_read_cookie(request, DEVICE_COOKIE), known)
        over = not trusted and not self.per_account.take(account, self.now())
        # Past the account's limit, a right password and a wrong one get the same answer, so guessing from many
        # addresses learns nothing, and the owner still gets in. With two-factor on, both reach the code step,
        # where a wrong password's ticket never passes. Without it, a right password emails a sign-in link.
        if over and not (known is not None and known["twoFactor"]):
            if not self.rl.mail_settings() or not self._home_origin():
                return too_many()
            user = self.accounts.sign_in(email, password)
            if user is not None:
                self._send_link_later(user, next_)
            return _html(login({"error": "Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.", "email": email}), 429)
        user = self.accounts.sign_in(email, password)
        if user is None:
            if over and known is not None:
                return _html(code_page(base, {"pending": self.accounts.decoy_for(known, self.now()), "next": next_}))
            return _html(login({"error": "That email and password do not match an account.", "email": email}), 401)
        self.per_address.clear(pair)
        if not over and not trusted:
            self.per_account.forgive(account)
        # With two-factor on, the password only earns the second step.
        if user["twoFactor"]:
            return _html(code_page(base, {"pending": self.accounts.pending_for(user, self.now()), "next": next_}))
        return self._signed_in_to(request, user, next_)

    def _api(self, request: Request, path: str) -> Response:
        """Your own account, and for the owner and admins, everyone else's."""
        user = self.signed_in(request)
        if user is None:
            return _coded("Sign in first", "sign_in", 401)
        now = self.now()
        method = request.method
        # Writes must be JSON, which a form on another page cannot send, even those with no body.
        if method == "POST" and _media_type(request) != "application/json":
            return _coded("Send JSON", "send_json", 415)
        if path == "/api/account" and method == "GET":
            return _reply({"account": _person(user)})

        def recheck(input: Mapping[str, Any], field: str, wrong: tuple[str, str]) -> Response | None:  # noqa: A002
            if not self.rechecks.take(user["id"], now):
                return _coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429)
            if self.accounts.sign_in(user["email"], _field(input, field)) is None:
                return _coded(wrong[0], wrong[1], 400)
            self.rechecks.forgive(user["id"])
            return None

        if path == "/api/account/password" and method == "POST":
            input = _body(request)  # noqa: A001
            if input is None:
                return _coded("Send JSON", "send_json", 415)
            refused = recheck(input, "current", ("Your current password is not right", "password_current_wrong"))
            if refused is not None:
                return refused
            try:
                updated = self.accounts.set_password(user["email"], _field(input, "next"), now)
                # The new password ends every other sign-in; this browser gets a fresh one.
                return _reply({"ok": True}, 200, self._fresh(request, updated))
            except AccountError as error:
                return _coded(error.message, error.code, 400, error.params)
        # Two-factor: turning it on, confirming the first code, new recovery codes, and turning it off.
        # Each change asks for the password again, so a browser left signed in cannot quietly change it.
        if path.startswith("/api/account/2fa") and method == "POST":
            input = _body(request)  # noqa: A001
            if input is None:
                return _coded("Send JSON", "send_json", 415)
            action = path[len("/api/account/2fa") :]
            # Confirming asks for no password, so it has its own few tries, after which the set-up starts again.
            if action == "/confirm":
                if not self.confirm_tries.take(user["id"], now):
                    self.accounts.cancel_two_factor_setup(user["id"])
                    return _coded("Too many wrong codes. Start turning on two-factor sign-in again.", "twofactor_restart", 429)
                codes = self.accounts.confirm_two_factor(user["id"], _js.SPACE.sub("", _field(input, "code")), now)
                if codes is None:
                    return _coded("That code is not right. Check the time on your phone and try the next one.", "code_wrong", 400)
                self.confirm_tries.clear(user["id"])
                # Turning it on signs out every other browser; this one gets a new session.
                updated = self.accounts.by_id(user["id"])
                return _reply({"recovery": codes}, 200, self._fresh(request, updated))
            refused = recheck(input, "password", ("Your password is not right", "password_wrong"))
            if refused is not None:
                return refused
            if action == "/start":
                self.confirm_tries.clear(user["id"])
                secret = self.accounts.start_two_factor(user["id"])
                return _reply({"secret": secret, "uri": otpauth_uri(secret, user["email"], Url(request.url).host)})
            if action == "/recovery":
                if not user["twoFactor"]:
                    return _coded("Turn on two-factor sign-in first", "twofactor_off", 400)
                return _reply({"recovery": self.accounts.new_recovery_codes(user["id"])})
            if action == "/disable":
                self.accounts.disable_two_factor(user["id"])
                # Sessions follow two-factor's state, so this browser gets a new one and stays signed in.
                updated = self.accounts.by_id(user["id"])
                return _reply({"ok": True}, 200, self._fresh(request, updated))
            return _coded("Not found", "not_found", 404)
        if user["role"] not in ("owner", "admin"):
            return _coded("Only the owner or an admin can manage people", "people_owner", 403)
        # The owner or an admin can turn off someone else's two-factor, for a coworker who lost both phone and
        # recovery codes, though never the owner's. It asks for their password like every other two-factor change,
        # and their own goes through Account.
        reset = _RESET.match(path)
        if reset and method == "DELETE":
            if reset.group(1) == user["id"]:
                return _coded("Turn off your own two-factor sign-in under Account", "twofactor_self", 400)
            input = _body(request)  # noqa: A001
            if input is None:
                return _coded("Send JSON", "send_json", 415)
            refused = recheck(input, "password", ("Your password is not right", "password_wrong"))
            if refused is not None:
                return refused
            target = self.accounts.by_id(reset.group(1))
            if target is None:
                return _coded("Unknown account", "unknown_account", 404)
            if target["role"] == "owner":
                return _coded("Only the owner can change the owner's account", "owner_protected", 403)
            self.accounts.disable_two_factor(reset.group(1))
            return _reply({"ok": True})
        # The owner hands ownership to an admin and becomes an admin, after typing their password again.
        hand_over = _HAND_OVER.match(path)
        if hand_over and method == "POST":
            if user["role"] != "owner":
                return _coded("Only the owner can hand over ownership", "owner_hand_over", 403)
            input = _body(request)  # noqa: A001
            if input is None:
                return _coded("Send JSON", "send_json", 415)
            refused = recheck(input, "password", ("Your password is not right", "password_wrong"))
            if refused is not None:
                return refused
            try:
                self.accounts.hand_over(user["id"], hand_over.group(1))
                return _reply({"people": [_person(p) for p in self.accounts.list()]})
            except AccountError as error:
                return _coded(error.message, error.code, 404 if error.code == "unknown_account" else 400, error.params)
        if path == "/api/people" and method == "GET":
            return _reply({"people": [_person(p) for p in self.accounts.list()], "invites": [_invite_view(i) for i in self.accounts.invites(now)]})
        if path == "/api/people" and method == "POST":
            input = _body(request)  # noqa: A001
            if input is None:
                return _coded("Send JSON", "send_json", 415)
            role = _role_of(input.get("role"))
            if role is None:
                return _coded("Pick admin, member, or viewer", "role_needed", 400)
            email = _js.lower(_js.trim(_field(input, "email")))
            if self.accounts.by_email(email) is not None:
                return _coded(f"{email} already has an account", "account_exists", 409, {"email": email})
            try:
                made = self.accounts.invite(email, role, user["email"], now)
                return _reply({"invite": _invite_view(made["invite"]), **self._send_invite(request, made["invite"], made["code"])}, 201)
            except AccountError as error:
                return _coded(error.message, error.code, 400, error.params)
        invite_match = _INVITE.match(path)
        if invite_match and method == "DELETE" and not invite_match.group(2):
            return _reply({"ok": True}) if self.accounts.cancel_invite(invite_match.group(1)) else _coded("Unknown invite", "unknown_invite", 404)
        if invite_match and method == "POST" and invite_match.group(2):
            old = next((i for i in self.accounts.invites(now) if i["id"] == invite_match.group(1)), None)
            if old is None:
                return _coded("Unknown invite", "unknown_invite", 404)
            # A new link replaces the old one, which stops working.
            made = self.accounts.invite(old["email"], old["role"], user["email"], now)
            return _reply({"invite": _invite_view(made["invite"]), **self._send_invite(request, made["invite"], made["code"])})
        match = _PERSON.match(path)
        if match and method in ("PATCH", "DELETE"):
            try:
                if method == "DELETE":
                    if match.group(1) == user["id"]:
                        return _coded("You cannot remove yourself", "remove_self", 400)
                    self.accounts.remove(match.group(1))
                    # The tokens they made, and the apps they connected, stop working with them.
                    self._drop_tokens_of(match.group(1))
                    return _reply({"ok": True})
                input = _body(request)  # noqa: A001
                if input is None:
                    return _coded("Send JSON", "send_json", 415)
                role = _role_of(input.get("role"))
                if role is None:
                    return _coded("Pick admin, member, or viewer", "role_needed", 400)
                changed = self.accounts.set_role(match.group(1), role)
                # A viewer changes nothing, so the tokens they made before go too.
                if role == "viewer":
                    self._drop_tokens_of(match.group(1))
                return _reply({"person": _person(changed)})
            except AccountError as error:
                status = 404 if error.code == "unknown_account" else 403 if error.code == "owner_protected" else 400
                return _coded(error.message, error.code, status, error.params)
        return _coded("Not found", "not_found", 404)

    def access(self, request: Request) -> bool | str:
        """What a signed-in person may do: everything (owner and admin, True), "member", "read" (viewer), or
        nothing (False)."""
        user = self.signed_in(request)
        if user is None:
            return False
        # A member changes everything but the install-wide controls; a viewer reads every site and changes nothing.
        return True if user["role"] in ("owner", "admin") else "member" if user["role"] == "member" else "read"

    def account_of(self, request: Request) -> str | None:
        user = self.signed_in(request)
        return user["id"] if user is not None else None

    def token_made(self, token: Mapping[str, Any], by: str) -> bool:
        """Notes who made a token. A viewer makes no tokens; someone removed or made a viewer since allowing an app
        gets none for it, and False takes the token back."""
        user = self.accounts.by_id(by)
        if user is None or user["role"] == "viewer":
            return False
        self.store.set_setting(f"{MADE_BY}{token['id']}", by)
        return True

    def handle(self, request: Request, path: str, context: Mapping[str, Any] | None = None) -> Response | None:
        """Answers an account page or API request at a path under the base, or None for anything else."""
        context = context or {}
        if path == "/api/account" or path.startswith("/api/account/") or path == "/api/people" or path.startswith("/api/people/") or path.startswith("/api/invites/"):
            return self._api(request, path)
        page = self._pages(request, path, context)
        if page is not None:
            return page
        # The dashboard itself: straight to sign-in, or to setting up the first account.
        if path in ("/", "") and request.method == "GET" and self.signed_in(request) is None:
            if not self.has_account():
                return _redirect(f"{self.base}/setup") if self.first == "open" or self.asks_for_token else self._setup_locked()
            search = Url(request.url).search
            return _redirect(f"{self.base}/login" + (f"?next={_js.encode_uri_component(f'{self.home_path}{search}')}" if search else ""))
        return None


def accounts_web(options: Mapping[str, Any]) -> AccountsWeb:
    """Accounts on the web. options: runlight, secret (signs sessions and seals two-factor secrets; keep it stable
    across restarts), base ("" on the standalone server, "/runlight" in an app), now, firstAccount, home (a function
    giving the address emails link to, the install's public one when known; without it, a locked account gets no
    link), forgot (where the sign-in page sends someone who forgot their password), and setupWhere."""
    return AccountsWeb(options)


def setup_code() -> str:
    """A random one-time code, such as the one a server prints to unlock its first account."""
    return base64url(random_bytes(9))
