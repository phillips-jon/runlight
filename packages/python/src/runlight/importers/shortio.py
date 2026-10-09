"""Short.io: https://developers.short.io/reference"""

from __future__ import annotations

from typing import Any

from .. import _js
from .http import Http, HttpError, at, credential, either, items, iso_string, parse_date, positive
from .types import ImportError

API = "https://api.short.io"
STATS = "https://statistics.short.io/statistics"
PAGE = 8
# The statistics API allows 60 requests a minute.
STATS_GAP_MS = 1050


class Shortio:
    """Short.io. Links are listed per domain. Daily click counts come from the
    statistics API, paced to its limit of 60 requests a minute, so a step
    holds only a few links."""

    def step(self, input: dict[str, Any]) -> dict[str, Any]:
        credentials, cursor, known, now = input["credentials"], input.get("cursor"), input["known"], input["now"]
        http: Http = input.get("http") or Http()
        key = credential(credentials, "apiKey")
        if not key:
            raise ImportError("Enter a Short.io secret API key", "import_key", {"service": "Short.io"})
        headers = {"authorization": key}
        if cursor:
            state = _js.loads(cursor)
        else:
            domains = items(http.get_json(f"{API}/api/domains?limit=300", {"headers": headers}))
            state = {"domains": [{"id": _js.get(d, "id"), "hostname": _js.get(d, "hostname")} for d in domains], "d": 0, "token": None, "total": None}
        domain = _js.get(state["domains"], state["d"])
        if not _js.truthy(domain):
            return {"cursor": None, "total": None, "links": []}

        token = f"&pageToken={_js.encode_uri_component(_js.string(state['token']))}" if _js.truthy(_js.get(state, "token")) else ""
        page = http.get_json(f"{API}/api/links?domain_id={_js.string(_js.get(domain, 'id'))}&limit={PAGE}{token}", {"headers": headers})

        links = []
        for link in items(_js.get(page, "links")):
            id = _js.string(either(_js.get(link, "idString"), _js.get(link, "id")))
            path = _js.get(link, "path")
            original = _js.get(link, "originalURL")
            if known(id, path, original):
                links.append({"link": {"sourceId": id, "slug": path, "domain": "", "name": "", "url": original, "createdAt": 0}, "known": True})
                continue
            daily = None
            try:
                http.pause(STATS_GAP_MS)
                body = http.get_json(
                    f"{STATS}/link/{_js.encode_uri_component(id)}/by_interval",
                    {
                        "method": "POST",
                        "headers": {**headers, "content-type": "application/json"},
                        "body": _js.dumps({"period": "total", "clicksChartInterval": "day", "tz": "UTC"}),
                    },
                )
                raw = _js.get(body, "clickStatistics")
                points = raw if isinstance(raw, list) else either(at(raw, "datasets", 0, "data"), [])
                daily = []
                for p in items(points):
                    y = _js.get(p, "y")
                    if positive(y):
                        x = _js.get(p, "x")
                        daily.append({"day": iso_string(x if _js.is_number(x) else parse_date(x))[:10], "clicks": y})
            except HttpError as error:
                if error.status == 401:
                    raise
            created = parse_date(_js.get(link, "createdAt"))
            title = _js.get(link, "title")
            item: dict[str, Any] = {
                "link": {
                    "sourceId": id,
                    "slug": path,
                    "domain": _js.get(domain, "hostname"),
                    "name": title if _js.truthy(title) else "",
                    "url": original,
                    "createdAt": created if _js.truthy(created) else now,
                }
            }
            if daily is not None:
                item["daily"] = daily
            links.append(item)

        next = _js.get(page, "nextPageToken")
        if _js.truthy(next):
            more: dict[str, Any] | None = {**state, "token": next}
        elif state["d"] + 1 < len(state["domains"]):
            more = {**state, "d": state["d"] + 1, "token": None}
        else:
            more = None
        return {"cursor": _js.dumps(more) if more else None, "total": None, "links": links}


shortio = Shortio()
