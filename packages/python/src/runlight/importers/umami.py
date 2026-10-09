"""Umami's links: https://umami.is/docs/api"""

from __future__ import annotations

import math
import re
from typing import Any

from .. import _js
from .http import Http, at, credential, defined, either, items, parse_date
from .types import ImportError

PAGE = 5


def umami_sign_in(credentials: dict[str, Any], token: Any = None, http: Http | None = None) -> dict[str, Any]:
    """Signs in to an Umami: an API key, or a username and password (stock
    self-hosted Umami has no API keys). A token from an earlier step is reused.
    Gives {base, token}."""
    http = http or Http()
    base = re.sub(r"/+\Z", "", credential(credentials, "url"))
    if not re.match(r"https?://[^/]+", base):
        raise ImportError("Enter your Umami address, like https://stats.example.com", "import_umami_address")
    key = credential(credentials, "apiKey")
    if key or _js.truthy(token):
        return {"base": base, "token": key or token}
    if not credentials.get("username") or not credentials.get("password"):
        raise ImportError("Enter an API key, or a username and password", "import_umami_login")
    login = http.get_json(
        f"{base}/api/auth/login",
        {
            "method": "POST",
            "headers": {"content-type": "application/json"},
            "body": _js.dumps({"username": credentials["username"], "password": credentials["password"]}),
        },
    )
    # A sign-in that answers without a token was refused, whatever its status.
    token = at(login, "token")
    if not isinstance(token, str) or token == "":
        raise ImportError("The key or sign-in was refused", "import_refused")
    return {"base": base, "token": token}


def at_least(count: int, total: Any) -> bool:
    """count >= total, as JavaScript compares a number with whatever a service sent."""
    n = _js.number(total)
    return not math.isnan(n) and count >= n


def map_key(value: Any) -> Any:
    """A Map key for a value read from JSON: the same text and the same number are the same key, an object only
    itself."""
    if value is _js.UNDEFINED:
        return ("undefined",)
    if isinstance(value, (dict, list)):
        return ("object", id(value))
    return ("value", _js.dumps(value))


class Umami:
    """Umami v3 (and forks with custom link domains). Signs in with an API key,
    or with a username and password (stock self-hosted Umami has no API keys).
    In Umami a link's clicks are events stored under the link's id, with the
    visitor's session holding place and device."""

    def step(self, input: dict[str, Any]) -> dict[str, Any]:
        credentials, cursor, known, now = input["credentials"], input.get("cursor"), input["known"], input["now"]
        http: Http = input.get("http") or Http()
        # A key comes with every step; only a sign-in token, which expires, rides in the cursor.
        saved = _js.loads(cursor) if cursor else {"page": 1}
        key = credential(credentials, "apiKey")
        signed = umami_sign_in(credentials, _js.get(saved, "token"), http)
        base = signed["base"]
        state = {"page": _js.get(saved, "page"), "token": signed["token"]}
        headers = {"authorization": f"Bearer {_js.string(state['token'])}"}
        listed = http.get_json(f"{base}/api/links?page={_js.string(state['page'])}&pageSize={PAGE}", {"headers": headers})

        def all(path: str) -> list[Any]:
            out: list[Any] = []
            page = 1
            while True:
                body = http.get_json(f"{base}/api{path}&page={page}&pageSize=1000", {"headers": headers})
                data = items(_js.get(body, "data"))
                out.extend(data)
                if at_least(len(out), _js.get(body, "count")) or len(data) == 0:
                    return out
                page += 1

        links = []
        for link in items(_js.get(listed, "data")):
            if _js.truthy(_js.get(link, "deletedAt")):
                continue
            id, slug, url, name = (_js.get(link, k) for k in ("id", "slug", "url", "name"))
            if known(id, slug, url):
                links.append({"link": {"sourceId": id, "slug": slug, "domain": "", "name": name, "url": url, "createdAt": 0}, "known": True})
                continue
            created = parse_date(_js.get(link, "createdAt"))
            created = created if _js.truthy(created) else now
            range = f"startAt={_js.number_text(created - 86_400_000)}&endAt={_js.number_text(now + 60_000)}"
            # TS asks for both at once; here one follows the other.
            events = all(f"/websites/{_js.string(id)}/events?{range}")
            sessions = all(f"/websites/{_js.string(id)}/sessions?{range}")
            info: dict[Any, Any] = {}
            for s in sessions:
                info[map_key(_js.get(s, "id"))] = s
            clicks = []
            for e in events:
                s = info.get(map_key(_js.get(e, "sessionId")), _js.UNDEFINED)
                domain = _js.get(e, "referrerDomain")
                path = _js.get(e, "referrerPath")
                clicks.append(
                    defined(
                        {
                            "ts": parse_date(_js.get(e, "createdAt")),
                            "visit": _js.get(e, "sessionId"),
                            "referrer": f"https://{_js.string(domain)}{_js.string(path) if _js.truthy(path) else '/'}" if _js.truthy(domain) else "",
                            "path": _js.get(e, "urlPath"),
                            "query": _js.get(e, "urlQuery"),
                            "country": _js.get(e, "country"),
                            "region": at(s, "region"),
                            "city": _js.get(e, "city"),
                            "browser": _js.get(e, "browser"),
                            "os": _js.get(e, "os"),
                            "device": _js.get(e, "device"),
                            "screen": at(s, "screen"),
                            "language": at(s, "language"),
                        }
                    )
                )
            links.append(
                {
                    "link": {"sourceId": id, "slug": slug, "domain": either(at(link, "customDomain", "domain"), ""), "name": name, "url": url, "createdAt": created},
                    "clicks": clicks,
                }
            )
        page = _js.number(state["page"])
        # Without a count there is no total, and a full page may have more after it.
        count = _js.get(listed, "count")
        count = count if _js.is_number(count) and _js.is_finite(count) else None
        data = _js.get(listed, "data")
        more = len(data) == PAGE if count is None else page * PAGE < count and len(data) > 0
        following = {"page": _js.whole(page + 1)} if key else {"page": _js.whole(page + 1), "token": state["token"]}
        return {"cursor": _js.dumps(following) if more else None, "total": count, "links": links}


umami = Umami()
