"""The dashboard, its API, the tracker, the MCP server, and OAuth, under one base path, as routes.ts serves them.

`create_routes(runlight, options)` (or `runlight.routes(options)`) gives a Routes whose `handle(request, context)`
answers every request under the base path. Options take the TypeScript names:

- basePath: where the routes are mounted. Default "/runlight".
- token: required to read stats. Send it as `Authorization: Bearer <token>`, or open the dashboard once with
  `?token=<token>` and a cookie is set. Absent means RUNLIGHT_TOKEN. Without one, the dashboard and API are open
  only when NODE_ENV is "development", and answer 503 everywhere else. Pass None to leave them open everywhere,
  for example behind your own auth middleware.
- authorize: a callable(Request) giving True, "member", "read", or False, your own check instead of a token. True
  is full access, "member" changes everything but the install-wide controls (the mail service, the assistant's
  settings, and deleting a site), "read" reads every site's stats and changes nothing (as an API token can).
- cronSecret: also accepted as a bearer token on POST /api/check, so a platform cron can run scheduled work.
  Defaults to CRON_SECRET.
- observeKey: lets another site report AI agent fetches to POST /api/observe without the dashboard token: what
  the WordPress, Drupal, and Craft plugins use. Defaults to RUNLIGHT_OBSERVE_KEY. The token works too.
- signOut, signIn: links the dashboard shows. The standalone server sets them.
- accounts: True for sign-in accounts for the dashboard, or an accounts web object of your own.
- geoCredit: credits DB-IP in the dashboard's footer, as its free location data asks.
- origin: the address people open the app at, such as https://example.com. A link domain can never be its host,
  and links in email reports point there, whatever Host header a request carries.
- ownHosts: a callable giving more names the dashboard is reached at, which can never be link domains either.
- accountOf (internal): callable(Request) giving the account a request comes from.
- tokenMade (internal): callable(token, by) noting who made a token; False takes it back.
"""

from __future__ import annotations

import hmac as _hmac
import re
import sys
import weakref
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from typing import Any

from . import _js, assets
from .brand import RUNLIGHT_ICON
from .env import env_value as env
from .hash import hmac, random_id, sha256
from .http import FetchError, Headers, Request, Response, Url

COOKIE = "runlight_token"
IMPLEMENTATION = {"library": "runlight", "language": "python"}
# TS's RangeError is _js.RangeError (a ValueError): SettingsError, ConnectError, and "Unknown link" from Links.

# runlight.ts's LINK_DOMAIN_CHECK: the path on every link domain that answers when the domain reaches this Runlight.
LINK_DOMAIN_CHECK = "/.well-known/runlight-link-domain"
# runlight.ts's RETENTION_MONTHS: the choices for how long a site keeps its visits.
RETENTION_MONTHS = [6, 12, 24, 36, 60]

_WS = _js.WHITESPACE
# runlight.ts's EMAIL: something@somewhere.tld, with no spaces, quotes, or angle brackets.
_EMAIL = re.compile(f'[^{_WS}@<>"]+@[^{_WS}@<>"]+\\.[^{_WS}@<>"]+\\Z')

_HTML_ESCAPES = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}


def escape_html(value: str) -> str:
    return re.sub(r"[&<>\"']", lambda m: _HTML_ESCAPES[m.group(0)], value)


def _is_oauth_document(path: str) -> bool:
    """The discovery documents OAuth clients read: two of OAuth's own, and OpenID's, which some clients try first."""
    return path.startswith("/.well-known/oauth-") or path.startswith("/.well-known/openid-configuration")


def _is_development() -> bool:
    return env("NODE_ENV") == "development"


def coded(
    error: str,
    code: str,
    status: int,
    params: Mapping[str, str] | None = None,
    headers: Mapping[str, str] | None = None,
) -> Response:
    """An error the dashboard can show in its own language: `code` names it and `params` fill its placeholders,
    while `error` stays the English message."""
    body: dict[str, Any] = {"error": error, "code": code}
    if params is not None:
        body["params"] = dict(params)
    return json(body, status, headers or {})


def _refused(error: BaseException, fallback: str, status: int = 400) -> Response:
    """A refusal from a check elsewhere: its own code and params when the error carries them, or else `fallback`
    with its English words as `detail`."""
    code = getattr(error, "code", None)
    message = _message(error)
    if isinstance(code, str):
        params = getattr(error, "params", None)
        return coded(message, code, status, params if isinstance(params, Mapping) else None)
    return coded(message, fallback, status, {"detail": message})


def _message(error: BaseException) -> str:
    message = getattr(error, "message", None)
    if isinstance(message, str):
        return message
    return str(error.args[0]) if error.args else ""


def json(body: Any, status: int = 200, headers: Mapping[str, str] | None = None) -> Response:
    all_headers = {"content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff"}
    all_headers.update(headers or {})
    return Response(_js.dumps(body), status, all_headers)


def is_json(request: Request) -> bool:
    """Whether a request's body is JSON by its media type. A cross-site form or a no-cors fetch can only send
    text/plain, urlencoded, or multipart, so a JSON media type proves the request came from a page allowed to send
    it. A substring test would accept "text/plain; application/json", which can."""
    return _js.trim((request.headers.get("content-type") or "").split(";")[0]).lower() == "application/json"


def host_name(value: str) -> str:
    """A Host or X-Forwarded-Host value as a bare name: lowercase, with no port, no final dot, and no www."""
    first = _js.trim(value.split(",")[0]).lower()
    name = first[: first.find("]") + 1] if first.startswith("[") else re.sub(r":[0-9]*\Z", "", first)
    return re.sub(r"^www\.", "", re.sub(r"\.+\Z", "", name))


# A domain name, such as go.example.com.
DOMAIN_NAME = re.compile(r"(?=.{1,253}\Z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\Z")


def _private_name(domain: str) -> bool:
    """Whether a domain name is one kept for private networks or tests, or has an IPv4 address inside it (as nip.io
    answers). The link-domain check fetches from it, so a name inside the install's own network must never get that
    far; names that only resolve there are refused when fetched."""
    if re.search(r"(^|\.)[0-9]{1,3}(\.[0-9]{1,3}){3}(\.|\Z)", domain):
        return True
    return bool(re.search(r"\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\.arpa|arpa|test|invalid|example)\Z", domain))


def _is_email(value: str) -> bool:
    return bool(_EMAIL.match(value))


def _entries(value: Any) -> list[tuple[str, Any]]:
    """Object.entries(value) for a JSON value: an object's pairs, an array's indexes, nothing for the rest."""
    if isinstance(value, dict):
        return [(str(k), v) for k, v in value.items()]
    if isinstance(value, list):
        return [(str(i), v) for i, v in enumerate(value)]
    return []


def _get(body: Any, key: str) -> Any:
    """body[key] for a parsed JSON value, UNDEFINED where there is no such property."""
    return body.get(key, _js.UNDEFINED) if isinstance(body, dict) else _js.UNDEFINED


def _text(body: Any, key: str, fallback: str = "") -> str:
    """String(body[key] ?? fallback)."""
    value = _get(body, key)
    return fallback if value is None or value is _js.UNDEFINED else _js.string(value)


def _or(value: Mapping[str, Any] | None, key: str, fallback: Any) -> Any:
    """value?.[key] ?? fallback."""
    found = value.get(key) if value else None
    return fallback if found is None else found


def _defined(body: Any, key: str) -> bool:
    return _get(body, key) is not _js.UNDEFINED


def _credentials(value: Any) -> dict[str, str]:
    """Object.fromEntries(Object.entries(value).map(([k, v]) => [k, String(v)])) for an object, else nothing."""
    if not _js.truthy(value) or not _js.is_object(value):
        return {}
    return {k: _js.string(v) for k, v in _entries(value)}


class _UriError(Exception):
    """decodeURIComponent threw. Not a RangeError, so it ends as an internal
    error, as a URIError does in the TypeScript."""


def _decode(text: str) -> str:
    """decodeURIComponent, which throws on a broken escape."""
    decoded = _js.decode_uri_component(text)
    if decoded is None:
        raise _UriError("URI malformed")
    return decoded


def _limit(value: str | None, fallback: int) -> Any:
    """Math.min(1000, Math.max(1, Number(value) || fallback))."""
    n = _js.number(value)
    if not _js.truthy(n):
        n = fallback
    return min(1000, max(1, n))


def _translator(lang: str) -> tuple[Callable[..., str], str]:
    from .messages import translator

    made = translator(lang)
    if isinstance(made, Mapping):
        return made["t"], made["lang"]
    return made.t, made.lang


def _languages() -> list[str]:
    from .messages import languages

    return list(languages())


def _pass_through(runlight: Any, remote: Mapping[str, Any], path: str, url: Url, request: Request | None = None) -> Response:
    """Answers a read for a site counted by another install by asking that install, with its token and its own id
    for the site, and handing back what it says."""
    target = Url(f"{remote['url']}{path}")
    query = target.search_params
    for key, value in url.search_params:
        query.append(key, value)
    query.set("site", remote["site"])
    target.set_search_params(query)
    # A change made from the hub goes on to the install with its JSON body; reads carry none.
    write = request is not None and request.method not in ("GET", "HEAD")
    headers = {"authorization": f"Bearer {remote['token']}"}
    if write and request is not None and request.headers.get("content-type"):
        headers["content-type"] = request.headers.get("content-type") or ""
    host = Url(remote["url"]).host
    init: dict[str, Any] = {
        "method": request.method if write and request is not None else "GET",
        "headers": headers,
        # An install that answers with a redirect gets no fetch of somewhere else on its behalf.
        "redirect": "manual",
        # A long report or an export is worked out in full before the install sends a byte, so reads get two minutes.
        "timeoutMs": 30_000 if write else 120_000,
    }
    if write and request is not None:
        init["body"] = request.text()
    try:
        answer = runlight.fetcher.fetch(target.href, init)
    except Exception as error:  # noqa: BLE001
        if isinstance(error, FetchError) and error.timed_out:
            return coded(f"{host} took too long to answer. Try a shorter range.", "remote_slow", 504, {"host": host})
        return coded(f"Could not reach {host}", "unreachable", 502, {"host": host})
    # What comes back is shown from this server's origin, so it is never taken as a page:
    # JSON, or a download for exports, with sniffing off and nothing allowed to run.
    download = path == "/api/export" or (path == "/api/breakdown" and url.search_params.get("format") == "csv")
    back = {
        "cache-control": "private, no-store",
        "x-content-type-options": "nosniff",
        "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
        "content-type": ("text/csv; charset=utf-8" if (answer.headers.get("content-type") or "").startswith("text/csv") else "application/zip")
        if download
        else "application/json; charset=utf-8",
    }
    if download:
        m = re.search(r'filename="([A-Za-z0-9._-]+)"', answer.headers.get("content-disposition") or "")
        name = m.group(1) if m else "runlight-export"
        back["content-disposition"] = f'attachment; filename="{name}"'
    if 300 <= answer.status < 400:
        return coded(f"{host} answered with a redirect", "redirected", 502, {"host": host})
    # The install's own errors say what went wrong there; a refused token is this server's problem to report.
    if answer.status == 401:
        return coded(f"{host} refused the token. Connect it again from the site's settings.", "token_refused", 502, {"host": host})
    # An install's own error is shown here, so it says where it came from, keeps only short text, and
    # carries its code and params for the dashboard to put in its own words.
    if answer.status >= 400 and not download:
        try:
            text = answer.text()
        except Exception:  # noqa: BLE001
            text = ""
        body: Any = None
        if _js.length(text) <= 65_536:
            ok, value = _js.try_loads(text)
            body = value if ok else None
        params_given = _get(body, "params")
        params: list[tuple[str, str]] = []
        if _js.truthy(params_given) and _js.is_object(params_given):
            params = [(_js.slice16(k, 0, 40), _js.slice16(v, 0, 200)) for k, v in _entries(params_given) if isinstance(v, str)][:10]
        error = _get(body, "error")
        out: dict[str, Any] = {"error": f"{host}: {_js.slice16(error, 0, 300) if isinstance(error, str) else f'answered {answer.status}'}"}
        code = _get(body, "code")
        if isinstance(code, str) and re.fullmatch(r"[a-z_]{1,40}", code):
            out["code"] = code
            out["params"] = dict(params)
        return json(out, answer.status, back)
    return Response(answer.content(), answer.status, back)


def _small_page(lang: str, body: str, status: int = 200) -> Response:
    """A plain page in a visitor's language, for unsubscribing and for a share link that is gone."""
    return Response(
        f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Runlight</title>\n'
        '<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;color:#111827}main{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 20px;color:#4b5563}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}</style></head><body><main>'
        f"{body}</main></body></html>",
        status,
        {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
            "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
            "referrer-policy": "no-referrer",
        },
    )


def _accepted_language(request: Request) -> str:
    """The first language a browser asks for that the dashboard speaks, else English."""
    for part in (request.headers.get("accept-language") or "").split(","):
        code = _js.slice16(_js.trim(part.split(";")[0]), 0, 2).lower()
        if code in _languages():
            return code
    return "en"


_PATH_DIMENSIONS = {"page", "entry", "exit", "ai_page"}


def _rows_csv(rows: list[Mapping[str, Any]], sheet: Mapping[str, Any]) -> str:
    """Rows of objects as CSV, with a column for every key the first row has, in the units a spreadsheet reads."""
    from .zip import csv

    readable = [_sheet_row(r, sheet) for r in rows]
    header = list(readable[0].keys()) if readable else ["value"]
    return csv(header, [[r.get(k, _js.UNDEFINED) for k in header] for r in readable])


def _sheet_row(row: Mapping[str, Any], sheet: Mapping[str, Any]) -> dict[str, Any]:
    """One row for a spreadsheet: a bucket's start as the site's local date (and hour), rates as percents,
    durations in seconds, and paths as people write them."""
    from .sources import readable_path
    from .time import local_date, local_weekday_hour

    out: dict[str, Any] = {}
    for key, value in row.items():
        number = _js.is_number(value)
        if key == "start" and number:
            hour = f" {str(local_weekday_hour(value, sheet['timezone'])[1]).rjust(2, '0')}:00" if sheet.get("interval") == "hour" else ""
            out["date"] = f"{local_date(value, sheet['timezone'])}{hour}"
        elif key == "bounceRate" and number:
            out["bounceRatePercent"] = _js.js_round(value * 1000) / 10
        elif key in ("visitDuration", "timeOnPage") and number:
            out[f"{key}Seconds"] = _js.js_round(value / 1000)
        elif key == "value" and isinstance(value, str) and (sheet.get("dimension") or "") in _PATH_DIMENSIONS:
            out["value"] = readable_path(value)
        else:
            out[key] = value
    return out


def _download(name: str, body: str | bytes, type_: str) -> Response:
    """A file to save, never shown in the browser or kept in a shared cache."""
    # The TypeScript replaces each UTF-16 unit, so a character past the BMP becomes two dashes.
    safe = "".join(c if re.fullmatch(r"[A-Za-z0-9._-]", c) else ("--" if ord(c) > 0xFFFF else "-") for c in name)
    return Response(body, 200, {"content-type": type_, "content-disposition": f'attachment; filename="{safe}"', "cache-control": "private, no-store"})


def _constant_time_equal(a: str, b: str) -> bool:
    if _js.length(a) != _js.length(b):
        return False
    return _hmac.compare_digest(a.encode("utf-16-le", "surrogatepass"), b.encode("utf-16-le", "surrogatepass"))


def cookie_value(token: str) -> str:
    return sha256(f"runlight-cookie:{token}")


def read_cookie(request: Request, name: str) -> str:
    for part in (request.headers.get("cookie") or "").split(";"):
        key, *rest = _js.trim(part).split("=")
        if key == name:
            return "=".join(rest)
    return ""


def bearer(request: Request) -> str:
    header = request.headers.get("authorization") or ""
    return _js.trim(header[7:]) if header.lower().startswith("bearer ") else ""


def normalise_base(path: str) -> str:
    trimmed = "/" + re.sub(r"^/+|/+\Z", "", path)
    return "" if trimmed == "/" else trimmed


def _escape_attr(value: str) -> str:
    return re.sub(r'[&"<>]', lambda m: f"&#{ord(m.group(0))};", value)


def _locale_urls(base: str) -> str:
    return _js.dumps({code: f"{base}/assets/locale.{code}.{assets.LOCALES_HASH}.json" for code in assets.LOCALES})


def dashboard(
    base: str, share: str = "", sign_out: str = "", geo_credit: bool = False, accounts: bool = False, sign_in: str = "", embed: Mapping[str, str] | None = None
) -> str:
    """The dashboard's page, which holds no data: the API it calls checks access. `embed` is the dashboard inside a
    CMS's admin pages: its session (empty once its ticket was used or ran out) and the admin origin that frames it."""
    b = _escape_attr(base)
    hash_ = assets.DASHBOARD_HASH
    attributes = (
        (f' data-share="{_escape_attr(share)}"' if share else "")
        + (f' data-sign-out="{_escape_attr(sign_out)}"' if sign_out else "")
        + (f' data-sign-in="{_escape_attr(sign_in)}"' if sign_in else "")
        + (' data-geo-credit=""' if geo_credit else "")
        + (' data-accounts=""' if accounts else "")
        + (f' data-embed="{_escape_attr(embed["session"])}" data-embed-origin="{_escape_attr(embed["origin"])}"' if embed is not None else "")
    )
    return (
        '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<meta name="robots" content="noindex">\n<title>Runlight</title>\n'
        f'<link rel="icon" href="{RUNLIGHT_ICON}">\n'
        f'<link rel="stylesheet" href="{b}/assets/app.{hash_}.css">\n</head>\n<body>\n'
        f'<div id="app" data-base="{b}"{attributes} data-world="{b}/assets/world.{assets.WORLD_HASH}.json" data-locales="{_escape_attr(_locale_urls(base))}"></div>\n'
        f'<script type="module" src="{b}/assets/app.{hash_}.js"></script>\n</body>\n</html>\n'
    )


# API tokens start with this, so they are told apart from the main token.
TOKEN_PREFIX = "rl_"

# The header a shared dashboard sends its share id in.
SHARE_HEADER = "x-runlight-share"
# The header an embedded dashboard sends its session in.
EMBED_HEADER = "x-runlight-embed"
# What a share, or the dashboard inside a CMS, can read: one site's reports, nothing that changes anything.
SHARED_PATHS = {"/api/sites", "/api/icon", "/api/realtime", "/api/stats", "/api/series", "/api/rhythm", "/api/breakdown", "/api/goals", "/api/event-props", "/api/export", "/api/funnels", "/api/journeys"}


def _shared_path(path: str) -> bool:
    return path in SHARED_PATHS or bool(re.fullmatch(r"/api/goals/[a-f0-9]{24}", path))


def manage_path(method: str, path: str) -> bool:
    """What a manage token, held by a Runlight hub, may read and change: one site's goals, funnels, short links,
    link domains, email reports, and share links, along with its name, timezone, and retention, and tickets for the
    element picker. It may read which mail service sends reports, through GET /api/mail, which hides the service's
    keys. Never people, tokens, changes to the mail service, imports, or other sites."""
    if path.startswith("/api/links/import"):
        return False
    if re.match(r"/api/(links|link-domains|reports|goals|funnels|shares)(/|\Z)", path):
        return True
    if path == "/api/pick":
        return method == "POST"
    if path == "/api/mail":
        return method == "GET"
    if re.fullmatch(r"/api/sites/[^/]+", path):
        return method == "PATCH"
    return False


# Where the tracker's click rules go; the script ships with this string in their place.
RULES_PLACEHOLDER = '"__RUNLIGHT_RULES__"'
# Where the picker's one allowed receiver goes, the dashboard origin its ticket names.
PICK_TARGET_PLACEHOLDER = '"__RUNLIGHT_PICK_TARGET__"'
# Where the hostnames of the site its ticket names go, as JSON inside a string.
PICK_HOSTS_PLACEHOLDER = '"__RUNLIGHT_PICK_HOSTS__"'
# A dashboard's origin, which a picker ticket names.
_ORIGIN = re.compile(f"https?://[^/?#{_WS}]+\\Z")
# How long a picker ticket works: long enough to find the element, not to be kept.
PICK_TICKET_MS = 30 * 60_000
# Questions one person may put to the assistant in an hour, and at once.
ASK_PER_HOUR = 30
ASK_AT_ONCE = 2
# Questions each viewer may ask a day, until an owner sets another number.
VIEWER_DAILY = 50
_SHARE_ID = re.compile(r"[a-f0-9]{32}\Z")
# How long an embed ticket works: long enough for the admin page to load its frame, never to be kept.
EMBED_TICKET_MS = 5 * 60_000
# How long an embedded dashboard reads before the admin page has to be loaded again for a new ticket.
EMBED_SESSION_MS = 60 * 60_000

DASHBOARD_CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

# A line of a JavaScript `.`: anything but a line terminator.
_DOT = "[^\\n\\r\\u2028\\u2029]"

_READ_ONLY_SIGN_IN = {"id": "", "name": "", "site": "", "scope": "read", "hash": "", "hint": "", "createdAt": 0, "lastUsedAt": None}


def create_routes(runlight: Any, options: Mapping[str, Any] | None = None) -> Routes:
    return Routes(runlight, options or {})


class Routes:
    """The routes for one Runlight: `handle(request, context)` answers a request under the base path."""

    def __init__(self, runlight: Any, options: Mapping[str, Any]) -> None:
        self.rl = runlight
        self.options = options
        self.base = normalise_base(options["basePath"] if options.get("basePath") is not None else "/runlight")
        # None leaves the routes open on purpose; an unset RUNLIGHT_TOKEN is no token (""), never open.
        self.token: str | None = options["token"] if "token" in options else (env("RUNLIGHT_TOKEN") or "")
        self.cron_secret = options["cronSecret"] if options.get("cronSecret") is not None else env("CRON_SECRET")
        self.observe_key = options["observeKey"] if options.get("observeKey") is not None else env("RUNLIGHT_OBSERVE_KEY")
        self.origin = Url(options["origin"]).origin if _js.truthy(options.get("origin")) else None
        # A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
        mount = self.base or "/"
        bases = runlight.route_bases
        if hasattr(bases, "add"):
            bases.add(mount)
        elif mount not in bases:
            bases.append(mount)
        self.warned = False

        # Accounts: the standalone server passes its own, and an app turns them on with True. Sessions need a secret
        # that outlives the process; in development without one, a made-up one does, so a restart signs everyone
        # out. An app left open on purpose (token None) is treated like development here.
        token = self.token
        open_setup = token is None or (not token and _is_development())
        account_secret = runlight.secret if runlight.secret is not None else (random_id(32) if open_setup else None)
        accounts = options.get("accounts")
        self.web: Any = None
        if accounts is not None and not isinstance(accounts, bool):
            self.web = accounts
        elif accounts is True and account_secret:
            from .accounts.web import accounts_web

            web_options: dict[str, Any] = {
                "runlight": runlight,
                "secret": account_secret,
                "base": self.base,
                "now": lambda: runlight.now(),
                # The app's token proves who may make the first account; in development without one, anyone may.
                "firstAccount": {"token": token} if token else ("open" if open_setup else "locked"),
            }
            if _js.truthy(options.get("origin")):
                home = Url(options["origin"]).origin
                web_options["home"] = lambda: home
            web_options["forgot"] = "https://runlight.sh/docs/configuration/#accounts"
            self.web = accounts_web(web_options)

        # Requests from a manage token, already checked against its one site, act as the owner's.
        self.managed: weakref.WeakKeyDictionary[Request, dict[str, Any]] = weakref.WeakKeyDictionary()
        # Requests from a member: full access apart from the install-wide controls.
        self.members: weakref.WeakSet[Request] = weakref.WeakSet()
        # When each report's last sample went out.
        self.sample_sent: dict[str, int] = {}
        # Each person's questions to the assistant in the last hour, and how many are being answered now.
        self.asked: dict[str, dict[str, Any]] = {}
        # The tracker with click rules inside, rebuilt when goals change, per site.
        self.trackers: dict[str, dict[str, Any]] = {}

        web = self.web
        self.sign_in = options["signIn"] if options.get("signIn") is not None else (f"{self.base}/login" if web else None)
        self.sign_out = options["signOut"] if options.get("signOut") is not None else (f"{self.base}/logout" if web else None)
        self.account_of = options["accountOf"] if options.get("accountOf") is not None else (web.account_of if web else None)
        self.token_made = options["tokenMade"] if options.get("tokenMade") is not None else ((lambda row, by: web.token_made(row, by)) if web else None)
        authorize = options.get("authorize")
        oauth: dict[str, Any] = {
            "runlight": runlight,
            "base": self.base,
            "isOwner": lambda r: self._can_read(r) is True,
            "isReader": lambda r: (authorize(r) == "read" if authorize is not None else (web.access(r) == "read" if web else False)),
        }
        if self.sign_in:
            oauth["signIn"] = self.sign_in
        if self.account_of:
            oauth["accountOf"] = self.account_of
        if self.token_made:
            oauth["tokenMade"] = self.token_made
        self.oauth = oauth

    # Fetch-style names, as routes.ts hands them back.

    def __call__(self, request: Request, context: Mapping[str, Any] | None = None) -> Response:
        return self.handle(request, context)

    @property
    def handler(self) -> Callable[..., Response]:
        return self.handle

    GET = POST = PUT = PATCH = DELETE = OPTIONS = property(lambda self: self.handle)

    # Access.

    def _admin_only(self, path: str, method: str) -> bool:
        """The controls a member cannot change: the mail service and its keys, the assistant's settings, and deleting a site."""
        return (
            (path == "/api/mail" and method in ("PUT", "DELETE"))
            or (path == "/api/assistant" and method in ("PUT", "DELETE"))
            or (path == "/api/assistant/limits" and method == "PUT")
            or (path == "/api/assistant/models" and method == "POST")
            or (bool(re.fullmatch(r"/api/sites/[^/]+", path)) and method == "DELETE")
        )

    def _can_read(self, request: Request) -> bool | str:
        """Whether this request acts as the owner. "read" is someone signed in who may only read, such as a viewer."""
        if request in self.managed:
            return True
        authorize = self.options.get("authorize")
        if authorize is not None or self.web is not None:
            # A script's bearer token still has full access beside the sign-ins.
            given = bearer(request)
            if authorize is None and self.token and given and _constant_time_equal(given, self.token):
                return True
            answer = authorize(request) if authorize is not None else self.web.access(request)
            # A member changes things like an owner, apart from the few controls _admin_only() names.
            if answer == "member":
                self.members.add(request)
            return "read" if answer == "read" else (answer is True or answer == "member")
        if self.token is None:
            return True
        if not self.token:
            # Fails closed: only a process that says it is in development runs open.
            if not _is_development():
                return "unconfigured"
            if not self.warned:
                self.warned = True
                print(
                    "Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because NODE_ENV is development. Anywhere else it answers 503 until a token is set.",
                    file=sys.stderr,
                )
            return True
        given = bearer(request)
        if given and _constant_time_equal(given, self.token):
            return True
        cookie = read_cookie(request, COOKIE)
        return bool(cookie) and _constant_time_equal(cookie, cookie_value(self.token))

    def _api_token(self, request: Request) -> dict[str, Any] | None:
        """An API token from the bearer header: read-only, and maybe limited to one site."""
        given = bearer(request)
        if not given.startswith(TOKEN_PREFIX):
            return None
        self.rl.init()
        row = self.rl.store.token_by_hash(sha256(given))
        if not row:
            return None
        now = self.rl.now()
        # At most once a minute, so a busy assistant does not write on every call.
        if row["lastUsedAt"] is None or now - row["lastUsedAt"] > 60_000:
            self.rl.store.touch_token(row["id"], now)
        return row

    def _reader(self, request: Request) -> Any:
        """Who may read stats: the owner (True), an API token or a read-only sign-in, or nobody."""
        token = self._api_token(request)
        if token:
            # A key for the dashboard inside a CMS gets tickets and reads nothing itself.
            return False if token["scope"] == "embed" else token
        if self.options.get("authorize") is not None or self.web is not None:
            access = self._can_read(request)
            # A read-only sign-in reads like an API token for every site.
            return dict(_READ_ONLY_SIGN_IN) if access == "read" else access is True
        access = self._can_read(request)
        return False if access == "read" else access

    @staticmethod
    def _origin_needed() -> Response:
        """The refusal for a hub that asks for something only safe once this app knows its own address."""
        return coded(
            "Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.",
            "origin_needed",
            400,
        )

    @staticmethod
    def _denied(result: Any) -> Response:
        if result == "read":
            return coded("Only an owner can change this", "owner_only", 403)
        if result == "unconfigured":
            return coded("Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.", "token_unset", 503)
        return coded("Unauthorized", "unauthorized", 401)

    def _query_site(self, url: Url) -> Any:
        return self.rl.site(url.search_params.get("site")) or coded("Unknown site", "unknown_site", 404)

    def _read_query(self, url: Url, site: Mapping[str, Any]) -> Any:
        from .query import MAX_FILTERS, parse_filter
        from .time import compare_range, local_date, resolve_range

        params = url.search_params
        filters = []
        if len(params.get_all("filter")) > MAX_FILTERS:
            return coded(f"Use at most {MAX_FILTERS} filters at once.", "filters_max", 400, {"max": str(MAX_FILTERS)})
        for raw in params.get_all("filter"):
            parsed = parse_filter(raw)
            if not parsed:
                return coded(f'Bad filter "{raw}". Use dimension:is|not|contains:value.', "filter_bad", 400, {"filter": raw})
            filters.append(parsed)
        now = self.rl.now()
        first_date = None
        if params.get("period") == "all":
            first = self.rl.store.first_seen(site["id"])
            if first is not None:
                first_date = local_date(first, site["timezone"])
        range_ = resolve_range(
            {"period": params.get("period"), "from": params.get("from"), "to": params.get("to"), "interval": params.get("interval")},
            site["timezone"],
            now,
            first_date,
        )
        if not range_:
            return coded("Bad date range. Use period, or from and to as YYYY-MM-DD.", "range_bad", 400)
        query = {"site": site["id"], "from": range_["from"], "to": range_["to"], "filters": filters}
        # compare=false is the older spelling of off.
        raw = params.get("compare")
        if raw is None:
            raw = "previous"
        mode = "off" if raw == "false" else raw
        if mode not in ("previous", "year", "custom", "off"):
            return coded(f'Bad compare "{raw}". Use previous, year, custom, or off.', "compare_bad", 400, {"compare": raw})
        compared = compare_range(range_, mode, site["timezone"], {"from": params.get("compare_from"), "to": params.get("compare_to")})
        if mode == "custom" and not compared:
            return coded("Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.", "compare_range_bad", 400)
        return {"query": query, "range": range_, "compared": compared}

    @staticmethod
    def _read_json(request: Request) -> Any:
        # A form posted from another site cannot carry this content type without CORS.
        if not is_json(request):
            return coded("Send JSON", "send_json", 415)
        ok, body = _js.try_loads(request.body())
        return body if ok and isinstance(body, dict) else coded("Send a JSON object", "send_object", 400)

    # Short links and link domains.

    def _links_api(self, request: Request, path: str, url: Url) -> Response:
        from .links import LinkError
        from .safefetch import public_addresses, public_fetch, resolves_privately

        rl = self.rl
        rl.init()
        site = self._query_site(url)
        if isinstance(site, Response):
            return site
        store = rl.store
        own_domains = lambda: [d["domain"] for d in store.link_domains() if d["site"] == site["id"]]  # noqa: E731
        method = request.method
        try:
            if path == "/api/link-domains":
                if method == "GET":
                    return json({"domains": own_domains()})
                if method == "POST":
                    body = self._read_json(request)
                    if isinstance(body, Response):
                        return body
                    domain = _js.trim(_text(body, "domain")).lower()
                    domain = re.sub(r"^https?://", "", domain)
                    domain = re.sub(f"/{_DOT}*\\Z", "", domain)
                    domain = re.sub(r"\.+\Z", "", domain)
                    domain = re.sub(r"^www\.", "", domain)
                    if not DOMAIN_NAME.match(domain):
                        return coded("That is not a domain name", "domain_invalid", 400)
                    if _private_name(domain) or resolves_privately(domain):
                        return coded(f"{domain} is not a public domain name. Use one that browsers anywhere can reach.", "domain_not_public", 400, {"domain": domain})
                    # A link domain answers every path on it, so it must never be where the dashboard or a counted site
                    # lives. The request's own Host is the caller's to choose, so the configured address and the names
                    # people signed in from count too. A hub cannot know every name this app answers on, so it adds none
                    # until the app knows its own address.
                    if request in self.managed and not self.origin:
                        return self._origin_needed()
                    here = [h for h in (request.headers.get("host"), request.headers.get("x-forwarded-host"), url.host) if h]
                    own = ([Url(self.origin).host] if self.origin else []) + here
                    own_hosts = self.options.get("ownHosts")
                    if own_hosts is not None:
                        own += [str(h) for h in (own_hosts() or [])]
                    taken = {host_name(h) for h in own}
                    for s in rl.sites:
                        taken.update(s["hostnames"])
                        remote = rl.remote(s["id"])
                        taken.update(remote["hostnames"] if remote else [])
                    if domain in taken:
                        return coded(
                            f"{domain} is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go.{domain}.",
                            "domain_in_use",
                            400,
                            {"domain": domain},
                        )
                    owner = next((d for d in store.link_domains() if d["domain"] == domain), None)
                    if owner and owner["site"] != site["id"]:
                        return coded(f"{domain} already belongs to another site", "domain_taken", 409, {"domain": domain})
                    store.add_link_domain(domain, site["id"], rl.now())
                    rl.forget_link_domains()
                    return json({"domain": domain}, 201)

            check_match = re.fullmatch(r"/api/link-domains/([^/]+)/check", path)
            if check_match and method == "GET":
                domain = _decode(check_match.group(1))
                if not any(d["domain"] == domain and d["site"] == site["id"] for d in store.link_domains()):
                    return coded("Unknown domain", "unknown_domain", 404)
                # One added before names inside private networks were refused is never fetched.
                # What the check found, as a code the dashboard says in its own words, beside the English reason.
                # Where the domain should point, for the setup steps: this server's name, and its public addresses
                # for a bare domain, which takes an A record. A server reached by its address has no name to give.
                own_host = Url(self.origin).hostname if self.origin else url.hostname
                target = {"host": own_host, "addresses": public_addresses(own_host)}

                def result(code: str, reason: str, params: dict[str, str] | None = None) -> Response:
                    out: dict[str, Any] = {"domain": domain, "working": code == "", "reason": reason, "target": target}
                    if code:
                        out["code"] = code
                        if params is not None:
                            out["params"] = params
                    return json(out)

                if not DOMAIN_NAME.match(domain) or _private_name(domain):
                    return result("check_not_public", "is not a public domain name")
                try:
                    # Only a public address is fetched, whatever the name resolves to now, so the check cannot be
                    # pointed into a private network.
                    answer = public_fetch(f"https://{domain}{LINK_DOMAIN_CHECK}", {"timeoutMs": 5000}, rl.fetcher)
                    try:
                        ok, found = _js.try_loads(answer.content())
                    except Exception:  # noqa: BLE001
                        ok, found = False, None
                    found = found if ok else None
                    if answer.ok and _get(found, "runlight") is True and _get(found, "domain") == domain:
                        return result("", "")
                    if answer.ok:
                        return result("check_not_runlight", "answered, but not from Runlight")
                    return result("check_status", f"answered {answer.status}", {"status": str(answer.status)})
                except Exception as error:  # noqa: BLE001
                    # A refused private address answers as a closed port does, so the check tells nothing about a
                    # private network.
                    if isinstance(error, FetchError) and error.timed_out:
                        return result("check_timeout", "timed out")
                    return result("check_https", "could not connect over HTTPS")

            domain_match = re.fullmatch(r"/api/link-domains/([^/]+)", path)
            if domain_match and method == "DELETE":
                domain = _decode(domain_match.group(1))
                if not any(d["domain"] == domain and d["site"] == site["id"] for d in store.link_domains()):
                    return coded("Unknown domain", "unknown_domain", 404)
                store.remove_link_domain(domain)
                rl.forget_link_domains()
                return json({"ok": True})

            if path == "/api/links":
                if method == "GET":
                    read = self._read_query(url, site)
                    if isinstance(read, Response):
                        return read
                    links = store.links(site["id"], read["range"]["from"], read["range"]["to"])
                    # Links on a removed domain are served from the app's own path until it is added back.
                    return json({"prefix": f"{url.origin}{rl.link_path}", "domains": own_domains(), "links": links})
                if method == "POST":
                    body = self._read_json(request)
                    if isinstance(body, Response):
                        return body
                    given: dict[str, Any] = {"url": _text(body, "url")}
                    for key in ("name", "slug", "domain"):
                        if _defined(body, key):
                            given[key] = _js.string(body[key])
                    link = rl.links.create(site["id"], given)
                    return json({"link": link}, 201)

            # One step of an import from another shortener; the page calls again with the cursor.
            import_match = re.fullmatch(r"/api/links/import/([a-z]+)", path)
            if import_match and method == "POST":
                from .importers import ImportError as ImporterError
                from .importers import import_step

                body = self._read_json(request)
                if isinstance(body, Response):
                    return body
                cursor = _get(body, "cursor")
                done = _js.number(_get(body, "done"))
                try:
                    step = import_step(
                        rl,
                        site["id"],
                        import_match.group(1),
                        _credentials(_get(body, "credentials")),
                        cursor if isinstance(cursor, str) else None,
                        done if _js.truthy(done) else 0,
                    )
                    return json(step)
                except ImporterError as error:
                    return _refused(error, "import_failed")

            if path == "/api/links/import" and method == "POST":
                body = self._read_json(request)
                if isinstance(body, Response):
                    return body
                # Rows that are not objects (null, a number) are dropped rather than failing the import.
                given_rows = _get(body, "rows")
                if not isinstance(given_rows, list):
                    return coded("Send rows as a list", "rows_needed", 400)
                rows = [row for row in given_rows if isinstance(row, dict)][:5000]
                return json(rl.links.import_(site["id"], rows))

            link_match = re.fullmatch(r"/api/links/([a-f0-9]+)", path)
            if link_match:
                from .query import is_session_dimension
                from .time import buckets

                id_ = link_match.group(1)
                if method == "GET":
                    link = store.link_by_id(id_)
                    if not link or link["site"] != site["id"]:
                        return coded("Unknown link", "unknown_link", 404)
                    read = self._read_query(url, site)
                    if isinstance(read, Response):
                        return read
                    range_ = read["range"]

                    def by(dimension: str) -> list[Any]:
                        if is_session_dimension(dimension):
                            return store.link_breakdown(site["id"], id_, range_["from"], range_["to"], dimension, 10)
                        return []

                    series = store.link_series(site["id"], id_, buckets(range_, site["timezone"]))
                    clicks = sum(p["clicks"] for p in series)
                    return json(
                        {
                            "link": link,
                            "range": {"from": range_["fromDate"], "to": range_["toDate"], "interval": range_["interval"], "timezone": site["timezone"]},
                            "clicks": clicks,
                            "series": series,
                            "sources": by("source"),
                            "referrers": by("referrer"),
                            "countries": by("country"),
                            "devices": by("device"),
                            "browsers": by("browser"),
                        }
                    )
                owned = store.link_by_id(id_)
                if not owned or owned["site"] != site["id"]:
                    return coded("Unknown link", "unknown_link", 404)
                if method == "PATCH":
                    body = self._read_json(request)
                    if isinstance(body, Response):
                        return body
                    patch = {key: _js.string(body[key]) for key in ("url", "name", "slug", "domain") if _defined(body, key)}
                    return json({"link": rl.links.update(id_, patch)})
                if method == "DELETE":
                    rl.links.remove(id_)
                    return json({"ok": True})
        except LinkError as error:
            return coded(_message(error), error.code, 400, getattr(error, "params", None))
        except _js.RangeError as error:
            return coded(_message(error), "unknown_link", 404)
        return coded("Not found", "not_found", 404)

    # The tracker and the element picker.

    def _pick_key(self) -> str:
        """The key picker tickets are signed with, made on first use and kept in the database for every process."""
        self.rl.init()
        saved = self.rl.store.setting("pick-key")
        if saved:
            return saved
        made = random_id(32)
        self.rl.store.set_setting("pick-key", made)
        return made

    def _pick_ticket(self, origin: str, site: str) -> str:
        """A ticket that lets the picker, on `site`'s pages, send its choice to `origin`, the dashboard that asked,
        for half an hour."""
        payload = f"{self.rl.now() + PICK_TICKET_MS}.{_js.encode(site).hex()}.{_js.encode(origin).hex()}"
        return f"{payload}.{hmac(self._pick_key(), payload)}"

    def _pick_target(self, ticket: str) -> dict[str, str] | None:
        """The dashboard origin and site a picker ticket names, or None when it is not one this install signed or has
        run out."""
        parts = re.fullmatch(r"([0-9]+)\.([a-f0-9]{2,512})\.([a-f0-9]{2,512})\.([a-f0-9]{64})", ticket)
        if not parts or _js.number(parts.group(1)) < self.rl.now():
            return None
        if not _constant_time_equal(parts.group(4), hmac(self._pick_key(), f"{parts.group(1)}.{parts.group(2)}.{parts.group(3)}")):
            return None

        def unhex(text: str) -> str:
            return _js.utf8(bytes.fromhex(text[: len(text) - len(text) % 2]))

        origin = unhex(parts.group(3))
        return {"origin": origin, "site": unhex(parts.group(2))} if _ORIGIN.match(origin) else None

    def _embed_key(self) -> str:
        """The key embed tickets and sessions are signed with, made on first use and kept in the database for every
        process."""
        self.rl.init()
        saved = self.rl.store.setting("embed-key")
        if saved:
            return saved
        made = random_id(32)
        self.rl.store.set_setting("embed-key", made)
        return made

    def _embed_token(self, id_: str) -> dict[str, Any] | None:
        """An embed token that still exists, for a site that still does."""
        token = next((t for t in self.rl.store.tokens() if t["id"] == id_), None)
        return token if token and token["scope"] == "embed" and self.rl.site(token["site"]) else None

    def _embed_ticket(self, origin: str, token: str) -> dict[str, Any]:
        """A ticket for one load of the embedded dashboard, signed with when it runs out, a nonce, and the admin
        origin that may frame it. The nonce is kept, with the token it was made for, until the ticket is used."""
        store = self.rl.store
        now = self.rl.now()
        # Tickets nobody used are cleared as new ones are made.
        for row in store.settings_starting_with("embed-ticket:"):
            if _js.number(row["value"].split(".")[0]) < now:
                store.set_setting(row["key"], None)
        expires_at = now + EMBED_TICKET_MS
        nonce = random_id(16)
        store.set_setting(f"embed-ticket:{nonce}", f"{expires_at}.{token}")
        payload = f"{expires_at}.{nonce}.{_js.encode(origin).hex()}"
        return {"ticket": f"{payload}.{hmac(self._embed_key(), f'ticket.{payload}')}", "expiresAt": expires_at}

    def _redeem_embed(self, ticket: str) -> dict[str, Any] | None:
        """What a ticket this install signed names: always its origin, and its token only the first time it is used
        before it runs out. None for anything else."""
        parts = re.fullmatch(r"([0-9]{1,15})\.([a-f0-9]{32})\.([a-f0-9]{2,512})\.([a-f0-9]{64})", ticket)
        if not parts:
            return None
        if not _constant_time_equal(parts.group(4), hmac(self._embed_key(), f"ticket.{parts.group(1)}.{parts.group(2)}.{parts.group(3)}")):
            return None
        text = parts.group(3)
        origin = _js.utf8(bytes.fromhex(text[: len(text) - len(text) % 2]))
        if not _ORIGIN.match(origin):
            return None
        # A ticket works once: it is gone before anything else is checked.
        kept = self.rl.store.take_setting(f"embed-ticket:{parts.group(2)}")
        pieces = kept.split(".") if kept else []
        token = self._embed_token(pieces[1] if len(pieces) > 1 else "") if kept and _js.number(parts.group(1)) >= self.rl.now() else None
        return {"origin": origin, "token": token}

    def _embed_session(self, token: str) -> str:
        """A session for an embedded dashboard, which its page sends with every read, signed with when it runs out
        and its token."""
        payload = f"{self.rl.now() + EMBED_SESSION_MS}.{token}"
        return f"{payload}.{hmac(self._embed_key(), f'session.{payload}')}"

    def _embed_reader(self, session: str) -> dict[str, Any] | None:
        """The embed token a session this install signed was made for, while it lasts and the token still exists."""
        parts = re.fullmatch(r"([0-9]{1,15})\.([a-f0-9]{24})\.([a-f0-9]{64})", session)
        if not parts or _js.number(parts.group(1)) < self.rl.now():
            return None
        if not _constant_time_equal(parts.group(3), hmac(self._embed_key(), f"session.{parts.group(1)}.{parts.group(2)}")):
            return None
        return self._embed_token(parts.group(2))

    def _tracker_script(self, site_id: str | None) -> dict[str, Any]:
        """The tracker with click rules inside, rebuilt when goals change. With ?site= it carries only that site's
        rules, so one site's visitors never see another site's domains or goals. The standalone server's snippet
        always names the site; without a name it serves no rules, and an app's own install, whose sites all belong
        to one owner, serves every site's."""
        from .goals import click_rules

        key = site_id if site_id is not None else ""
        cached = self.trackers.get(key)
        if cached and self.rl.now() - cached["at"] < 60_000:
            return cached
        self.rl.init()
        if site_id is not None:
            sites = [s for s in self.rl.sites if s["id"] == site_id]
        else:
            sites = [] if self.rl.managed_sites else self.rl.sites
        rules = _js.dumps(click_rules(sites, self.rl.store.goals()))
        # Replaced once, as a plain string, so "$'" or "$&" in a selector is never read as a pattern.
        body = assets.TRACKER.replace(RULES_PLACEHOLDER, rules, 1)
        script = {"body": body, "etag": f'"{assets.TRACKER_HASH}-{sha256(rules)[:8]}"', "at": self.rl.now()}
        # One entry per site at most; a query naming no real site gets the empty script without filling the map.
        if site_id is None or sites:
            self.trackers[key] = script
        return script

    def _goal_writes(self, request: Request, path: str, url: Url) -> Response:
        from .goals import GoalError, goal_from

        rl = self.rl
        rl.init()
        site = self._query_site(url)
        if isinstance(site, Response):
            return site
        existing = rl.store.goals(site["id"])
        id_ = None if path == "/api/goals" else _decode(path[len("/api/goals/") :])
        before = next((g for g in existing if g["id"] == id_), None)
        if id_ is not None and before is None:
            return coded("Unknown goal", "unknown_goal", 404)
        self.trackers.clear()
        if request.method == "DELETE":
            rl.store.delete_goal(id_)
            return json({"ok": True})
        body = self._read_json(request)
        if isinstance(body, Response):
            return body
        try:
            goal = goal_from(body, site["id"], existing, rl.now(), id_)
            rl.store.save_goal(goal, before)
            return json({"goal": goal}, 200 if id_ else 201)
        except GoalError as error:
            return _refused(error, "goal_invalid")

    # Mail and email reports.

    @staticmethod
    def _report_view(r: Mapping[str, Any]) -> dict[str, Any]:
        return {"id": r["id"], "site": r["site"], "email": r["email"], "frequency": r["frequency"], "lang": r["lang"], "lastSentAt": r["lastSentAt"], "createdAt": r["createdAt"]}

    def _mail_api(self, request: Request, path: str, url: Url) -> Response:
        from .mail.transports import SERVICES, MailError

        rl = self.rl
        method = request.method
        rl.init()
        try:
            if path == "/api/mail":
                if method == "GET":
                    settings = rl.mail_settings()
                    service = next((x for x in SERVICES if settings and x["id"] == settings.get("service")), None)
                    # Secret fields come back only as "saved", never as their value.
                    fields: dict[str, str] = {}
                    saved: list[str] = []
                    for f in (service or {}).get("fields", []):
                        if f.get("secret"):
                            if settings and _js.truthy(settings.get(f["name"])):
                                saved.append(f["name"])
                        else:
                            value = settings.get(f["name"]) if settings else None
                            fields[f["name"]] = "" if value is None else _js.string(value)
                    # A hub with a manage token learns which service sends the reports and from where, nothing more.
                    via_manage = request in self.managed
                    return json(
                        {
                            "source": _or(settings, "source", None),
                            "service": _or(settings, "service", ""),
                            "from": _or(settings, "from", ""),
                            "fromName": _or(settings, "fromName", ""),
                            "fields": {} if via_manage else fields,
                            "saved": [] if via_manage else saved,
                            "encrypted": rl.secret is not None,
                            "services": SERVICES,
                        }
                    )
                if method == "PUT":
                    body = self._read_json(request)
                    if isinstance(body, Response):
                        return body
                    rl.save_mail_settings(body)
                    return json({"ok": True})
                if method == "DELETE":
                    rl.save_mail_settings(None)
                    return json({"ok": True})
                return coded("Method not allowed", "method_not_allowed", 405)

            if path == "/api/mail/test" and method == "POST":
                body = self._read_json(request)
                if isinstance(body, Response):
                    return body
                to = _js.trim(_text(body, "to"))
                if not _is_email(to):
                    return coded("Enter an email address to send the test to", "test_email", 400)
                settings = rl.mail_settings()
                if not settings:
                    return coded("Set up a mail service first", "mail_unset", 400)
                t, _ = _translator(_text(body, "lang", "en"))
                name = next((x["name"] for x in SERVICES if x["id"] == settings.get("service")), "")
                rl.send_mail(
                    {
                        "to": to,
                        "subject": t("email.test.subject"),
                        "text": t("email.test.body", {"service": name}),
                        "html": f'<p style="font-family:sans-serif;font-size:15px">{escape_html(t("email.test.body", {"service": name}))}</p>',
                    }
                )
                return json({"ok": True})

            site = self._query_site(url)
            if isinstance(site, Response):
                return site

            if path == "/api/reports":
                if method == "GET":
                    return json({"reports": [self._report_view(r) for r in rl.store.reports(site["id"])], "languages": _languages()})
                if method == "POST":
                    from .reports import last_period

                    body = self._read_json(request)
                    if isinstance(body, Response):
                        return body
                    email = _js.trim(_text(body, "email")).lower()
                    if not _is_email(email):
                        return coded("Enter an email address", "email_invalid", 400)
                    frequency = "monthly" if _get(body, "frequency") == "monthly" else "weekly"
                    existing = rl.store.reports(site["id"])
                    if any(r["email"] == email and r["frequency"] == frequency for r in existing):
                        return coded(f"{email} already gets the {frequency} report", "report_exists", 400, {"email": email})
                    if len(existing) >= 50:
                        return coded("A site can send to at most 50 addresses", "report_limit", 400)
                    # Links in the email point back to the configured address, or else to this dashboard as the
                    # browser sees it. A report made from a hub needs the configured address, where its unsubscribe
                    # link answers, since the Host its request names is the hub's to choose.
                    if request in self.managed and not self.origin:
                        return self._origin_needed()
                    given = "" if self.origin else _text(body, "origin")
                    if re.match(f"https?://[^{_WS}]+\\Z", given):
                        home = re.sub(r"/+\Z", "", given)
                    else:
                        home = f"{self.origin or url.origin}{self.base}"
                    # A period already due counts as sent, so a report added mid-week first goes out on the next
                    # Monday, as the form says.
                    due = last_period(frequency, rl.now(), site["timezone"])
                    lang = _js.string(_get(body, "lang"))
                    report = {
                        "id": random_id(),
                        "site": site["id"],
                        "email": email,
                        "frequency": frequency,
                        "lang": lang if lang in _languages() else "en",
                        "token": random_id(16),
                        "origin": home,
                        "lastPeriod": due["key"] if rl.now() >= due["dueAt"] else "",
                        "lastSentAt": None,
                        "createdAt": rl.now(),
                    }
                    rl.store.insert_report(report)
                    return json({"report": self._report_view(report)}, 201)
                return coded("Method not allowed", "method_not_allowed", 405)

            match = re.fullmatch(r"/api/reports/([a-f0-9]{24})(/send)?", path)
            report = rl.store.report_by("id", match.group(1)) if match else None
            if not report or report["site"] != site["id"]:
                return coded("Unknown report", "unknown_report", 404)
            assert match is not None
            if match.group(2) and method == "POST":
                # A sample at most once a minute per report, so the send button cannot be used to flood an inbox. A
                # hub sends one every ten minutes for the whole site, so adding reports again does not start a new count.
                via_hub = request in self.managed
                key = f"site:{site['id']}" if via_hub else report["id"]
                wait = 600_000 if via_hub else 60_000
                last = self.sample_sent.get(key, 0)
                if rl.now() - last < wait:
                    if via_hub:
                        return coded("A connected hub can send one sample every ten minutes. Wait a few minutes and try again.", "sample_soon_hub", 429)
                    return coded("A sample went out a moment ago. Wait a minute and try again.", "sample_soon", 429)
                self.sample_sent[key] = rl.now()
                rl.deliver_report(report, site)
                return json({"ok": True})
            if not match.group(2) and method == "DELETE":
                rl.store.delete_report(report["id"])
                return json({"ok": True})
            return coded("Method not allowed", "method_not_allowed", 405)
        except MailError as error:
            return coded(_message(error), error.code, 400, getattr(error, "params", None))

    def _unsubscribe_page(self, request: Request, token: str) -> Response:
        """A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing."""
        rl = self.rl
        rl.init()
        report = rl.store.report_by("token", token) if re.fullmatch(r"[a-f0-9]{32}", token) else None
        site = rl.site(report["site"]) if report else None
        t, lang = _translator(report["lang"] if report else "en")

        def page(body: str, status: int = 200) -> Response:
            return _small_page(lang, body, status)

        if not report or not site:
            return page(f"<h1>{escape_html(t('email.unsub.goneTitle'))}</h1><p>{escape_html(t('email.unsub.gone'))}</p>", 404)
        if request.method == "POST":
            rl.store.delete_report(report["id"])
            return page(f"<h1>{escape_html(t('email.unsub.doneTitle'))}</h1><p>{escape_html(t('email.unsub.done', {'site': site['name'], 'email': report['email']}))}</p>")
        return page(
            f"<h1>{escape_html(t('email.unsub.title', {'site': site['name']}))}</h1><p>{escape_html(t('email.unsub.body', {'email': report['email']}))}</p>"
            f'<form method="post"><button type="submit">{escape_html(t("email.unsubscribe"))}</button></form>'
        )

    # Share links.

    def _shares_api(self, request: Request, path: str, url: Url) -> Response:
        rl = self.rl
        rl.init()
        site = self._query_site(url)
        if isinstance(site, Response):
            return site

        def view(share: Mapping[str, Any]) -> dict[str, Any]:
            return {**share, "path": f"{self.base}/share/{share['id']}"}

        if path == "/api/shares":
            if request.method == "GET":
                return json({"shares": [view(s) for s in rl.store.shares(site["id"])]})
            if request.method == "POST":
                body = self._read_json(request)
                if isinstance(body, Response):
                    return body
                share = {"id": random_id(16), "site": site["id"], "name": _js.slice16(_js.trim(_text(body, "name")), 0, 100), "createdAt": rl.now()}
                rl.store.insert_share(share)
                return json({"share": view(share)}, 201)
            return coded("Method not allowed", "method_not_allowed", 405)

        id_ = _decode(path[len("/api/shares/") :])
        share = rl.store.share_by_id(id_) if _SHARE_ID.match(id_) else None
        if not share or share["site"] != site["id"]:
            return coded("Unknown share", "unknown_share", 404)
        if request.method == "PATCH":
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            name = _js.slice16(_js.trim(_text(body, "name")), 0, 100)
            rl.store.rename_share(share["id"], name)
            return json({"share": view({**share, "name": name})})
        if request.method == "DELETE":
            rl.store.delete_share(share["id"])
            return json({"ok": True})
        return coded("Method not allowed", "method_not_allowed", 405)

    # The assistant.

    def _viewer_daily(self) -> Any:
        """How many questions each viewer may ask the assistant a day, as an owner set it."""
        saved = self.rl.store.setting("assistant-viewer-daily")
        return VIEWER_DAILY if saved is None else _js.number(saved)

    def _ask_turn(self, who: str, owner: bool) -> Response | Callable[[], None]:
        """Counts a question to the assistant, which spends the owner's AI credit, or refuses it: past thirty an hour
        or two at once for anyone, and past the owner's daily number for a viewer. Returns how to finish."""
        now = self.rl.now()
        mine = self.asked.get(who) or {"at": [], "open": 0}
        mine["at"] = [at for at in mine["at"] if now - at < 3_600_000]
        if len(mine["at"]) >= ASK_PER_HOUR or mine["open"] >= ASK_AT_ONCE:
            return coded("You have asked a lot in a short time. Wait a little and ask again.", "assistant_soon", 429)
        if not owner:
            store = self.rl.store
            limit = self._viewer_daily()
            day = f"assistant-asked:{datetime.fromtimestamp(now / 1000, timezone.utc).strftime('%Y-%m-%d')}"
            counts = _js.loads(store.setting(day) or "{}")
            if counts.get(who, 0) >= limit:
                return coded(f"Viewers can ask {_js.string(limit)} questions a day. Ask again tomorrow.", "assistant_daily", 429, {"limit": _js.string(limit)})
            counts[who] = counts.get(who, 0) + 1
            store.set_setting(day, _js.dumps(counts))
            for entry in store.settings_starting_with("assistant-asked:"):
                if entry["key"] != day:
                    store.set_setting(entry["key"], None)
        mine["at"].append(now)
        mine["open"] += 1
        self.asked[who] = mine
        # People who stopped asking are dropped, so the map holds only the last hour's.
        if len(self.asked) > 1000:
            for key, value in list(self.asked.items()):
                if not value["open"] and not any(now - at < 3_600_000 for at in value["at"]):
                    del self.asked[key]

        def finish() -> None:
            mine["open"] -= 1

        return finish

    # API tokens.

    def _tokens_api(self, request: Request, path: str) -> Response:
        rl = self.rl
        rl.init()

        def view(t: Mapping[str, Any]) -> dict[str, Any]:
            return {"id": t["id"], "name": t["name"], "site": t["site"], "scope": t["scope"], "hint": t["hint"], "createdAt": t["createdAt"], "lastUsedAt": t["lastUsedAt"]}

        if path == "/api/tokens" and request.method == "GET":
            return json({"tokens": [view(t) for t in rl.store.tokens()]})
        if path == "/api/tokens" and request.method == "POST":
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            name = _js.slice16(_js.trim(_text(body, "name")), 0, 100)
            if not name:
                return coded("Name the token", "token_name", 400)
            site = _text(body, "site")
            if site and not any(s["id"] == site for s in rl.sites):
                return coded("Unknown site", "unknown_site", 404)
            asked_scope = _get(body, "scope")
            scope = asked_scope if asked_scope in ("manage", "embed") else "read"
            if scope == "manage" and not site:
                return coded("A token that changes settings is for one site. Pick the site.", "token_site", 400)
            if scope == "embed" and not site:
                return coded("A key for the dashboard in a CMS is for one site. Pick the site.", "embed_site", 400)
            secret = f"{TOKEN_PREFIX}{random_id(20)}"
            row = {"id": random_id(), "name": name, "site": site, "scope": scope, "hash": sha256(secret), "hint": secret[-4:], "createdAt": rl.now(), "lastUsedAt": None}
            rl.store.insert_token(row)
            by = self.account_of(request) if self.account_of else None
            if by and self.token_made and not self.token_made(row, by):
                rl.store.delete_token(row["id"])
                return self._denied("read")
            # The only time the token is ever shown.
            return json({"token": view(row), "secret": secret}, 201)
        match = re.fullmatch(r"/api/tokens/([a-f0-9]{24})", path)
        if match and request.method == "DELETE":
            return json({"ok": True}) if rl.store.delete_token(match.group(1)) else coded("Unknown token", "unknown_token", 404)
        return coded("Not found", "not_found", 404)

    def _read_api(self, request: Request, url: Url, default_site: str | None = None) -> Callable[[str, list[tuple[str, str]]], Response]:
        """Reads one API path with the asker's own headers, as the MCP server and the assistant's tools do."""
        headers = Headers(request.headers)
        for name in ("content-type", "content-length", SHARE_HEADER, EMBED_HEADER):
            headers.delete(name)

        def read(api_path: str, params: Any) -> Response:
            target = Url(f"{self.base}{api_path}", url.origin)
            query = target.search_params
            for key, value in params:
                query.append(str(key), str(value))
            # A tool that names no site reads the one on screen, not the install's first.
            if default_site is not None and api_path != "/api/sites" and not query.has("site"):
                query.set("site", default_site)
            target.set_search_params(query)
            return self._api(Request(target.href, "GET", headers), api_path, target)

        return read

    # The API.

    def _api(self, request: Request, path: str, url: Url) -> Response:
        rl = self.rl
        method = request.method
        # An embedded dashboard reads what a share link shows and nothing else, whoever else the request comes from.
        if request.headers.get(EMBED_HEADER) is not None and not (method == "GET" and _shared_path(path)):
            return coded("Not available on a shared dashboard", "share_not_available", 403)
        # A write must be JSON, which a form on another page cannot send, even the writes that carry no body.
        # That holds without a cookie too, since a browser also sends Basic credentials or comes from an
        # allowed address on its own. A bearer token is never sent by the browser on its own, so it needs no check.
        if method not in ("GET", "HEAD", "OPTIONS", "DELETE") and not bearer(request) and not is_json(request):
            return coded("Send JSON", "send_json", 415)
        if path == "/api" and method == "GET":
            from .version import API_VERSION, VERSION

            return json({"name": "runlight", "version": VERSION, "api": API_VERSION, **IMPLEMENTATION})

        # A hub asks what its token may do before offering to change anything.
        if path == "/api/token" and method == "GET":
            token = self._api_token(request)
            if not token:
                return self._denied(False)
            return json({"scope": token["scope"], "site": token["site"]})
        # A token can delete itself, which a hub does when it disconnects a site or gets a new token.
        if path == "/api/token" and method == "DELETE":
            token = self._api_token(request)
            if not token:
                return self._denied(False)
            rl.store.delete_token(token["id"])
            return json({"ok": True})

        # Connecting another Runlight through its consent page, so nobody copies a token.
        if path == "/api/sites/connect" and method == "POST":
            from .connect import ConnectError, start_connect

            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            rl.init()
            if not rl.managed_sites:
                return coded("Sites are set in code", "sites_in_code", 400)
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            site = _get(body, "site")
            given = _get(body, "url")
            try:
                return json({"authorize": start_connect(rl, None if given is _js.UNDEFINED else given, f"{url.origin}{self.base}/api/sites/connect/done", site if isinstance(site, str) else "")})
            except ConnectError as error:
                return coded(_message(error), "unreachable" if error.code == "unreachable" else f"connect_{error.code}", 400, getattr(error, "params", None))
            except _js.RangeError as error:
                return _refused(error, "connect_failed")
        if path == "/api/sites/connect/done" and method == "GET":
            from .connect import ConnectError, finish_connect

            home = self.base or "/"
            access = self._can_read(request)
            if access is not True:
                return Response(b"", 303, {"location": home, "cache-control": "no-store"})
            rl.init()
            try:
                id_ = finish_connect(rl, url.search_params)
                # The site's settings open with a word that the connection worked, which a reconnection otherwise lacks.
                to = f"{home}?site={_js.encode_uri_component(id_)}&settings=general&connected=1"
            except _js.RangeError as error:
                # A code, never the message: the dashboard shows its own words for it, so a link cannot put text there.
                to = f"{home}?connect_error={error.code if isinstance(error, ConnectError) else 'failed'}"
            return Response(b"", 303, {"location": to, "cache-control": "no-store"})

        # A ticket for one load of the dashboard inside a CMS's admin pages. The plugin's server asks with its embed
        # token on each page view and names the admin's origin, which must be one of the site's domains and alone
        # may frame the page the ticket opens.
        if path == "/api/embed" and method == "POST":
            token = self._api_token(request)
            if not token:
                return self._denied(False)
            if token["scope"] != "embed":
                return coded("Use a key for the dashboard in a CMS, made in Settings, Install", "embed_token", 403)
            site = rl.site(token["site"])
            if not site:
                return coded("Unknown site", "unknown_site", 404)
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            origin = _text(body, "origin")
            parsed = Url(origin) if _ORIGIN.match(origin) and _js.length(origin) <= 200 and Url.can_parse(origin) else None
            if parsed is None or parsed.origin != origin:
                return coded("Send the admin page's origin, such as https://example.com", "embed_origin", 400)
            host = host_name(parsed.host)
            remote = rl.remote(site["id"])
            if host not in [host_name(h) for h in (remote["hostnames"] if remote else site["hostnames"])]:
                return coded(f"{host} is not one of this site's domains. Add it to the site's domains in Runlight's settings.", "embed_host", 400, {"host": host})
            made = self._embed_ticket(origin, token["id"])
            return json({"ticket": made["ticket"], "site": site["id"], "expiresAt": made["expiresAt"], "path": f"{self.base}/embed?ticket={made['ticket']}"}, 201)

        token = self._api_token(request) if bearer(request).startswith(TOKEN_PREFIX) else None
        # An embed token gets tickets and reads nothing itself.
        if token and token["scope"] == "embed":
            return coded("This key only opens the dashboard inside a CMS", "token_embed_only", 403)
        if token and token["scope"] == "manage" and manage_path(method, path):
            asked = url.search_params.get("site")
            site_match = re.fullmatch(r"/api/sites/([^/]+)", path)
            if (asked and asked != token["site"]) or (site_match and _decode(site_match.group(1)) != token["site"]):
                return coded("Unknown site", "unknown_site", 404)
            if site_match and is_json(request):
                # Where a site lives stays with its owner: a hub may rename it, never move it.
                ok, body = _js.try_loads(request.body())
                if ok and isinstance(body, dict) and "hostnames" in body:
                    return coded("A connected hub cannot change a site's domains", "hub_domains", 403)
            url = url.copy()
            query = url.search_params
            query.set("site", token["site"])
            url.set_search_params(query)
            self.managed[request] = token
        # A token this install made that tries a change it may not make is known, just not allowed, as for a viewer.
        if token and request not in self.managed and method not in ("GET", "HEAD", "OPTIONS"):
            if token["scope"] == "manage":
                return coded("A manage token changes only its own site's settings", "token_manage_only", 403)
            return coded("API tokens can only read", "token_read_only", 403)

        # A page another site served to an AI agent, reported by a CMS plugin.
        if path == "/api/observe" and method == "POST":
            return self._observe(request)

        # GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
        if path == "/api/check" and method in ("POST", "GET"):
            given = bearer(request)
            allowed = bool(self.cron_secret and given and _constant_time_equal(given, self.cron_secret)) or self._can_read(request) is True
            if not allowed:
                return coded("Unauthorized", "unauthorized", 401)
            return json(rl.check())

        # A site counted by another install is read there. Its settings change there too,
        # through this server when the install gave a manage token, and only by an owner here.
        asked = url.search_params.get("site")
        connected = rl.remote(asked) if asked else None
        if connected and connected.get("scope") == "manage" and manage_path(method, path) and not (method == "GET" and _shared_path(path)):
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            if method != "GET":
                rl.forget_remote_info(asked)
            return _pass_through(rl, connected, path, url, request)
        if connected and not (method == "GET" and (_shared_path(path) or path == "/api/links")):
            return coded("This site is counted by its own Runlight. Connect it again from its settings to change it from here.", "site_remote", 400)

        # Visit history from Umami: list the account's websites, then import one a step at a time.
        if path in ("/api/import/umami/websites", "/api/import/umami/visits") and method == "POST":
            from .importers import ImportError as ImporterError
            from .importers.visits import import_umami_visits, umami_websites

            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            credentials = _credentials(_get(body, "credentials"))
            try:
                if path == "/api/import/umami/websites":
                    return json({"websites": umami_websites(credentials, rl.fetcher)})
                rl.init()
                site = self._query_site(url)
                if isinstance(site, Response):
                    return site
                cursor = _get(body, "cursor")
                return json(import_umami_visits(rl, site["id"], credentials, _text(body, "website"), cursor if isinstance(cursor, str) else None))
            except ImporterError as error:
                return _refused(error, "import_failed")

        # Visit history from a CSV file, a batch at a time.
        if path == "/api/import/csv/visits" and method == "POST":
            from .importers import ImportError as ImporterError
            from .importers.visits import import_csv_visits

            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            rl.init()
            site = self._query_site(url)
            if isinstance(site, Response):
                return site
            try:
                return json(import_csv_visits(rl, site["id"], _get(body, "rows")))
            except ImporterError as error:
                return _refused(error, "import_failed")

        # Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on request.
        if (path == "/api/observe-key" and method == "GET") or (path == "/api/observe-key/new" and method == "POST"):
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            rl.init()
            site = self._query_site(url)
            if isinstance(site, Response):
                return site
            name = f"observe-key:{site['id']}"
            key = None if path.endswith("/new") else rl.store.setting(name)
            if not key:
                key = f"rlo_{random_id(20)}"
                rl.store.set_setting(name, key)
            return json({"key": key})

        # Making, changing, and deleting funnels; reading them is with the other reports.
        if (path == "/api/funnels" and method == "POST") or (re.fullmatch(r"/api/funnels/[a-f0-9]{24}", path) and method in ("PATCH", "DELETE")):
            from .funnels import FunnelError, funnel_from

            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            rl.init()
            site = self._query_site(url)
            if isinstance(site, Response):
                return site
            existing = rl.store.funnels(site["id"])
            id_ = None if path == "/api/funnels" else path[len("/api/funnels/") :]
            if id_ is not None and not any(f["id"] == id_ for f in existing):
                return coded("Unknown funnel", "unknown_funnel", 404)
            if method == "DELETE":
                rl.store.delete_funnel(id_)
                return json({"ok": True})
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            try:
                funnel = funnel_from(body, site["id"], existing, rl.now(), id_)
                rl.store.save_funnel(funnel)
                return json({"funnel": funnel}, 200 if id_ else 201)
            except FunnelError as error:
                return _refused(error, "funnel_invalid")

        # The assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
        if path == "/api/assistant":
            from .assistant import PROVIDERS

            self_ = self._can_read(request)
            # A member uses the assistant like anyone else, but its settings are for owners and admins.
            owner = self_ is True and request not in self.members
            if method == "GET":
                access = self._reader(request)
                if access is False or access == "unconfigured":
                    return self._denied(access)
                # Only people at the dashboard, never an API token or a share, so nobody spends the owner's AI credit
                # from outside.
                if isinstance(access, dict) and access["id"]:
                    return coded("Only the dashboard can use the assistant", "assistant_dashboard", 403)
                rl.init()
                settings = rl.assistant_settings()
                if not owner:
                    return json({"configured": bool(settings)})
                return json(
                    {
                        "configured": bool(settings),
                        "viewerDaily": self._viewer_daily(),
                        "provider": _or(settings, "provider", ""),
                        "model": _or(settings, "model", ""),
                        "baseUrl": _or(settings, "baseUrl", ""),
                        "keySaved": _js.truthy((settings or {}).get("key")),
                        "encrypted": rl.secret is not None,
                        "providers": PROVIDERS,
                    }
                )
            if not owner:
                return coded("Only an owner or admin can change this", "admin_only", 403) if self_ is True else self._denied(self_)
            rl.init()
            if method == "DELETE":
                rl.save_assistant_settings(None)
                return json({"ok": True})
            if method == "PUT":
                body = self._read_json(request)
                if isinstance(body, Response):
                    return body
                try:
                    rl.save_assistant_settings(body)
                    return json({"ok": True})
                except _js.RangeError as error:
                    return _refused(error, "assistant_invalid")
            return coded("Method not allowed", "method_not_allowed", 405)
        # How many questions each viewer may ask a day; 0 keeps the assistant for owners.
        if path == "/api/assistant/limits" and method == "PUT":
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            rl.init()
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            daily = _js.number(_get(body, "viewerDaily"))
            if not _js.is_integer(daily) or daily < 0 or daily > 1000:
                return coded("Use a whole number from 0 to 1,000", "assistant_limit", 400)
            daily = int(daily)
            rl.store.set_setting("assistant-viewer-daily", str(daily))
            return json({"viewerDaily": daily})
        # The models a service offers, for the setup form's dropdown. The key can be the one already saved.
        if path == "/api/assistant/models" and method == "POST":
            from .assistant import AssistantError, list_models

            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            rl.init()
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            provider = _text(body, "provider")
            saved = rl.assistant_settings()
            base_url = re.sub(r"/+\Z", "", _js.trim(_text(body, "baseUrl")))
            # The saved key only for the address it was saved with.
            same_address = bool(saved) and saved.get("provider") == provider and (saved.get("baseUrl") or "") == base_url
            key = _js.trim(_text(body, "key")) or (saved["key"] if same_address else "")
            try:
                return json({"models": list_models({"provider": provider, "baseUrl": _js.trim(_text(body, "baseUrl")), "key": key}, rl.fetcher)})
            except AssistantError as error:
                return _refused(error, "assistant_failed")
        if path == "/api/assistant/chat" and method == "POST":
            return self._chat(request, url)

        # Only the owner manages tokens: an API token cannot make or revoke one.
        if path == "/api/tokens" or path.startswith("/api/tokens/"):
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            return self._tokens_api(request, path)

        if connected and path == "/api/links":
            access = self._reader(request)
            if access is False or access == "unconfigured":
                return self._denied(access)
            # A token limited to one site reads only that site's links, here as everywhere else.
            if isinstance(access, dict) and access["site"] and access["site"] != asked:
                return coded("Unknown site", "unknown_site", 404)
            return _pass_through(rl, connected, path, url)

        # An API token, or someone signed in to read, may list links and see each one's clicks, but not change them.
        if method == "GET" and (path == "/api/links" or re.fullmatch(r"/api/links/[a-f0-9]+", path)):
            access = self._reader(request)
            if access is False or access == "unconfigured":
                return self._denied(access)
            if access is not True:
                rl.init()
                asked_site = url.search_params.get("site")
                site = rl.site(asked_site if asked_site is not None else (access["site"] or None))
                if not site or (access["site"] and site["id"] != access["site"]):
                    return coded("Unknown site", "unknown_site", 404)
                scoped = url.copy()
                query = scoped.search_params
                query.set("site", site["id"])
                scoped.set_search_params(query)
                return self._links_api(request, path, scoped)

        if path == "/api/links" or path.startswith("/api/links/") or path == "/api/link-domains" or path.startswith("/api/link-domains/"):
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            return self._links_api(request, path, url)

        if path in ("/api/mail", "/api/mail/test", "/api/reports") or path.startswith("/api/reports/"):
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            return self._mail_api(request, path, url)

        # A ticket for the element picker, naming the dashboard it may send its choice to. A hub asks the install
        # that serves the site's script, with its own origin, since that install signs what the script will trust.
        if path == "/api/pick" and method == "POST":
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            rl.init()
            site = self._query_site(url)
            if isinstance(site, Response):
                return site
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            origin = _text(body, "origin")
            if not _ORIGIN.match(origin):
                return coded("Send the dashboard's origin, such as https://stats.example.com", "pick_origin", 400)
            # A hub's ticket only ever sends to the hub it connected from, never to an origin it names now.
            hub = self.managed.get(request)
            if hub and rl.store.setting(f"token-origin:{hub['id']}") != origin:
                return coded("This hub's address is not the one it connected from. Connect the site again from here.", "pick_hub", 403)
            return json({"ticket": self._pick_ticket(origin, site["id"])})

        if (path == "/api/goals" and method == "POST") or (re.fullmatch(r"/api/goals/[^/]+", path) and method in ("PATCH", "DELETE")):
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            return self._goal_writes(request, path, url)

        if path == "/api/shares" or path.startswith("/api/shares/"):
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            return self._shares_api(request, path, url)

        # Adding and deleting sites, when they are managed in the dashboard.
        if path == "/api/sites" and method == "POST":
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            body = self._read_json(request)
            if isinstance(body, Response):
                return body
            try:
                return json({"site": rl.add_site(body)}, 201)
            except _js.RangeError as error:
                return _refused(error, "site_invalid")

        site_match = re.fullmatch(r"/api/sites/([^/]+)", path)
        if site_match and method == "DELETE":
            access = self._can_read(request)
            if access is not True:
                return self._denied(access)
            try:
                rl.delete_site(_decode(site_match.group(1)))
                return json({"ok": True})
            except _js.RangeError as error:
                return coded(_message(error), "unknown_site", 404) if _message(error) == "Unknown site" else _refused(error, "site_invalid")
        if site_match and method == "PATCH":
            return self._patch_site(request, site_match.group(1), url)

        if method != "GET":
            return coded("Method not allowed", "method_not_allowed", 405)
        return self._reports(request, path, url)

    def _observe(self, request: Request) -> Response:
        rl = self.rl
        given = bearer(request)
        # The install-wide key and the owner's access can report for any site.
        any_site = bool(self.observe_key and given and _constant_time_equal(given, self.observe_key)) or self._can_read(request) is True
        if not any_site and not given:
            return coded("Unauthorized", "unauthorized", 401)
        body = self._read_json(request)
        if isinstance(body, Response):
            return body
        # One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
        fetches = _get(body, "fetches")
        batch = isinstance(fetches, list)
        items = fetches if batch else [body]
        if len(items) > 500:
            return coded("Send at most 500 fetches at a time", "observe_many", 413)
        pages: list[dict[str, Any]] = []
        for item in items:
            raw = _get(item, "url")
            page = Url.parse(_js.string("" if raw is None or raw is _js.UNDEFINED else raw))
            if page is None or page.protocol not in ("https:", "http:"):
                return coded("Send the page's url", "observe_url", 400)
            at = _get(item, "at")
            when: Any = None
            if _js.is_number(at):
                when = at
            elif isinstance(at, str):
                from .importers.http import parse_date

                when = parse_date(at)
            agent = _get(item, "userAgent")
            entry: dict[str, Any] = {"page": page, "userAgent": _js.slice16("" if agent is None or agent is _js.UNDEFINED else _js.string(agent), 0, 500)}
            if when is not None and _js.is_finite(when):
                entry["at"] = when
            pages.append(entry)
        rl.init()
        keep = pages
        if not any_site:
            # A site's own key reports only pages on that site's domains. Pages elsewhere in a batch (another
            # host in the same log, say) are skipped, not a reason to refuse the rest.
            key_site = None
            for site in rl.sites:
                key = rl.store.setting(f"observe-key:{site['id']}")
                if key and _constant_time_equal(given, key):
                    key_site = site["id"]
            if not key_site:
                return coded("Unauthorized", "unauthorized", 401)
            keep = [p for p in pages if (rl.site_for(p["page"].hostname) or {}).get("id") == key_site]
            # A single report for another site's page is a misconfigured plugin, which should hear about it.
            if not batch and not keep:
                return coded("Unauthorized", "unauthorized", 401)
        recorded = 0
        for p in keep:
            if rl.observe(Request(p["page"].href, "GET", {"user-agent": p["userAgent"]}), p.get("at")):
                recorded += 1
        # A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
        if not batch:
            return Response(b"", 204)
        return json({"recorded": recorded, "skipped": len(pages) - recorded})

    def _chat(self, request: Request, url: Url) -> Response:
        from .assistant import AssistantError, chat
        from .time import local_date

        rl = self.rl
        access = self._reader(request)
        if access is False or access == "unconfigured":
            return self._denied(access)
        if isinstance(access, dict) and access["id"]:
            return coded("Only the dashboard can use the assistant", "assistant_dashboard", 403)
        if request.headers.get(SHARE_HEADER) is not None:
            return coded("Not available on a shared dashboard", "share_not_available", 403)
        rl.init()
        settings = rl.assistant_settings()
        if not settings:
            return coded("The assistant is not set up yet. An owner can set it up in Settings, AI Assistant.", "assistant_unset", 400)
        body = self._read_json(request)
        if isinstance(body, Response):
            return body
        site = rl.site(_text(body, "site") or None)
        if not site:
            return coded("Unknown site", "unknown_site", 404)
        given = _get(body, "messages")
        messages = (
            [{"role": m["role"], "content": m["content"]} for m in given if isinstance(m, dict) and m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str)]
            if isinstance(given, list)
            else []
        )
        if not messages or messages[-1]["role"] != "user":
            return coded("Ask a question", "question_needed", 400)
        owner = access is True
        who = self.account_of(request) if self.account_of else None
        turn = self._ask_turn(who if who is not None else ("owner" if owner else "viewer"), owner)
        if isinstance(turn, Response):
            return turn
        language = _js.string(_get(body, "language"))
        try:
            answer = chat(
                settings,
                messages,
                {
                    "site": {"id": site["id"], "name": site["name"], "timezone": site["timezone"]},
                    "today": local_date(rl.now(), site["timezone"]),
                    "view": _js.slice16(_text(body, "view", "the last 30 days"), 0, 200),
                    "language": language if re.fullmatch(r"[a-z]{2}", language) else "en",
                },
                # Each tool reads the HTTP API with the asker's own headers, as the MCP server does.
                self._read_api(request, url, site["id"]),
                fetcher=rl.fetcher,
                now=rl.now,
            )
            return json(answer)
        except AssistantError as error:
            return _refused(error, "assistant_failed", 502)
        finally:
            turn()

    def _patch_site(self, request: Request, raw_id: str, url: Url) -> Response:
        from .time import is_timezone

        rl = self.rl
        access = self._can_read(request)
        if access is not True:
            return self._denied(access)
        # A form posted from another site cannot carry this content type without CORS.
        body = self._read_json(request)
        if isinstance(body, Response):
            return body
        rl.init()
        # Every field is checked before any changes, since a shorter retention deletes visits at once.
        if _defined(body, "name"):
            name = _js.trim(_js.string(body["name"]))
            if not (name and _js.length(name) <= 80):
                return coded("A site name is 1 to 80 characters", "site_name", 400)
        if _defined(body, "timezone") and not is_timezone(_js.string(body["timezone"])):
            tz = _js.string(body["timezone"])
            return coded(f'Unknown timezone "{tz}"', "unknown_timezone", 400, {"timezone": tz})
        retention = _get(body, "retentionMonths")
        if retention is not _js.UNDEFINED and retention is not None and _js.number(retention) not in RETENTION_MONTHS:
            months = ", ".join(str(m) for m in RETENTION_MONTHS)
            return coded(f"Keep visits for {months} months, or forever", "retention_bad", 400, {"months": months})
        try:
            id_ = _decode(raw_id)
            remote = rl.remote(id_)
            # How long a connected site keeps visits, and the timezone its days follow, are the install's
            # settings: this server passes them on, and changes its own row only once the install took them.
            forward: dict[str, Any] = {}
            if retention is not _js.UNDEFINED:
                forward["retentionMonths"] = retention
            if _defined(body, "timezone") and _js.string(body["timezone"]) != (rl.site(id_) or {}).get("timezone", _js.UNDEFINED):
                forward["timezone"] = _js.string(body["timezone"])
            if remote and forward:
                if remote.get("scope") != "manage":
                    return coded("Connect this site again to change it from here", "connect_again", 400)
                answer = _pass_through(
                    rl,
                    remote,
                    f"/api/sites/{_js.encode_uri_component(remote['site'])}",
                    url.copy(),
                    Request(request.url, "PATCH", {"content-type": "application/json"}, _js.dumps(forward)),
                )
                if not answer.ok:
                    return answer
                rl.forget_remote_info(id_)
            elif not remote and retention is not _js.UNDEFINED:
                rl.set_retention(id_, None if retention is None else _js.number(retention))
            patch: dict[str, Any] = {}
            if _defined(body, "name"):
                patch["name"] = _js.string(body["name"])
            if _defined(body, "timezone"):
                patch["timezone"] = _js.string(body["timezone"])
            if _defined(body, "hostnames") and rl.managed_sites:
                patch["hostnames"] = body["hostnames"]
            site = rl.update_site(_decode(raw_id), patch)
            # A connected site answers as the list shows it, so the dashboard keeps its install and domains.
            if remote:
                site = {**site, "remote": remote["url"], "remoteSite": remote["site"], "manage": remote.get("scope") == "manage", "hostnames": remote["hostnames"]}
            return json({"site": site})
        except _js.RangeError as error:
            return coded(_message(error), "unknown_site", 404) if _message(error) == "Unknown site" else _refused(error, "site_invalid")

    def _reports(self, request: Request, path: str, url: Url) -> Response:
        """The reads: sites, stats, and every report, for the owner, a token, a viewer, or a share."""
        rl = self.rl
        store = rl.store
        params = url.search_params
        rl.init()
        # A shared dashboard sees exactly what its visitors see, even for someone signed in.
        share_id = request.headers.get(SHARE_HEADER)
        shared = None
        # The one site a share or a site's API token may read; None for every site.
        only = None
        if share_id is not None:
            shared = store.share_by_id(share_id) if _SHARE_ID.match(share_id) else None
            if not shared:
                return coded("This share link no longer works", "share_gone", 404)
            if not _shared_path(path):
                return coded("Not available on a shared dashboard", "share_not_available", 403)
            only = shared["site"]
        elif request.headers.get(EMBED_HEADER) is not None:
            embedded = self._embed_reader(request.headers.get(EMBED_HEADER) or "")
            if not embedded:
                return coded("This dashboard has expired. Reload the page to open it again.", "embed_expired", 401)
            # An embedded dashboard sees what a share link of its token's site shows.
            shared = {"id": "", "site": embedded["site"], "name": "", "createdAt": 0}
            only = embedded["site"]
        else:
            access = self._reader(request)
            if access is False or access == "unconfigured":
                return self._denied(access)
            if access is not True:
                if not _shared_path(path):
                    return coded("API tokens can only read", "token_read_only", 403)
                only = access["site"] or None

        if path == "/api/sites":
            visible = [s for s in rl.sites if s["id"] == only] if only else rl.sites
            sites = []
            for site in visible:
                remote = rl.remote(site["id"])
                row = dict(site)
                # A connected install's address, so the dashboard can say where the site is counted.
                # Its domains as the install reported them, for the goal picker; tracker hits never match them here.
                if remote and not shared:
                    row.update({"remote": remote["url"], "remoteSite": remote["site"], "manage": remote.get("scope") == "manage", "hostnames": remote["hostnames"]})
                # Hostnames say where the site lives; a share shows only its name.
                if shared:
                    row["hostnames"] = []
                row["lastSeen"] = rl.remote_last_seen(site["id"]) if remote else store.last_seen(site["id"])
                # Left out for a connected install that cannot be reached, so nobody reads "forever" by mistake.
                if not shared:
                    row["retentionMonths"] = _field(rl.remote_info(site["id"]), "retentionMonths") if remote else rl.retention(site["id"])
                # Whether a connected install still takes this server's token, so the dashboard offers to connect it
                # again only when it no longer does.
                if remote and not shared:
                    row["connection"] = _field(rl.remote_info(site["id"]), "connection")
                sites.append(row)
            # A share never learns how the install is run.
            return json({"sites": sites} if shared else {"sites": sites, "managed": rl.managed_sites})

        if shared:
            site = rl.site(shared["site"])
        elif only:
            asked_site = params.get("site")
            site = rl.site(asked_site if asked_site is not None else only)
        else:
            site = self._query_site(url)
        if isinstance(site, Response):
            return site
        if not site or (only and site["id"] != only):
            return coded("Unknown site", "unknown_site", 404)
        remote = rl.remote(site["id"])
        if remote:
            return _pass_through(rl, remote, path, url, request)

        if path == "/api/icon":
            from .icon import fetch_icon

            host = site["hostnames"][0] if site["hostnames"] else None
            # Only a site's own domain, never the request's Host header, which a caller can write.
            icon = fetch_icon(f"https://{host}", rl.now(), rl.fetcher) if host else None
            if not icon:
                return coded("No icon", "icon_none", 404, None, {"cache-control": "private, max-age=3600"})
            return Response(
                icon["body"],
                200,
                {
                    "content-type": icon["type"],
                    "cache-control": "private, max-age=86400",
                    # An SVG served from this origin must never run script.
                    "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox",
                    "x-content-type-options": "nosniff",
                },
            )

        if path == "/api/realtime":
            return json(store.realtime(site["id"], rl.now()))

        from .time import buckets, local_weekday_hour

        read = self._read_query(url, site)
        if isinstance(read, Response):
            return read
        query, range_, compared = read["query"], read["range"], read["compared"]
        range_out = {"from": range_["fromDate"], "to": range_["toDate"], "interval": range_["interval"], "timezone": site["timezone"]}
        compare_out = {"from": compared["fromDate"], "to": compared["toDate"]} if compared else _js.UNDEFINED
        before = {**query, "from": compared["from"], "to": compared["to"]} if compared else None

        if path == "/api/stats":
            stats = store.stats(query)
            previous = store.stats(before) if before else _js.UNDEFINED
            return json({"site": site["id"], "range": range_out, "compare": compare_out, "stats": stats, "previous": previous})

        if path == "/api/goals":
            goals = store.goals(site["id"])
            visitors = store.visitors(query)
            previous_visitors = store.visitors(before) if before else 0
            # Every goal in one pass for the range, and one more for the comparison.
            now_all = store.goal_totals_all(query, goals)
            before_all = store.goal_totals_all(before, goals) if before else None
            rows = []
            for goal in goals:
                now = now_all[goal["id"]]
                then = before_all.get(goal["id"]) if before_all is not None else None
                rows.append(
                    {
                        **goal,
                        **now,
                        "rate": now["visitors"] / visitors if visitors else 0,
                        "previous": {**then, "rate": then["visitors"] / previous_visitors if previous_visitors else 0} if then else _js.UNDEFINED,
                    }
                )
            return json({"site": site["id"], "range": range_out, "compare": compare_out, "visitors": visitors, "goals": rows})

        goal_match = re.fullmatch(r"/api/goals/([a-f0-9]{24})", path)
        if goal_match:
            goal = store.goal_by_id(goal_match.group(1))
            if not goal or goal["site"] != site["id"]:
                return coded("Unknown goal", "unknown_goal", 404)
            visitors = store.visitors(query)
            totals = store.goal_totals(query, goal)
            series = store.goal_series(query, goal, buckets(range_, site["timezone"]))
            sources = store.goal_breakdown(query, goal, "source")
            channels = store.goal_breakdown(query, goal, "channel")
            pages = store.goal_breakdown(query, goal, "path")
            return json(
                {
                    "site": site["id"],
                    "range": range_out,
                    "goal": goal,
                    "totals": {**totals, "rate": totals["visitors"] / visitors if visitors else 0},
                    "series": series,
                    "sources": sources,
                    "channels": channels,
                    "pages": pages,
                }
            )

        if path == "/api/series":
            points = store.series(query, buckets(range_, site["timezone"]))
            # Comparison points line up with the main ones by position.
            previous = store.series(query, buckets(compared, site["timezone"]))[: len(points)] if compared else _js.UNDEFINED
            return json({"site": site["id"], "range": range_out, "compare": compare_out, "points": points, "previous": previous})

        if path == "/api/rhythm":
            # Visits per weekday and hour, plus each cell's details for its tooltip.
            # Visitors are summed over the hours folded into a cell, so someone who
            # came on two Tuesdays at 2pm counts twice there.
            grid = [[0] * 24 for _ in range(7)]
            cells = [[{"visits": 0, "visitors": 0, "pageviews": 0, "bounced": 0} for _ in range(24)] for _ in range(7)]
            for row in store.hourly(query):
                weekday, h = local_weekday_hour(row["quarter"] * 900_000, site["timezone"])
                grid[weekday][h] += row["visits"]
                cell = cells[weekday][h]
                cell["visits"] += row["visits"]
                cell["visitors"] += row["visitors"]
                cell["pageviews"] += row["pageviews"]
                cell["bounced"] += row["bounced"]
            details = [
                [{"visits": c["visits"], "visitors": c["visitors"], "pageviews": c["pageviews"], "bounceRate": c["bounced"] / c["visits"] if c["visits"] else 0} for c in day]
                for day in cells
            ]
            return json({"site": site["id"], "range": range_out, "grid": grid, "cells": details})

        if path == "/api/journeys":
            from .journeys import PAGES_PER_VISIT, journeys
            from .store import JOURNEY_VISITS

            through = re.fullmatch(f"([0-9]+):({_DOT}+)", params.get("through") or "")
            # Journeys reads the newest visits up to a cap; say when it was reached.
            read_pages = store.journey_pages(query, PAGES_PER_VISIT)
            steps = params.get("steps")
            options: dict[str, Any] = {"steps": _js.number(steps if steps is not None else 5)}
            if params.get("start"):
                options["start"] = params.get("start")
            if params.get("end"):
                options["end"] = params.get("end")
            if through:
                options["through"] = {"step": _js.number(through.group(1)), "value": through.group(2)}
            answer = {"site": site["id"], "range": range_out, **journeys(read_pages["rows"], options)}
            if read_pages["sampled"]:
                answer["sampled"] = JOURNEY_VISITS
            return json(answer)

        if path == "/api/funnels":
            # One funnel at a time, so a page of funnels never takes every database connection at once.
            rows = []
            for funnel in store.funnels(site["id"]):
                counts = store.funnel_counts(query, funnel)
                rows.append({**funnel, "steps": [{**step, "visits": counts[i]} for i, step in enumerate(funnel["steps"])]})
            return json({"site": site["id"], "range": range_out, "funnels": rows})

        if path == "/api/event-props":
            event = params.get("event") or ""
            if not event:
                return coded("Name the event", "event_needed", 400)
            keys = store.event_prop_keys(query, event)
            asked = params.get("key")
            # A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
            if asked is not None and not ('"' not in asked and "\\" not in asked and 1 <= _js.length(asked) <= 64):
                return coded("Bad property name", "property_bad", 400)
            key = asked if asked is not None else (keys[0]["key"] if keys else None)
            limit = _limit(params.get("limit"), 100)
            rows = store.event_prop_values(query, event, key, limit) if key else []
            return json({"site": site["id"], "range": range_out, "event": event, "keys": keys, "key": key, "rows": rows})

        if path == "/api/breakdown":
            from .query import is_dimension

            dimension = params.get("dimension") or ""
            if not is_dimension(dimension):
                return coded(f'Unknown dimension "{dimension}"', "unknown_dimension", 400, {"dimension": dimension})
            limit = _limit(params.get("limit"), 10)
            page = _js.number(params.get("page"))
            page = max(1, page if _js.truthy(page) else 1)
            rows = store.breakdown(query, dimension, limit, _js.whole((page - 1) * limit))
            if params.get("format") == "csv":
                return _download(
                    f"{site['id']}-{dimension}-{range_['fromDate']}-{range_['toDate']}.csv",
                    _rows_csv(rows, {"timezone": site["timezone"], "dimension": dimension}),
                    "text/csv; charset=utf-8",
                )
            return json({"site": site["id"], "range": range_out, "dimension": dimension, "rows": rows})

        # Everything the dashboard shows for a view, as a ZIP of CSV files.
        if path == "/api/export":
            from .query import DIMENSIONS
            from .zip import csv, zip as make_zip

            files = []
            stats = store.stats(query)
            previous = store.stats(before) if before else None
            now_row = _sheet_row(stats, {"timezone": site["timezone"]})
            then_row = _sheet_row(previous, {"timezone": site["timezone"]}) if previous else None
            files.append(
                {
                    "name": "overview.csv",
                    "text": csv(
                        ["metric", "value"] + (["previous"] if then_row else []),
                        [[m, now_row[m]] + ([then_row.get(m, _js.UNDEFINED)] if then_row else []) for m in now_row],
                    ),
                }
            )
            points = store.series(query, buckets(range_, site["timezone"]))
            files.append({"name": "over-time.csv", "text": _rows_csv(points, {"timezone": site["timezone"], "interval": range_["interval"]})})
            for dimension in DIMENSIONS:
                rows = store.breakdown(query, dimension, 1000, 0)
                if rows:
                    files.append({"name": f"{dimension}.csv", "text": _rows_csv(rows, {"timezone": site["timezone"], "dimension": dimension})})
            goals = store.goals(site["id"])
            if goals:
                totals = store.goal_totals_all(query, goals)
                files.append(
                    {
                        "name": "goals.csv",
                        "text": csv(
                            ["goal", "conversions", "visitors", "revenue", "currency"],
                            [[g["name"], totals[g["id"]]["conversions"], totals[g["id"]]["visitors"], totals[g["id"]]["revenue"], g["currency"]] for g in goals],
                        ),
                    }
                )
            return _download(f"{site['id']}-{range_['fromDate']}-{range_['toDate']}.zip", make_zip(files, rl.now()), "application/zip")

        return coded("Not found", "not_found", 404)

    # The handler.

    def handle(self, request: Request, context: Mapping[str, Any] | None = None) -> Response:
        """Answers one request under the base path: the dashboard and its assets, the tracker, the API, MCP, OAuth,
        accounts, and the small pages."""
        context = dict(context or {})
        url = Url(request.url)
        base = self.base
        # OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
        if base and _is_oauth_document(url.pathname):
            from .oauth import oauth_response

            try:
                return oauth_response(self.oauth, request, url.pathname, url, context) or coded("Not found", "not_found", 404)
            except Exception as error:  # noqa: BLE001
                print(f"Runlight: {error!r}", file=sys.stderr)
                return coded("Internal error", "internal", 500)
        if base and url.pathname != base and not url.pathname.startswith(f"{base}/"):
            return coded("Not found", "not_found", 404)
        path = url.pathname[len(base) :] or "/"

        try:
            return self._route(request, path, url, context)
        except Exception as error:  # noqa: BLE001
            print(f"Runlight: {error!r}", file=sys.stderr)
            return coded("Internal error", "internal", 500)

    def _route(self, request: Request, path: str, url: Url, context: dict[str, Any]) -> Response:
        rl = self.rl
        base = self.base
        method = request.method
        # Checked before any route, so a connected site's pass-through to its install is held to it too.
        if self._admin_only(path, method) and self._can_read(request) is True and request in self.members:
            return coded("Only an owner or admin can change this", "admin_only", 403)
        # Sign-in, setup, invites, and the Account and People APIs, and the dashboard sends anyone signed out to sign in.
        if self.web is not None:
            answered = self.web.handle(request, path, context)
            if answered:
                return answered
        if path == "/s.js" and method == "GET":
            script = self._tracker_script(url.search_params.get("site"))
            headers = {
                "content-type": "application/javascript; charset=utf-8",
                # Short, so a new click goal reaches visitors within minutes; the etag makes rechecks cheap.
                "cache-control": "public, max-age=300",
                "etag": script["etag"],
            }
            if request.headers.get("if-none-match") == script["etag"]:
                return Response(b"", 304, headers)
            return Response(script["body"], 200, headers)

        if path == "/pick.js" and method == "GET":
            # The picker sends what it picked only to the dashboard its ticket names; without a good ticket it does
            # nothing. It also runs only on the pages of the site the ticket names.
            target = self._pick_target(url.search_params.get("runlight_ticket") or "")
            if target:
                rl.init()
            if target:
                ticketed = rl.site(target["site"])
                hosts = ticketed["hostnames"] if ticketed else None
            else:
                hosts = []
            script = assets.PICKER.replace(PICK_TARGET_PLACEHOLDER, _js.dumps((target or {}).get("origin", "") if hosts is not None else ""), 1)
            script = script.replace(PICK_HOSTS_PLACEHOLDER, _js.dumps(_js.dumps(hosts if hosts is not None else [])), 1)
            return Response(script, 200, {"content-type": "application/javascript; charset=utf-8", "cache-control": "no-store"})

        if path == f"/assets/world.{assets.WORLD_HASH}.json" and method == "GET":
            return Response(assets.WORLD_JSON, 200, {"content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=31536000, immutable"})

        locale = re.fullmatch(r"/assets/locale\.([a-z]{2,3})\.([a-f0-9]+)\.json", path)
        locales = assets.LOCALES
        if locale and locale.group(2) == assets.LOCALES_HASH and locales.get(locale.group(1)) and method == "GET":
            return Response(locales[locale.group(1)], 200, {"content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=31536000, immutable"})

        if path.startswith("/assets/app.") and method == "GET":
            hash_ = assets.DASHBOARD_HASH
            asset = assets.DASHBOARD_JS if path == f"/assets/app.{hash_}.js" else assets.DASHBOARD_CSS if path == f"/assets/app.{hash_}.css" else None
            if asset is None:
                return coded("Not found", "not_found", 404)
            return Response(
                asset,
                200,
                {
                    "content-type": "application/javascript; charset=utf-8" if path.endswith(".js") else "text/css; charset=utf-8",
                    "cache-control": "public, max-age=31536000, immutable",
                },
            )

        if path == "/e":
            if method == "OPTIONS":
                return Response(b"", 204, {"access-control-allow-origin": "*", "access-control-allow-methods": "POST", "access-control-max-age": "86400"})
            if method != "POST":
                return coded("Method not allowed", "method_not_allowed", 405)
            try:
                rl.collect(request, context)
            except Exception as error:  # noqa: BLE001
                print(f"Runlight: could not record an event {error!r}", file=sys.stderr)
            # The same answer whatever happened, so the endpoint reveals nothing.
            return Response(b"", 202, {"access-control-allow-origin": "*"})

        if path == "/api" or path.startswith("/api/"):
            return self._api(request, path, url)

        if path.startswith("/oauth/") or _is_oauth_document(path):
            from .oauth import oauth_response

            answer = oauth_response(self.oauth, request, path, url, context)
            if answer:
                return answer

        if path == "/mcp":
            from .mcp import mcp_response

            # No server-sent stream and no sessions: every message is one POST.
            if method != "POST":
                return coded("Method not allowed", "method_not_allowed", 405, None, {"allow": "POST"})
            access = self._reader(request)
            if access is False or access == "unconfigured":
                from .oauth import resource_metadata_url

                refused = self._denied(access)
                # Points an OAuth client at the metadata that starts the sign-in.
                refused.headers.set("www-authenticate", f'Bearer realm="runlight", resource_metadata="{resource_metadata_url(url.origin, base)}"')
                return refused
            # Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
            return mcp_response(request, self._read_api(request, url))

        unsubscribe = re.fullmatch(r"/unsubscribe/([^/]+)/?", path)
        if unsubscribe and method in ("GET", "POST"):
            return self._unsubscribe_page(request, unsubscribe.group(1))

        # The dashboard inside a CMS's admin pages, opened with a ticket its plugin just got. Only the admin origin
        # the ticket names may frame it. A ticket used already or run out opens it with no session, so it says it
        # has expired and offers to reload the admin page; anything else is refused and never framed.
        if path == "/embed" and method == "GET":
            rl.init()
            found = self._redeem_embed(url.search_params.get("ticket") or "")
            if not found:
                t, lang = _translator(_accepted_language(request))
                return _small_page(lang, f"<h1>{escape_html(t('embed.goneTitle'))}</h1><p>{escape_html(t('embed.gone'))}</p>", 404)
            session = self._embed_session(found["token"]["id"]) if found["token"] else ""
            return Response(
                dashboard(base, "", "", _js.truthy(self.options.get("geoCredit")), False, "", {"session": session, "origin": found["origin"]}),
                200 if session else 410,
                {
                    "content-type": "text/html; charset=utf-8",
                    "cache-control": "no-store",
                    "content-security-policy": DASHBOARD_CSP.replace("frame-ancestors 'none'", f"frame-ancestors {found['origin']}"),
                    "referrer-policy": "no-referrer",
                    "x-robots-tag": "noindex",
                },
            )

        share_page = re.fullmatch(r"/share/([^/]+)/?", path)
        if share_page and method == "GET":
            rl.init()
            id_ = share_page.group(1)
            share = rl.store.share_by_id(id_) if _SHARE_ID.match(id_) else None
            if not share:
                t, lang = _translator(_accepted_language(request))
                return _small_page(lang, f"<h1>{escape_html(t('share.goneTitle'))}</h1><p>{escape_html(t('share.gone'))}</p>", 404)
            return Response(
                dashboard(base, share["id"], "", _js.truthy(self.options.get("geoCredit"))),
                200,
                {
                    "content-type": "text/html; charset=utf-8",
                    "cache-control": "no-store",
                    "content-security-policy": DASHBOARD_CSP,
                    "x-frame-options": "DENY",
                    # The share id is the key; never send it on to another site.
                    "referrer-policy": "no-referrer",
                    "x-robots-tag": "noindex",
                },
            )

        if path in ("/", "") and method == "GET":
            given = url.search_params.get("token")
            if given and self.token and _constant_time_equal(given, self.token):
                query = url.search_params
                query.delete("token")
                url.set_search_params(query)
                secure = "; Secure" if url.protocol == "https:" else ""
                return Response(
                    b"",
                    303,
                    {
                        "location": url.pathname + url.search,
                        "set-cookie": f"{COOKIE}={cookie_value(self.token)}; Path={base or '/'}; HttpOnly; SameSite=Lax; Max-Age=2592000{secure}",
                    },
                )
            # The page itself holds no data; the API it calls checks access and
            # the page explains how to sign in when it is refused.
            return Response(
                dashboard(base, "", self.sign_out or "", _js.truthy(self.options.get("geoCredit")), self.web is not None, self.sign_in or ""),
                200,
                {
                    "content-type": "text/html; charset=utf-8",
                    "cache-control": "no-store",
                    "content-security-policy": DASHBOARD_CSP,
                    "x-frame-options": "DENY",
                    "referrer-policy": "same-origin",
                },
            )

        return coded("Not found", "not_found", 404)


def _field(info: Mapping[str, Any] | None, key: str) -> Any:
    """A field of a remote's info, or undefined when there is none, which JSON leaves out."""
    return info[key] if info is not None and key in info else _js.UNDEFINED
