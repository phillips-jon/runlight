"""Connecting another Runlight to this one (a hub) without copying a token:
this server registers itself with the install's OAuth server, sends the
owner to that install's consent page, and on the way back swaps the code
for a manage token, limited there to the one site the owner picked.

A pending attempt is kept in settings as `connect:<state>`: the install's `url`, the `client` id it gave, the
PKCE `verifier`, the `redirect` address, its `token` endpoint, and when it `expires`.
"""

from __future__ import annotations

import re
from typing import Any

from . import _js
from .hash import random_id
from .http import Response, SearchParams, Url
from .oauth import s256

PENDING_MS = 15 * 60_000

_INSTALL = re.compile(r"https://[^/]+|http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/|\Z)")
_STATE = re.compile(r"[a-f0-9]{32}\Z")


class ConnectError(_js.RangeError):
    """Why connecting failed, as a code the dashboard says in its own words. The first four ("expired", "denied",
    "refused", and "token") come back from the consent page, the rest ("url", "unreachable", "not_runlight",
    "endpoints", "old", and "register") from starting. The page it lands on is this server's own, so it never
    shows text that came in the address."""

    def __init__(self, message: str, code: str, params: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = {} if params is None else params


def install_url(value: Any) -> str:
    """The install's address as its dashboard is, without a trailing slash."""
    url = re.sub(r"/+\Z", "", _js.trim(_js.string("" if value is None or value is _js.UNDEFINED else value)))
    if not _INSTALL.match(url):
        raise ConnectError("Enter the install's address, like https://example.com/runlight", "url")
    return url


def _json(answer: Response) -> Any:
    """The body as JSON, or None when it is not, as `answer.json().catch(() => null)`."""
    try:
        ok, value = _js.try_loads(answer.content())
    except Exception:  # noqa: BLE001
        return None
    return value if ok else None


def _clear_expired(runlight: Any) -> None:
    """Attempts nobody came back from are removed, so they do not pile up in settings."""
    for setting in runlight.store.settings_starting_with("connect:"):
        ok, pending = _js.try_loads(setting["value"])
        expires = pending.get("expires") if ok and isinstance(pending, dict) else None
        if not _js.truthy(expires) or _js.number(expires) < runlight.now():
            runlight.store.set_setting(setting["key"], None)


def _same_origin(endpoint: Any, origin: str) -> bool:
    """Whether an endpoint is on the install's own address."""
    parsed = Url.parse(_js.string(endpoint))
    return parsed is not None and parsed.origin == origin


def start_connect(runlight: Any, input: Any, back: str, site: str = "") -> str:  # noqa: A002
    """Starts connecting: returns the address of the install's consent page."""
    url = install_url(input)
    host = Url(url).host
    try:
        answer = runlight.fetcher.fetch(f"{url}/.well-known/oauth-authorization-server", {"timeoutMs": 10_000})
    except Exception:  # noqa: BLE001
        raise ConnectError(f"Could not reach {url}", "unreachable", {"host": host}) from None
    meta = _json(answer) if answer.ok else None
    if not isinstance(meta, dict) or not all(
        _js.truthy(meta.get(name)) for name in ("authorization_endpoint", "token_endpoint", "registration_endpoint")
    ):
        raise ConnectError(f"{url} did not answer like a Runlight install", "not_runlight", {"url": url})
    # Its endpoints must be its own, so an address cannot steer this server into requests elsewhere.
    origin = Url(url).origin
    if not all(_same_origin(meta[name], origin) for name in ("authorization_endpoint", "token_endpoint", "registration_endpoint")):
        raise ConnectError(f"{url} named endpoints on another address", "endpoints", {"url": url})
    scopes = meta.get("scopes_supported")
    if not (isinstance(scopes, list) and "manage" in scopes):
        raise ConnectError(f"{url} runs an older Runlight. Update it, or connect it with an API token from its Settings.", "old", {"url": url})

    try:
        registered = runlight.fetcher.fetch(_js.string(meta["registration_endpoint"]), {
            "method": "POST",
            "headers": {"content-type": "application/json"},
            "body": _js.dumps({"client_name": f"Runlight at {Url(back).host}", "redirect_uris": [back]}),
            "timeoutMs": 10_000,
        })  # fmt: skip
    except Exception:  # noqa: BLE001
        raise ConnectError(f"Could not reach {url}", "unreachable", {"host": host}) from None
    client = _json(registered)
    client_id = client.get("client_id") if isinstance(client, dict) else None
    if not registered.ok or not _js.truthy(client_id):
        # Say why, in the install's own words when it gives them.
        description = client.get("error_description") if isinstance(client, dict) else None
        if _js.truthy(description):
            reason = f"{_js.cut(_js.string(description), 200)}."
        elif registered.status == 400:
            reason = "This server's address must use https."
        else:
            reason = f"It answered {registered.status}."
        raise ConnectError(f"{url} would not let this server connect. {reason}", "register", {"url": url, "reason": reason})
    client_id = _js.string(client_id)
    _clear_expired(runlight)

    state = random_id(16)
    verifier = f"{random_id(32)}{random_id(32)}"
    pending = {
        "url": url,
        "client": client_id,
        "verifier": verifier,
        "redirect": back,
        "token": meta["token_endpoint"],
        "expires": runlight.now() + PENDING_MS,
    }
    runlight.store.set_setting(f"connect:{state}", _js.dumps(pending))
    to = Url(_js.string(meta["authorization_endpoint"]))
    query = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": back,
        "code_challenge": s256(verifier),
        "code_challenge_method": "S256",
        "scope": "manage",
        "state": state,
    }
    # Which of its sites to offer first, when connecting again for a site already here.
    if site:
        query["site"] = site
    to.set_search_params(SearchParams(query))
    return to.href


def finish_connect(runlight: Any, params: SearchParams) -> str:
    """Finishes connecting when the owner comes back from the consent page. Returns the site's id here."""
    state = params.get("state") or ""
    key = f"connect:{state}"
    stored = runlight.store.setting(key) if _STATE.match(state) else None
    # Each attempt works once.
    if stored:
        runlight.store.set_setting(key, None)
    pending = _js.loads(stored) if stored else None
    if not pending or pending["expires"] < runlight.now():
        raise ConnectError("That connection took too long or was already used. Start again.", "expired")
    if params.get("error") == "access_denied":
        raise ConnectError("The connection was not allowed.", "denied")
    if params.get("error"):
        description = params.get("error_description")
        raise ConnectError(description if description is not None else params.get("error") or "", "refused")

    answer = None
    try:
        answer = runlight.fetcher.fetch(pending["token"], {
            "method": "POST",
            "headers": {"content-type": "application/x-www-form-urlencoded"},
            "body": SearchParams({
                "grant_type": "authorization_code",
                "code": params.get("code") or "",
                "client_id": pending["client"],
                "redirect_uri": pending["redirect"],
                "code_verifier": pending["verifier"],
            }).to_string(),
            "timeoutMs": 10_000,
        })  # fmt: skip
    except Exception:  # noqa: BLE001
        answer = None
    granted = _json(answer) if answer is not None and answer.ok else None
    token = granted.get("access_token") if isinstance(granted, dict) else None
    if not _js.truthy(token):
        raise ConnectError(f"{Url(pending['url']).host} did not give this server a token. Start again.", "token")
    remote: dict[str, Any] = {"url": pending["url"], "token": token}
    if "site" in granted:
        remote["site"] = granted["site"]
    site = runlight.add_site({"remote": remote})
    return site["id"]
