"""Writing an imported link and its history, and the names other tools use, in Runlight's spelling."""

from __future__ import annotations

import math
import re
from typing import Any

from .. import _js
from ..hash import sha256
from ..http import Url
from ..sources import attribute, parse_page, strip_www
from .http import iso_string, parse_date

# Domains run by the shorteners themselves. Links there stay on Runlight's own path.
SHORTENER_DOMAINS = {"bit.ly", "bitly.com", "j.mp", "dub.sh", "dub.co", "dub.link", "short.gy", "rebrand.ly", "rebrandly.com", "rb.gy"}


def hex_id(value: str, length: int = 24) -> str:
    return sha256(value)[:length]


def imported_link_id(source: str, source_id: str) -> str:
    """The Runlight id an imported link gets, from its source and its id there."""
    return hex_id(f"{source}:{source_id}")


def same_url(a: str, b: str) -> bool:
    """Two destinations are the same link when they differ only by a trailing slash."""
    return re.sub(r"/\Z", "", a) == re.sub(r"/\Z", "", b)


# Browser and system names as other tools write them, in Runlight's spelling.
BROWSERS = {
    "chrome": "Chrome", "crios": "Chrome", "chromium-webview": "Android WebView", "chrome webview": "Android WebView", "safari": "Safari", "ios": "Safari",
    "ios-webview": "Safari", "mobile safari": "Safari", "firefox": "Firefox", "fxios": "Firefox", "edge": "Edge", "edge-chromium": "Edge",
    "edge-ios": "Edge", "microsoft edge": "Edge", "opera": "Opera", "opera-mini": "Opera", "samsung": "Samsung Internet",
    "samsung internet": "Samsung Internet", "yandexbrowser": "Yandex Browser", "facebook": "Facebook", "instagram": "Instagram", "brave": "Brave",
    "duckduckgo": "DuckDuckGo",
}  # fmt: skip
SYSTEMS = {
    "mac os": "macOS", "mac os x": "macOS", "macos": "macOS", "ios": "iOS", "android os": "Android", "android": "Android",
    "windows 10": "Windows", "windows 11": "Windows", "windows 7": "Windows", "windows": "Windows", "linux": "Linux", "chrome os": "Chrome OS",
    "chromium os": "Chrome OS",
}  # fmt: skip
DEVICES = {"desktop": "desktop", "laptop": "desktop", "mobile": "mobile", "smartphone": "mobile", "phone": "mobile", "tablet": "tablet"}

_SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}\Z")
_COUNTRY = re.compile(r"[A-Z]{2}\Z")
_LEADING_QUESTION = re.compile(r"^\?")


def title(v: str) -> str:
    """The first UTF-16 unit in upper case, as v[0].toUpperCase() + v.slice(1) does."""
    if not v:
        return ""
    # Half of a pair has no case, so a character past U+FFFF stays as it is.
    return v if ord(v[0]) > 0xFFFF else v[0].upper() + v[1:]


def _text(value: Any) -> str:
    """`value || ""` read as text."""
    return _js.string(value) if _js.truthy(value) else ""


def _or_text(value: Any) -> str:
    """`value ?? ""` read as text."""
    return "" if value is None or value is _js.UNDEFINED else _js.string(value)


def browser(name: str) -> str:
    """A browser name in Runlight's spelling: a known one, or the name with a capital first letter."""
    return BROWSERS.get(name.lower(), title(name))


def device(name: str) -> str:
    return DEVICES.get(name.lower(), "")


def write_link(runlight: Any, site: str, source: str, foreign: dict[str, Any], history: dict[str, Any]) -> dict[str, Any]:
    """Writes one link and its history in a single transaction: the link (and its
    branded domain), then each click as a visit like a live one, or daily
    counts as clicks without visitors. Ids come from the source's own ids, so
    importing again skips what is already there.

    Returns a WriteResult: {status: "created" | "skipped" | "failed", clicks, reason?, code?, params?}, the reason
    also as a code and its params, for the dashboard to say in its own words."""
    id = imported_link_id(source, _js.string(foreign["sourceId"]))
    if runlight.store.link_by_id(id):
        return {"status": "skipped", "clicks": 0}
    slug = _js.string(foreign["slug"])
    taken = runlight.store.link_by_slug(slug)
    # The same slug to the same place is this link, brought in earlier some other way.
    if taken and same_url(taken["url"], _js.string(foreign["url"])):
        return {"status": "skipped", "clicks": 0}
    if taken:
        return {
            "status": "failed",
            "clicks": 0,
            "reason": f'/{slug} is already used by "{taken["name"]}"',
            "code": "import_slug_taken",
            "params": {"slug": slug, "name": taken["name"]},
        }
    if not _SLUG.match(slug):
        return {"status": "failed", "clicks": 0, "reason": f"/{slug} has characters Runlight slugs cannot use", "code": "import_slug_bad", "params": {"slug": slug}}

    domain = strip_www(_text(foreign.get("domain")))
    if domain in SHORTENER_DOMAINS:
        domain = ""
    now = runlight.now()
    clicks = 0

    # Nothing in the transaction is one link's own problem (those are checked above),
    # so a failure in it is the database's, and it stops the import rather than marking the link.
    def write(store: Any) -> None:
        nonlocal clicks
        # On a database without transactions (D1), a failed earlier try can have left
        # some of this link's clicks behind. Clear them, then write the link row last,
        # so a link only counts as imported once all of its history is in.
        store.db.run("DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')", [id])
        store.db.run("DELETE FROM rl_events WHERE link = ?", [id])

        made: set[str] = set()
        for c in history.get("clicks") or []:
            ts = c.get("ts", _js.UNDEFINED)
            if not _js.is_finite(ts):
                continue
            ts = _js.whole(ts)
            visit = c.get("visit", _js.UNDEFINED)
            visit_key = f"{_js.number_text(ts)}:{clicks}" if visit is None or visit is _js.UNDEFINED else _js.string(visit)
            session = hex_id(f"{source}:{_js.string(foreign['sourceId'])}:{visit_key}")
            # A visitor id lasts one day at most, as every other visitor id does.
            visitor = hex_id(f"{source}:{visit_key}:{iso_string(ts)[:10]}", 16)
            path = _text(c.get("path"))
            if session not in made:
                made.add(session)
                store.db.run("DELETE FROM rl_sessions WHERE id = ?", [session])
                host = domain or "link.invalid"
                query = _text(c.get("query"))
                search = "?" + _LEADING_QUESTION.sub("", query) if query else ""
                url = Url.parse(f"https://{host}{path or '/' + slug}{search}")
                page = parse_page(url if url is not None else Url(f"https://{host}/{slug}"))
                country = _js.slice16(_text(c.get("country")).upper(), 0, 2)
                raw_region = _text(c.get("region"))
                region = _js.slice16((raw_region if "-" in raw_region else f"{country}-{raw_region}").upper(), 0, 10) if raw_region else ""
                os_name = _text(c.get("os"))
                store.insert_session(
                    {
                        "id": session,
                        "site": site,
                        "visitor": visitor,
                        "startedAt": ts,
                        "hostname": page["hostname"],
                        **attribute(page, _or_text(c.get("referrer")), []),
                        "utmSource": page["utm"]["source"],
                        "utmMedium": page["utm"]["medium"],
                        "utmCampaign": page["utm"]["campaign"],
                        "utmTerm": page["utm"]["term"],
                        "utmContent": page["utm"]["content"],
                        "country": country if _COUNTRY.match(country) else "",
                        "region": region if country else "",
                        "city": _js.slice16(_text(c.get("city")), 0, 100),
                        "browser": browser(_text(c.get("browser"))),
                        "browserVersion": "",
                        "os": SYSTEMS.get(os_name.lower(), _or_text(c.get("os"))),
                        "osVersion": "",
                        "device": device(_text(c.get("device"))),
                        "screen": _or_text(c.get("screen")),
                        "language": _or_text(c.get("language")),
                    }
                )
                store.db.run("UPDATE rl_sessions SET imported = 1 WHERE id = ?", [session])
            click_path = path or f"/{slug}"
            store.touch_session(session, ts, "click", click_path)
            store.insert_event(
                {
                    "site": site, "ts": ts, "kind": "click", "visitor": visitor, "session": session, "pageview": "", "path": _js.slice16(click_path, 0, 1000),
                    "hostname": domain, "title": "", "name": slug, "props": None, "engagedMs": 0, "scroll": None, "link": id,
                }
            )  # fmt: skip
            clicks += 1

        # Counts without detail: clicks spread through each day, with no visitor or visit.
        for d in history.get("daily") or []:
            start = parse_date(f"{_js.string(d.get('day', _js.UNDEFINED))}T00:00:00Z")
            count = _js.number(d.get("clicks", _js.UNDEFINED))
            if not _js.is_finite(start) or count <= 0 or math.isnan(count):
                continue
            n = min(count, 1_000_000)
            i = 0
            while i < n:
                store.insert_event(
                    {
                        "site": site, "ts": start + math.floor(((i + 0.5) / n) * 86_400_000), "kind": "click", "visitor": "", "session": "",
                        "pageview": "", "path": f"/{slug}", "hostname": domain, "title": "", "name": slug, "props": {"imported": "daily"},
                        "engagedMs": 0, "scroll": None, "link": id,
                    }
                )  # fmt: skip
                clicks += 1
                i += 1
        if domain:
            store.add_link_domain(domain, site, now)
        created = foreign.get("createdAt")
        created = created if _js.truthy(created) else now
        store.insert_link(
            {
                "id": id,
                "site": site,
                "domain": domain,
                "slug": slug,
                "name": _js.slice16(_text(foreign.get("name")) or slug, 0, 100),
                "url": foreign["url"],
                "createdAt": created,
                "updatedAt": created,
            }
        )

    runlight.store.transaction(write)
    if domain:
        runlight.forget_link_domains()
    return {"status": "created", "clicks": clicks}
