"""Dub: https://dub.co/docs/api-reference"""

from __future__ import annotations

from typing import Any

from .. import _js
from .http import Http, HttpError, at, credential, defined, items, parse_date, positive
from .types import ImportError

BASE = "https://api.dub.co"
PAGE = 10


class Dub:
    """Dub. Links come from GET /links (cursor pages of up to 100, archived
    included). Click history is per click from /events where the plan allows,
    else daily counts from /analytics, else none; the first link decides.

    What the account's plan lets us read rides in the cursor as `history`: "events" (every click, Business),
    "daily" (daily counts, Pro), "none" (Free), or None before the first link."""

    def step(self, input: dict[str, Any]) -> dict[str, Any]:
        credentials, cursor, known, now = input["credentials"], input.get("cursor"), input["known"], input["now"]
        http: Http = input.get("http") or Http()
        key = credential(credentials, "apiKey")
        if not key:
            raise ImportError("Enter a Dub API key", "import_key", {"service": "Dub"})
        headers = {"authorization": f"Bearer {key}"}
        state = _js.loads(cursor) if cursor else {"after": None, "history": None}
        history = _js.get(state, "history")
        after = f"&startingAfter={_js.encode_uri_component(_js.string(state['after']))}" if _js.truthy(_js.get(state, "after")) else ""
        listed = items(http.get_json(f"{BASE}/links?pageSize={PAGE}&showArchived=true{after}", {"headers": headers}))

        links = []
        for link in listed:
            id = _js.get(link, "id")
            if known(id, _js.get(link, "key"), _js.get(link, "url")):
                links.append(
                    {"link": {"sourceId": id, "slug": _js.get(link, "key"), "domain": "", "name": "", "url": _js.get(link, "url"), "createdAt": 0}, "known": True}
                )
                continue
            clicks: list[dict[str, Any]] | None = None
            daily: list[dict[str, Any]] | None = None
            if history is None or history == "events":
                try:
                    clicks = []
                    page = 1
                    while True:
                        events = items(
                            http.get_json(
                                f"{BASE}/events?event=clicks&linkId={_js.encode_uri_component(_js.string(id))}&interval=all&sortOrder=asc&limit=1000&page={page}",
                                {"headers": headers},
                            )
                        )
                        for e in events:
                            click = at(e, "click")
                            referer = at(click, "referer")
                            referer_url = at(click, "refererUrl")
                            device = at(click, "device")
                            if device is not _js.UNDEFINED and device is not None and not isinstance(device, str):
                                raise TypeError("e.click.device.toLowerCase is not a function")
                            clicks.append(
                                defined(
                                    {
                                        "ts": parse_date(at(e, "timestamp")),
                                        "visit": at(click, "id"),
                                        "referrer": referer_url
                                        if _js.truthy(referer_url)
                                        else (f"https://{_js.string(referer)}/" if _js.truthy(referer) and referer != "(direct)" else ""),
                                        "country": at(click, "country"),
                                        "region": at(click, "region"),
                                        "city": at(click, "city"),
                                        "device": device.lower() if isinstance(device, str) else _js.UNDEFINED,
                                        "browser": at(click, "browser"),
                                        "os": at(click, "os"),
                                    }
                                )
                            )
                        if len(events) < 1000:
                            break
                        page += 1
                    history = "events"
                except HttpError as error:
                    if error.status == 401:
                        raise
                    clicks = None
                    history = "daily"
            if history == "daily":
                try:
                    series = http.get_json(
                        f"{BASE}/analytics?event=clicks&groupBy=timeseries&interval=all&linkId={_js.encode_uri_component(_js.string(id))}",
                        {"headers": headers},
                    )
                    daily = [
                        {"day": _js.slice16(_js.get(p, "start"), 0, 10), "clicks": _js.get(p, "clicks")} for p in items(series) if positive(_js.get(p, "clicks"))
                    ]
                except HttpError as error:
                    if error.status == 401:
                        raise
                    history = "none"
            created = parse_date(_js.get(link, "createdAt"))
            title = _js.get(link, "title")
            item: dict[str, Any] = {
                "link": {
                    "sourceId": id,
                    "slug": _js.get(link, "key"),
                    "domain": _js.get(link, "domain"),
                    "name": title if _js.truthy(title) else "",
                    "url": _js.get(link, "url"),
                    "createdAt": created if _js.truthy(created) else now,
                }
            }
            if clicks is not None:
                item["clicks"] = clicks
            if daily is not None:
                item["daily"] = daily
            links.append(item)
        last = listed[-1] if listed else None
        more = len(listed) == PAGE and _js.truthy(last)
        return {"cursor": _js.dumps({"after": _js.get(last, "id"), "history": history}) if more else None, "total": None, "links": links}


dub = Dub()
