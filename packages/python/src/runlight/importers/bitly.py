"""Bitly: https://dev.bitly.com/api-reference"""

from __future__ import annotations

import re
from typing import Any

from .. import _js
from .http import Http, HttpError, at, credential, either, items, parse_date, positive
from .types import ImportError

BASE = "https://api-ssl.bitly.com/v4"
PAGE = 20


def _split(value: Any) -> dict[str, str]:
    """A short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale"."""
    if not isinstance(value, str):
        raise TypeError("value.replace is not a function")
    bare = re.sub(r"^https?://", "", value)
    slash = bare.find("/")
    if slash < 0:
        return {"domain": bare, "slug": ""}
    return {"domain": bare[:slash], "slug": re.sub(r"/\Z", "", bare[slash + 1 :])}


class Bitly:
    """Bitly. Links are listed per group (every group in the account), with
    archived ones. Bitly only keeps daily click counts, and only as far back
    as the account's plan allows. A custom back-half or branded domain wins
    over the random bit.ly one."""

    def step(self, input: dict[str, Any]) -> dict[str, Any]:
        credentials, cursor, known, now = input["credentials"], input.get("cursor"), input["known"], input["now"]
        http: Http = input.get("http") or Http()
        token = credential(credentials, "token") or credential(credentials, "apiKey")
        if not token:
            raise ImportError("Enter a Bitly access token", "import_key", {"service": "Bitly"})
        headers = {"authorization": f"Bearer {token}"}
        if cursor:
            state = _js.loads(cursor)
        else:
            groups = items(_js.get(http.get_json(f"{BASE}/groups", {"headers": headers}), "groups"))
            state = {"groups": [_js.get(g, "guid") for g in groups], "g": 0, "after": None}
        group = _js.get(state["groups"], state["g"])
        if not _js.truthy(group):
            return {"cursor": None, "total": None, "links": []}

        after = f"&search_after={_js.encode_uri_component(_js.string(state['after']))}" if _js.truthy(state.get("after")) else ""
        page = http.get_json(f"{BASE}/groups/{_js.string(group)}/bitlinks?size={PAGE}&archived=both{after}", {"headers": headers})

        links = []
        for b in items(_js.get(page, "links")):
            if _js.truthy(_js.get(b, "is_deleted")):
                continue
            id = _js.get(b, "id")
            short = _split(either(at(b, "custom_bitlinks", 0), id))
            if known(id, short["slug"], _js.get(b, "long_url")):
                links.append({"link": {"sourceId": id, "slug": "", "domain": "", "name": "", "url": _js.get(b, "long_url"), "createdAt": 0}, "known": True})
                continue
            daily = None
            try:
                clicks = http.get_json(f"{BASE}/bitlinks/{_js.encode_uri_component(_js.string(id))}/clicks?unit=day&units=-1", {"headers": headers})
                daily = [
                    {"day": _js.slice16(_js.get(c, "date"), 0, 10), "clicks": _js.get(c, "clicks")}
                    for c in items(_js.get(clicks, "link_clicks"))
                    if positive(_js.get(c, "clicks"))
                ]
            except HttpError as error:
                # Plans without analytics refuse this; the link still comes across.
                if error.status == 401:
                    raise
            created = parse_date(_js.get(b, "created_at"))
            item: dict[str, Any] = {
                "link": {
                    "sourceId": id,
                    "slug": short["slug"],
                    "domain": short["domain"],
                    "name": _js.get(b, "title") if _js.truthy(_js.get(b, "title")) else "",
                    "url": _js.get(b, "long_url"),
                    "createdAt": created if _js.truthy(created) else now,
                }
            }
            if daily is not None:
                item["daily"] = daily
            links.append(item)

        next = at(page, "pagination", "search_after")
        next = next if _js.truthy(next) and len(_js.get(page, "links")) == PAGE else None
        if next is not None:
            more: dict[str, Any] | None = {**state, "after": next}
        elif state["g"] + 1 < len(state["groups"]):
            more = {**state, "g": state["g"] + 1, "after": None}
        else:
            more = None
        return {"cursor": _js.dumps(more) if more else None, "total": None, "links": links}


bitly = Bitly()
