"""OAuth for the MCP server, so apps that connect only through OAuth (the
Claude and ChatGPT web connectors) can reach it. Runlight is both the
resource and the authorization server:

- /.well-known/oauth-protected-resource names the MCP endpoint and this server.
- /.well-known/oauth-authorization-server lists the endpoints below.
- POST /oauth/register lets a client register itself (public clients, no secret).
- /oauth/authorize asks the signed-in owner to allow the client, every site or one.
- POST /oauth/token swaps the one-time code, checked with PKCE, for a token.

The token is an ordinary API token, so it appears in Settings, API and AI,
beside the others, and deleting it there disconnects the app. It reads
stats, or with the "manage" scope (asked for by a Runlight hub) it also
changes one site's settings.

The context the routes pass is a dict: runlight, base, isOwner (a function of the request giving a bool), and
optionally signIn (text), isReader (a function of the request), accountOf (a function of the request giving an
account id or None), and tokenMade (a function of the token row and who made it, giving a bool).
"""

from __future__ import annotations

import base64
import hashlib
import hmac as _hmac
import re
import threading
import weakref
from collections.abc import Mapping
from typing import Any

from . import _js
from .hash import hmac, random_id, sha256
from .http import Request, Response, SearchParams, Url

CODE_MS = 5 * 60_000
# An app stored before client ids were signed, which never finished connecting within a day, is removed.
UNUSED_CLIENT_MS = 86_400_000
# Registrations one address may make a minute.
REGISTRATIONS_PER_MINUTE = 10
# The longest client id, which carries the app's name and redirect addresses.
MAX_CLIENT_ID = 2048

# Per install, the per-address limit on registrations.
_registrations: weakref.WeakKeyDictionary[Any, Any] = weakref.WeakKeyDictionary()
_registrations_lock = threading.Lock()

CORS = {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, content-type, mcp-protocol-version",
    "access-control-allow-methods": "GET, POST, OPTIONS",
}

_STORED_CLIENT = re.compile(r"[a-f0-9]{32}\Z")
_SIGNED_CLIENT = re.compile(r"([A-Za-z0-9_-]{1,2000})\.([a-f0-9]{64})\Z")
_CHALLENGE = re.compile(r"[A-Za-z0-9_-]{43,128}\Z")
_ESCAPES = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}


def _base64url(text: str) -> str:
    return base64.urlsafe_b64encode(_js.encode(text)).decode("ascii").rstrip("=")


def _from_base64url(text: str) -> str:
    return _js.utf8(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)))


def _client_key(runlight: Any) -> str:
    """The key client ids are signed with, made on first use and kept in the database for every process."""
    saved = runlight.store.setting("oauth-key")
    if saved:
        return saved
    made = random_id(32)
    runlight.store.set_setting("oauth-key", made)
    return made


def _client_for(runlight: Any, id: str) -> dict[str, Any] | None:  # noqa: A002
    """The app a client id names, and where to note that it connected: {client, usedKey}. A new id
    carries the app's name and addresses, signed, so registering stores
    nothing and a flood of registrations fills nothing. Ids from before that
    were stored."""
    if _STORED_CLIENT.match(id):
        stored = runlight.store.setting(f"oauth-client:{id}")
        return {"client": _js.loads(stored), "usedKey": f"oauth-client:{id}"} if stored else None
    parts = _SIGNED_CLIENT.match(id)
    if not parts or len(id) > MAX_CLIENT_ID:
        return None
    if not _constant_time_equal(parts.group(2), hmac(_client_key(runlight), parts.group(1))):
        return None
    meta = _js.loads(_from_base64url(parts.group(1)))
    used_key = f"oauth-used:{sha256(id)}"
    used = runlight.store.setting(used_key)
    client: dict[str, Any] = {"name": meta["n"], "redirects": meta["r"], "createdAt": meta["t"]}
    if used:
        client["usedAt"] = _js.number(used)
    return {"client": client, "usedKey": used_key}


def _constant_time_equal(a: str, b: str) -> bool:
    return len(a) == len(b) and _hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def _esc(value: str) -> str:
    return re.sub("[&<>\"']", lambda m: _ESCAPES[m.group(0)], value)


def _json(body: Any, status: int = 200) -> Response:
    return Response(_js.dumps(body), status, {"content-type": "application/json; charset=utf-8", "cache-control": "no-store", **CORS})


def _oauth_error(error: str, description: str, status: int = 400) -> Response:
    return _json({"error": error, "error_description": description}, status)


def s256(verifier: str) -> str:
    """base64url of SHA-256, as PKCE's S256 method compares."""
    return base64.urlsafe_b64encode(hashlib.sha256(_js.encode(verifier)).digest()).decode("ascii").rstrip("=")


_HTTPS = re.compile(r"https://[^/]+")
_LOOPBACK = re.compile(r"http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?/")


def _allowed_redirect(value: str) -> bool:
    """Redirect addresses a client may register: https, or a local app's own loopback address."""
    return bool(_HTTPS.match(value) or _LOOPBACK.match(value))


def resource_metadata_url(origin: str, base: str) -> str:
    """The URL that a 401 from the MCP endpoint points clients at, to start OAuth."""
    return f"{origin}{base}/.well-known/oauth-protected-resource"


def _allow_registration(runlight: Any, ip: str) -> bool:
    from .limit import RateLimit

    with _registrations_lock:
        limit = _registrations.get(runlight)
        if limit is None:
            limit = RateLimit(REGISTRATIONS_PER_MINUTE, runlight.now)
            _registrations[runlight] = limit
    return limit.allow(ip)


def _json_form(text: str) -> SearchParams:
    """`new URLSearchParams(Object.entries(await request.json().catch(() => ({})) ?? {}))`, each value as String()
    writes it."""
    form = SearchParams()
    ok, body = _js.try_loads(text)
    if not ok or body is None:
        return form
    if isinstance(body, dict):
        for k, v in body.items():
            form.append(k, _js.string(v))
    elif isinstance(body, list):
        for i, v in enumerate(body):
            form.append(str(i), _js.string(v))
    elif isinstance(body, str):
        # Object.entries of text gives each UTF-16 unit; a pair stays whole here.
        for i, c in enumerate(body):
            form.append(str(i), c)
    return form


def oauth_response(ctx: Mapping[str, Any], request: Request, path: str, url: Url, context: Mapping[str, Any] | None = None) -> Response | None:
    """Answers the OAuth paths, or returns None for anything else. `path` is
    relative to the routes' base; the two well-known documents are also answered
    at the site's root (`/.well-known/...`) for clients that look there."""
    context = context or {}
    runlight = ctx["runlight"]
    base: str = ctx["base"]
    issuer = f"{url.origin}{base}"
    known = path
    if request.method == "OPTIONS" and (
        known.startswith("/.well-known/oauth-") or known.startswith("/.well-known/openid-configuration") or path.startswith("/oauth/")
    ):
        return Response("", 204, CORS)

    if known.startswith("/.well-known/oauth-protected-resource"):
        return _json({"resource": f"{issuer}/mcp", "authorization_servers": [issuer], "scopes_supported": ["read", "manage"], "bearer_methods_supported": ["header"]})
    if known.startswith("/.well-known/oauth-authorization-server") or known.startswith("/.well-known/openid-configuration"):
        return _json({
            "issuer": issuer,
            "authorization_endpoint": f"{issuer}/oauth/authorize",
            "token_endpoint": f"{issuer}/oauth/token",
            "registration_endpoint": f"{issuer}/oauth/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": ["read", "manage"],
        })  # fmt: skip

    if path == "/oauth/register" and request.method == "POST":
        runlight.init()
        if not _allow_registration(runlight, runlight.client_ip(request, context)):
            return _oauth_error("invalid_client_metadata", "Too many registrations from this address. Wait a minute and try again.", 429)
        ok, body = _js.try_loads(request.text())
        if not ok:
            body = None
        uris = body.get("redirect_uris") if isinstance(body, dict) else None
        redirects = [r for r in (_js.string(u) for u in uris) if _allowed_redirect(r)][:10] if isinstance(uris, list) else []
        if not redirects:
            return _oauth_error("invalid_redirect_uri", "Register at least one https redirect address")
        name = body.get("client_name") if isinstance(body, dict) else None
        return _register(runlight, "An app" if name is None else _js.string(name), redirects)

    if path == "/oauth/authorize" and request.method in ("GET", "POST"):
        runlight.init()
        form = SearchParams(request.text()) if request.method == "POST" else url.search_params
        client_id = form.get("client_id") or ""
        found = _client_for(runlight, client_id)
        client = found["client"] if found is not None else None
        redirect = form.get("redirect_uri") or ""
        # Without a known client and one of its own addresses there is nowhere safe to send an answer.
        if client is None or redirect not in client["redirects"]:
            return _page("This app is not registered", "<p>Start connecting again from the app.</p>", 400)

        def back(params: Mapping[str, str]) -> Response:
            to = Url(redirect)
            query = to.search_params
            for k, v in params.items():
                query.set(k, v)
            state = form.get("state")
            if state:
                query.set("state", state)
            to.set_search_params(query)
            return Response("", 303, {"location": to.href, "cache-control": "no-store"})

        name = _js.string(client["name"])

        def refuse(params: Mapping[str, str]) -> Response:
            # Anyone can register an app with any address, so until an owner has allowed it once, a request
            # it got wrong ends on a page here rather than sending a visitor who is not signed in on to it.
            if _js.truthy(client.get("usedAt")):
                return back(params)
            said = params.get("error_description") or params["error"]
            return _page(
                "This app asked in a way Runlight does not support",
                f"<p>{_esc(name)} sent {_esc(said)}. Start connecting again from the app.</p>",
                400,
            )

        if form.get("response_type") != "code":
            return refuse({"error": "unsupported_response_type"})
        challenge = form.get("code_challenge") or ""
        if form.get("code_challenge_method") != "S256" or not _CHALLENGE.match(challenge):
            return refuse({"error": "invalid_request", "error_description": "PKCE with S256 is required"})
        manage = "manage" in _js.SPACES.split(form.get("scope") or "")

        if not ctx["isOwner"](request):
            # Someone signed in who may only read would be sent to sign in again and again.
            if ctx.get("isReader") and ctx["isReader"](request):
                return _page(
                    "Ask an owner to connect this",
                    f"<p>You are signed in as a viewer, and only an owner of this Runlight can connect {_esc(name)}.</p>",
                    403,
                )
            # The site stays, since on the way in it only says which one to offer first.
            kept = SearchParams([(k, v) for k, v in form.items() if k != "decision"])
            here = f"{url.pathname}?{kept.to_string()}"
            if ctx.get("signIn"):
                return Response("", 303, {"location": f"{ctx['signIn']}?next={_js.encode_uri_component(here)}", "cache-control": "no-store"})
            home = base or "/"
            return _page(
                "Sign in first",
                f'<p>Open your Runlight dashboard at <a href="{_esc(home)}">{_esc(url.host + home)}</a> and sign in, then connect {_esc(name)} again.</p>',
                401,
            )

        if request.method == "GET":
            hidden = "".join(
                f'<input type="hidden" name="{k}" value="{_esc(form.get(k) or "")}">' if form.get(k) is not None else ""
                for k in ("response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "scope", "resource")
            )
            # The app names itself, so the page also shows where the answer goes, which it cannot fake.
            sends_to = (
                f'<p class="note">Allowing sends you back to <strong>{_esc(Url(redirect).host)}</strong>. '
                "Only allow it if you started connecting there.</p>"
            )
            sites = runlight.sites
            if manage:
                # Changing settings is for one site at a time, so there is no "every site" here.
                wanted = form.get("site") or ""
                choices = "".join(
                    f'<option value="{_esc(s["id"])}"{" selected" if s["id"] == wanted else ""}>{_esc(s["name"])}</option>'
                    for s in sites
                    if not runlight.remote(s["id"])
                )
                return _page(
                    f"Connect {_esc(name)}",
                    f"<p><strong>{_esc(name)}</strong> wants to show this site’s stats and change its settings, so you can manage it from there.</p>\n"
                    "<p>It will be able to change goals, funnels, short links, link domains, email reports, and share links for the site you pick, "
                    "along with its name, timezone, and retention. It cannot read other sites, add people, make tokens, or change how email is sent.</p>\n"
                    f"{sends_to}\n"
                    f'<form method="post" action="{_esc(base)}/oauth/authorize">{hidden}\n'
                    f'<label>Site<select name="site">{choices}</select></label>\n'
                    f'<p class="note">Its token appears in Settings, API and AI, where deleting it disconnects {_esc(name)}.</p>\n'
                    '<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button>'
                    '<button type="submit" name="decision" value="allow">Allow</button></div></form>',
                )
            options = "".join(f'<option value="{_esc(s["id"])}">{_esc(s["name"])} only</option>' for s in sites)
            return _page(
                f"Connect {_esc(name)}",
                f"<p><strong>{_esc(name)}</strong> wants to read your Runlight stats so it can answer questions about them. "
                "It will be able to read and never to change anything.</p>\n"
                f"{sends_to}\n"
                f'<form method="post" action="{_esc(base)}/oauth/authorize">{hidden}\n'
                f'<label>Which sites it can read<select name="site"><option value="">Every site</option>{options if len(sites) > 1 else ""}</select></label>\n'
                '<p class="note">Its token appears in Settings, API and AI, where deleting it disconnects the app.</p>\n'
                '<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button>'
                '<button type="submit" name="decision" value="allow">Allow</button></div></form>',
            )
        # The consent form posts here from this page only; a form from another site is refused.
        origin = request.headers.get("origin")
        if origin and origin != url.origin:
            return _page("This request came from another site", "<p>Start connecting again from the app.</p>", 403)
        if form.get("decision") != "allow":
            return back({"error": "access_denied"})
        site = form.get("site") or ""
        if site and not runlight.site(site):
            return back({"error": "invalid_request", "error_description": "Unknown site"})
        if manage and (not site or runlight.remote(site)):
            return back({"error": "invalid_request", "error_description": "Pick the site to manage"})
        code = random_id(32)
        by = ctx["accountOf"](request) if ctx.get("accountOf") else None
        grant: dict[str, Any] = {
            "client": client_id,
            "redirect": redirect,
            "challenge": challenge,
            "site": site,
            "scope": "manage" if manage else "read",
            "expires": runlight.now() + CODE_MS,
        }
        if by:
            grant["by"] = by
        runlight.store.set_setting(f"oauth-code:{sha256(code)}", _js.dumps(grant))
        return back({"code": code})

    if path == "/oauth/token" and request.method == "POST":
        runlight.init()
        kind = _js.trim((request.headers.get("content-type") or "").split(";")[0])
        form = _json_form(request.text()) if kind == "application/json" else SearchParams(request.text())
        if form.get("grant_type") != "authorization_code":
            return _oauth_error("unsupported_grant_type", "Only authorization_code is supported")
        key = f"oauth-code:{sha256(form.get('code') or '')}"
        stored = runlight.store.setting(key)
        # A code works once: it is gone before anything else is checked.
        if stored:
            runlight.store.set_setting(key, None)
        grant = _js.loads(stored) if stored else None
        if not grant or grant["expires"] < runlight.now():
            return _oauth_error("invalid_grant", "The code has expired or was already used")
        if grant["client"] != form.get("client_id") or grant["redirect"] != form.get("redirect_uri"):
            return _oauth_error("invalid_grant", "The code was issued to another app")
        if s256(form.get("code_verifier") or "") != grant["challenge"]:
            return _oauth_error("invalid_grant", "The code verifier does not match")
        # The first row an app gets here: it has connected, so a request it gets wrong may go back to it.
        found = _client_for(runlight, grant["client"])
        client = found["client"] if found is not None else {}
        if found is not None and not _js.truthy(found["client"].get("usedAt")):
            stored_client = found["usedKey"].startswith("oauth-client:")
            runlight.store.set_setting(
                found["usedKey"], _js.dumps({**found["client"], "usedAt": runlight.now()}) if stored_client else _js.string(runlight.now())
            )
        secret = f"rl_{random_id(20)}"
        scope = "manage" if grant.get("scope") == "manage" else "read"
        client_name = client.get("name")
        row = {
            "id": random_id(),
            "name": _js.cut(f"{'An app' if client_name is None else _js.string(client_name)} (OAuth)", 100),
            "site": grant["site"],
            "scope": scope,
            "hash": sha256(secret),
            "hint": secret[-4:],
            "createdAt": runlight.now(),
            "lastUsedAt": None,
        }
        runlight.store.insert_token(row)
        # Someone removed, or no longer an owner, between allowing the app and its swapping the code gets nothing.
        if grant.get("by") and ctx.get("tokenMade") and not ctx["tokenMade"](row, grant["by"]):
            runlight.store.delete_token(row["id"])
            return _oauth_error("invalid_grant", "Whoever allowed this app can no longer connect it")
        # A hub's own address, from where it asked to be sent back, so the picker only ever sends choices there.
        if scope == "manage":
            runlight.store.set_setting(f"token-origin:{row['id']}", Url(grant["redirect"]).origin)
        # site is not part of OAuth, but a hub needs to know which site it was given.
        answer: dict[str, Any] = {"access_token": secret, "token_type": "Bearer", "scope": scope}
        if grant["site"]:
            answer["site"] = grant["site"]
        return _json(answer)

    return None


def _register(runlight: Any, name: str, redirects: list[str]) -> Response:
    """Registers a client by signing its name and addresses into its id, so
    nothing is stored until an owner allows it and the app swaps its code."""
    now = runlight.now()
    # Apps stored before ids were signed, which never connected, and codes nobody exchanged are cleared away.
    for setting in runlight.store.settings_starting_with("oauth-client:"):
        client = _js.loads(setting["value"])
        if not _js.truthy(client.get("usedAt")) and now - client["createdAt"] >= UNUSED_CLIENT_MS:
            runlight.store.set_setting(setting["key"], None)
    for setting in runlight.store.settings_starting_with("oauth-code:"):
        ok, code = _js.try_loads(setting["value"])
        expires = code.get("expires", 0) if ok and isinstance(code, dict) else 0
        if _js.number(expires) < now:
            runlight.store.set_setting(setting["key"], None)
    client_name = _js.cut(_js.trim(name), 80) or "An app"
    payload = _base64url(_js.dumps({"n": client_name, "r": redirects, "t": now}))
    id_ = f"{payload}.{hmac(_client_key(runlight), payload)}"
    if len(id_) > MAX_CLIENT_ID:
        return _oauth_error("invalid_client_metadata", "Register fewer or shorter redirect addresses")
    return _json(
        {
            "client_id": id_,
            "client_name": client_name,
            "redirect_uris": redirects,
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code"],
            "response_types": ["code"],
        },
        201,
    )


_STYLE = (
    "<style>:root{color-scheme:light dark;--page:#f4f4f5;--card:#fff;--ink:#111827;--muted:#4b5563;--line:#e5e7eb}"
    "@media (prefers-color-scheme:dark){:root{--page:#09090b;--card:#141417;--ink:#fafafa;--muted:#a1a1aa;--line:#27272a}}"
    "body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--page);color:var(--ink);"
    'font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}'
    "main{width:min(440px,calc(100% - 32px));padding:28px;background:var(--card);border:1px solid var(--line);border-radius:14px}"
    "h1{font-size:20px;margin:0 0 12px}p{margin:0 0 16px;color:var(--muted)}p strong{color:var(--ink)}a{color:inherit}"
    "label{display:block;margin:0 0 14px;font-size:13px;font-weight:600}"
    "select{display:block;width:100%;height:40px;margin-top:6px;padding:0 36px 0 12px;border:1px solid var(--line);border-radius:8px;"
    "background:var(--card) url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 6l4 4 4-4' "
    "fill='none' stroke='%238a8a93' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E\") right 12px center/14px no-repeat;"
    "color:var(--ink);font:inherit;font-weight:400;appearance:none;cursor:pointer}.note{font-size:13px}"
    ".buttons{display:flex;justify-content:flex-end;gap:8px}"
    "button{height:40px;padding:0 18px;border:0;border-radius:8px;background:var(--ink);color:var(--card);font:inherit;font-weight:600;cursor:pointer}"
    "button.ghost{background:none;color:var(--ink);border:1px solid var(--line)}</style>"
)


def _page(title: str, body: str, status: int = 200) -> Response:
    return Response(
        '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<meta name="robots" content="noindex"><title>{title} | Runlight</title>\n'
        f"{_STYLE}</head><body><main><h1>{title}</h1>{body}</main></body></html>",
        status,
        {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
            # No form-action rule: browsers apply it to the redirect back to the app after Allow.
            "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'",
            "x-frame-options": "DENY",
            # same-origin, not no-referrer: under no-referrer a form post carries Origin: null, which the consent check
            # refuses.
            "referrer-policy": "same-origin",
        },
    )
