"""Rebrandly: https://developers.rebrandly.com/docs"""

from __future__ import annotations

from typing import Any

from .. import _js
from .http import Http, at, credential, either, items, parse_date
from .types import ImportError

BASE = "https://api.rebrandly.com/v1"
PAGE = 25


class Rebrandly:
    """Rebrandly. Its API gives only total clicks, with no dates, so links come
    across with their slugs and domains and start their history fresh."""

    def step(self, input: dict[str, Any]) -> dict[str, Any]:
        credentials, cursor, now = input["credentials"], input.get("cursor"), input["now"]
        http: Http = input.get("http") or Http()
        key = credential(credentials, "apiKey")
        if not key:
            raise ImportError("Enter a Rebrandly API key", "import_key", {"service": "Rebrandly"})
        headers = {"apikey": key}
        workspace = credential(credentials, "workspace")
        if workspace:
            headers["workspace"] = workspace
        last = f"&last={_js.encode_uri_component(cursor)}" if cursor else ""
        listed = items(http.get_json(f"{BASE}/links?orderBy=createdAt&orderDir=desc&limit={PAGE}{last}", {"headers": headers}))
        links = []
        for link in listed:
            title = _js.get(link, "title")
            created = parse_date(_js.get(link, "createdAt"))
            links.append(
                {
                    "link": {
                        "sourceId": _js.get(link, "id"),
                        "slug": _js.get(link, "slashtag"),
                        "domain": either(at(link, "domain", "fullName"), ""),
                        "name": title if _js.truthy(title) else "",
                        "url": _js.get(link, "destination"),
                        "createdAt": created if _js.truthy(created) else now,
                    }
                }
            )
        end = listed[-1] if listed else None
        return {"cursor": _js.get(end, "id") if len(listed) == PAGE and _js.truthy(end) else None, "total": None, "links": links}


rebrandly = Rebrandly()
