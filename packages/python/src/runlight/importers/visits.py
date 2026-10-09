"""Visit history from Umami: pageviews and custom events with where each
visit came from, its place, and its device, written as imported visits so
the dashboard's history does not start the day Runlight was installed.

The dashboard drives it a few days at a time, oldest first, so it fits any
host's time limit and shows progress. It stops where Runlight's own visits
begin, so nothing is counted twice, and it remembers how far it got, so
running it again carries on from there.

An ImportedHit, one pageview or event from another tool in the shape every visit import writes, is a dict: `ts`,
`key` (groups rows into visitors, as Umami's session id does), `kind` ("pageview" or "event"), and the texts
`hostname`, `path`, `query`, `referrer`, `title`, `name`, `country`, `region`, `city`, `browser`, `os`, `device`,
`screen`, and `language`.
"""

from __future__ import annotations

import math
import re
from collections.abc import Callable
from typing import Any

from .. import _js
from ..http import Fetcher, Url
from ..sources import attribute, parse_page
from ..store import EVENT_TAIL_MS
from ..time import add_days, local_date
from .csvvisits import CSV_BATCH, csv_format, csv_hit
from .http import Http, at, credential, items, parse_date
from .types import ImportError
from .umami import at_least, map_key, umami_sign_in
from .write import BROWSERS, DEVICES, SYSTEMS, hex_id, title

DAY = 86_400_000
# Each step reads at most this many days, or stops after this many events.
STEP_DAYS = 14
STEP_EVENTS = 5_000
# A single day with more than this is refused rather than read without end.
MAX_DAY_EVENTS = 200_000

# Umami's event types that are visits: a pageview, and a custom event.
PAGEVIEW = 1
CUSTOM_EVENT = 2

_WEBSITE = re.compile(r"[A-Za-z0-9-]{1,64}\Z")
_COUNTRY = re.compile(r"[A-Z]{2}\Z")
_LEADING_QUESTION = re.compile(r"^\?")


def _progress_key(site: str, website: str) -> str:
    return f"import:umami-visits:{site}:{website}"


def _is(value: Any, n: int) -> bool:
    """value === n for a number read from JSON."""
    return _js.is_number(value) and value == n


def _max(*values: int | float) -> int | float:
    """Math.max: NaN when any is."""
    return math.nan if any(isinstance(v, float) and math.isnan(v) for v in values) else max(values)


def umami_websites(credentials: dict[str, Any], fetcher: Fetcher | None = None) -> list[dict[str, Any]]:
    """The websites an Umami account can see, to pick which one becomes this site's history: [{id, name, domain}]."""
    http = Http(fetcher)
    signed = umami_sign_in(credentials, None, http)
    base = signed["base"]
    headers = {"authorization": f"Bearer {_js.string(signed['token'])}"}
    out: list[dict[str, Any]] = []
    for page in range(1, 100):
        body = http.get_json(f"{base}/api/websites?page={page}&pageSize=100", {"headers": headers})
        data = items(_js.get(body, "data"))
        out.extend({"id": _js.get(w, "id"), "name": _js.get(w, "name"), "domain": _js.get(w, "domain")} for w in data)
        if at_least(len(out), _js.get(body, "count")) or len(data) == 0:
            break
    return out


def _all(http: Http, base: str, path: str, headers: dict[str, str], limit: int) -> list[Any]:
    """Every page of an Umami list for a time window."""
    out: list[Any] = []
    page = 1
    while True:
        body = http.get_json(f"{base}/api{path}&page={page}&pageSize=1000", {"headers": headers})
        data = items(_js.get(body, "data"))
        out.extend(data)
        if at_least(len(out), _js.get(body, "count")) or len(data) == 0:
            return out
        if len(out) > limit:
            raise ImportError(f"One day has more than {limit:,} events, more than an import step can read", "import_day_full", {"limit": str(limit)})
        page += 1


def import_umami_visits(runlight: Any, site_id: str, credentials: dict[str, Any], website: str, cursor: str | None) -> dict[str, Any]:
    """One step: read the next few days from Umami and write them as imported visits. Gives a VisitImportStep:
    {cursor, done, total (days read so far and in all, for the progress bar), pageviews, events, visits}."""
    runlight.init()
    site = runlight.site(site_id)
    if not site:
        raise ImportError("Unknown site", "unknown_site")
    if not _WEBSITE.match(website):
        raise ImportError("Pick the Umami website to import", "import_website")
    http = Http(runlight.fetcher)

    saved = _js.loads(cursor) if cursor else None
    signed = umami_sign_in(credentials, at(saved, "token"), http)
    base, token = signed["base"], signed["token"]
    headers = {"authorization": f"Bearer {_js.string(token)}"}
    if saved is not None and _js.get(saved, "website") == website:
        state = saved
    else:
        info = http.get_json(f"{base}/api/websites/{website}", {"headers": headers})
        created = parse_date(_js.get(info, "createdAt"))
        created = created if _js.truthy(created) else runlight.now()
        # Carry on where an earlier run stopped, and end where Runlight's own visits begin.
        stored = runlight.store.setting(_progress_key(site_id, website))
        # A saved place that does not read as a number is ignored, as if there were none.
        resumed = _js.number(0 if stored is None else stored)
        resumed = resumed if _js.is_finite(resumed) else 0
        # Never older than the site keeps, or the next scheduled check would delete it again.
        cutoff = runlight.retention_cutoff(site_id) or 0
        start = _js.whole(_max(math.floor(created / DAY) * DAY, resumed, math.ceil(cutoff / DAY) * DAY))
        own = runlight.store.first_own_visit(site_id)
        state = {"website": website, "day": start, "start": start, "end": own if own is not None else runlight.now()}
    uses_key = bool(credential(credentials, "apiKey"))

    # Read whole days until the step has enough.
    events: list[Any] = []
    end = state["end"]
    from_ = state["day"]
    to = state["day"]
    while to < end and to - from_ < STEP_DAYS * DAY and len(events) < STEP_EVENTS:
        next = min(to + DAY, end)
        events.extend(_all(http, base, f"/websites/{website}/events?startAt={_js.number_text(to)}&endAt={_js.number_text(next - 1)}", headers, MAX_DAY_EVENTS))
        to = next
    sessions = (
        _all(http, base, f"/websites/{website}/sessions?startAt={_js.number_text(from_)}&endAt={_js.number_text(to - 1)}", headers, MAX_DAY_EVENTS * STEP_DAYS)
        if events
        else []
    )
    info_by_id: dict[Any, Any] = {}
    for s in sessions:
        info_by_id[map_key(_js.get(s, "id"))] = s

    ns = f"umami-visits:{website}"
    kept = []
    for e in events:
        kind = _js.get(e, "eventType")
        if not (_is(kind, PAGEVIEW) or (_is(kind, CUSTOM_EVENT) and _js.truthy(_js.get(e, "eventName")))):
            continue
        ts = parse_date(_js.get(e, "createdAt"))
        if not _js.is_finite(ts) or not ts < end:
            continue
        kept.append((ts, e))
    kept.sort(key=lambda pair: pair[0])
    visits = [{"ns": ns, "hit": _from_umami(e, ts, info_by_id.get(map_key(_js.get(e, "sessionId"))))} for ts, e in kept]
    counts = _write_step(runlight, site_id, from_, to, visits, lambda store: store.set_setting(_progress_key(site_id, website), _js.number_text(to)))

    total_days = max(1, math.ceil((end - state["start"]) / DAY))
    done_days = min(total_days, math.ceil((to - state["start"]) / DAY))
    more = to < end
    following = {**state, "day": to}
    if not uses_key:
        following["token"] = token
    return {"cursor": _js.dumps(following) if more else None, "done": done_days, "total": total_days, **counts}


def _write_step(
    runlight: Any,
    site_id: str,
    from_: int,
    to: int,
    hits: list[dict[str, Any]],
    done: Callable[[Any], None] | None = None,
) -> dict[str, int]:
    """Writes one step of imported visits, sorted oldest first, all within [from, to). Whatever an earlier import
    left in those times is cleared first, so a step can always run again, and a visit carried in from the step
    before is counted again from its rows. `done` runs in the same transaction, to remember how far it got."""
    site = runlight.site(site_id)
    if not site:
        raise ImportError("Unknown site", "unknown_site")
    counts = {"pageviews": 0, "events": 0, "visits": 0}

    def write(store: Any) -> None:
        # Days this step writes into are added up again later, with the imported visits in them.
        store.clear_rollups(site_id, {"from": from_, "to": to})
        # A failed earlier try at these days (on D1, which has no transactions) can
        # have left part of them behind. Clear it, so every step can safely run again.
        imported = "SELECT id FROM rl_sessions WHERE site = ? AND imported = 1"
        store.db.run(
            f"DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN ({imported})",
            [site_id, from_, to, site_id],
        )
        # Visits of these days that kept no rows go too. Their rows would come within EVENT_TAIL_MS of the step,
        # so the time bounds let the (site, ts) index find them, with no scan of every event.
        store.db.run(
            """DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?
         AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)""",
            [site_id, from_, to, site_id, from_, to + EVENT_TAIL_MS],
        )
        for item in hits:
            hit = item["hit"]
            if _write_event(store, site, item["ns"], hit):
                counts["visits"] += 1
            if hit["kind"] == "pageview":
                counts["pageviews"] += 1
            else:
                counts["events"] += 1
        # A visit that began in an earlier step and went on into this one is counted
        # again from its rows, so a repeated step cannot leave it with doubled totals.
        # The day it began may already be built, so that day is built again too.
        carried = store.db.all(
            """SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s
       WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?
         AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)""",
            [site_id, from_, from_ - EVENT_TAIL_MS, site_id, from_, to],
        )
        if carried:
            earliest = _js.whole(min(_js.number(c["started_at"]) for c in carried))
            store.clear_rollups(site_id, {"from": earliest, "to": from_})
            # Their rows lie between the earliest start and this step's end, which the (site, ts) index reads in one pass.
            # Ninety ids a statement, within Cloudflare D1's 100 values.
            rows: list[dict[str, Any]] = []
            for i in range(0, len(carried), 90):
                ids = [c["id"] for c in carried[i : i + 90]]
                rows.extend(
                    store.db.all(
                        f"""SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e
             WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN ({", ".join("?" for _ in ids)})
             ORDER BY e.ts, e.id""",
                        [site_id, earliest, to, *ids],
                    )
                )
            totals: dict[str, dict[str, Any]] = {}
            for r in rows:
                t = totals.get(r["session"]) or {"pageviews": 0, "events": 0, "last": 0, "exit": None}
                if r["kind"] == "pageview":
                    t["pageviews"] += 1
                    t["exit"] = r["path"]
                else:
                    t["events"] += 1
                t["last"] = max(t["last"], _js.number(r["ts"]))
                totals[r["session"]] = t
            for id, t in totals.items():
                store.db.run(
                    "UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?",
                    [t["pageviews"], t["events"], t["last"], t["exit"], id],
                )
        if done:
            done(store)

    runlight.store.transaction(write)
    return counts


def _referrer_of(domain: Any, path: Any, query: Any) -> str:
    if not _js.truthy(domain):
        return ""
    search = "?" + _LEADING_QUESTION.sub("", _js.string(query)) if _js.truthy(query) else ""
    return f"https://{_js.string(domain)}{_js.string(path) if _js.truthy(path) else '/'}{search}"


def _or_text(value: Any) -> str:
    """`value ?? ""` as text."""
    return "" if value is None or value is _js.UNDEFINED else _js.string(value)


def _from_umami(e: Any, ts: int | float, session: Any) -> dict[str, Any]:
    subdivision = at(session, "subdivision1")
    region = at(session, "region")
    return {
        "ts": _js.whole(ts),
        "key": _js.string(_js.get(e, "sessionId")),
        "kind": "pageview" if _is(_js.get(e, "eventType"), PAGEVIEW) else "event",
        "hostname": _or_text(_js.get(e, "hostname")),
        "path": _or_text(_js.get(e, "urlPath")),
        "query": _or_text(_js.get(e, "urlQuery")),
        "referrer": _referrer_of(_js.get(e, "referrerDomain"), _js.get(e, "referrerPath"), _js.get(e, "referrerQuery")),
        "title": _or_text(_js.get(e, "pageTitle")),
        "name": _or_text(_js.get(e, "eventName")),
        "country": _or_text(_js.get(e, "country")),
        "region": _js.string(subdivision if _js.truthy(subdivision) else region if _js.truthy(region) else ""),
        "city": _or_text(_js.get(e, "city")),
        "browser": _or_text(_js.get(e, "browser")),
        "os": _or_text(_js.get(e, "os")),
        "device": _or_text(_js.get(e, "device")),
        "screen": _or_text(at(session, "screen")),
        "language": _or_text(at(session, "language")),
    }


def _write_event(store: Any, site: dict[str, Any], ns: str, e: dict[str, Any]) -> bool:
    """Writes one imported pageview or event as part of a Runlight visit. Visitors
    are hashed per day from the hit's key, as live visitors are hashed per day,
    and a hit within thirty minutes of the visitor's last one joins that visit.
    Ids come from `ns` and the key, so importing the same rows again makes the
    same ids. Returns whether it started a new visit."""
    from ..core import SESSION_IDLE_MS

    # The site's own day, as live visitors are counted, so days add up the same way in rollups.
    day = local_date(e["ts"], site["timezone"])
    visitor = hex_id(f"{ns}:{e['key']}:{day}", 16)
    # A visit that runs past midnight keeps the id it started with, as a live one does.
    yesterday = hex_id(f"{ns}:{e['key']}:{add_days(day, -1)}", 16)
    hostnames = site.get("hostnames") or []
    host = (e["hostname"] or (hostnames[0] if hostnames else "") or "imported.invalid").lower()
    search = "?" + _LEADING_QUESTION.sub("", e["query"]) if e["query"] else ""
    url = Url.parse(f"https://{host}{e['path'] or '/'}{search}")
    page = parse_page(url if url is not None else Url(f"https://{host}/"))
    open = store.open_session(site["id"], [visitor, yesterday], e["ts"] - SESSION_IDLE_MS)
    id = open["id"] if open else None
    if not id:
        id = hex_id(f"{ns}:{e['key']}:{_js.number_text(e['ts'])}")
        store.db.run("DELETE FROM rl_sessions WHERE id = ?", [id])
        referrer = e["referrer"]
        country = _js.slice16((e["country"] or "").upper(), 0, 2)
        raw_region = e["region"]
        region = _js.slice16((raw_region if "-" in raw_region else f"{country}-{raw_region}").upper(), 0, 10) if raw_region else ""
        known = bool(_COUNTRY.match(country))
        store.insert_session(
            {
                "id": id,
                "site": site["id"],
                "visitor": visitor,
                "startedAt": e["ts"],
                "hostname": page["hostname"],
                **attribute(page, referrer, hostnames),
                "utmSource": page["utm"]["source"],
                "utmMedium": page["utm"]["medium"],
                "utmCampaign": page["utm"]["campaign"],
                "utmTerm": page["utm"]["term"],
                "utmContent": page["utm"]["content"],
                "country": country if known else "",
                "region": region if known else "",
                "city": _js.slice16(e["city"] or "", 0, 100),
                "browser": BROWSERS.get((e["browser"] or "").lower(), title(e["browser"] or "")),
                "browserVersion": "",
                "os": SYSTEMS.get((e["os"] or "").lower(), e["os"]),
                "osVersion": "",
                "device": DEVICES.get((e["device"] or "").lower(), ""),
                "screen": _js.slice16(e["screen"], 0, 20),
                "language": _js.slice16(e["language"], 0, 35),
            }
        )
        # No engaged time is known, so duration falls back to first-to-last pageview.
        store.db.run("UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", [id])
    kind = e["kind"]
    store.touch_session(id, e["ts"], kind, page["path"])
    store.insert_event(
        {
            "site": site["id"],
            "ts": e["ts"],
            "kind": kind,
            # The visit's own visitor, which for one running past midnight is the id of the day it started.
            "visitor": open["visitor"] if open else visitor,
            "session": id,
            "pageview": "",
            "path": page["path"],
            "hostname": page["hostname"],
            "title": _js.slice16(e["title"], 0, 300) if kind == "pageview" else "",
            "name": _js.slice16(e["name"], 0, 120) if kind == "event" else "",
            "props": None,
            "engagedMs": 0,
            "scroll": None,
            "link": "",
        }
    )
    return not open


def import_csv_visits(runlight: Any, site_id: str, rows: Any) -> dict[str, int]:
    """One batch of a CSV file, sorted oldest first by the dashboard. As with Umami, only rows from before
    Runlight's own first visit, and within what the site keeps, are written. A batch can run again: its
    time span is cleared first, so batches must not share a moment, which the dashboard sees to.
    Gives {pageviews, events, visits, skipped}."""
    runlight.init()
    if not runlight.site(site_id):
        raise ImportError("Unknown site", "unknown_site")
    if not isinstance(rows, list) or len(rows) > CSV_BATCH:
        raise ImportError(f"Send at most {CSV_BATCH} rows at a time", "import_csv_batch", {"max": str(CSV_BATCH)})
    clean: list[dict[str, str]] = []
    for r in rows:
        entries = r.items() if isinstance(r, dict) else ((str(i), v) for i, v in enumerate(r)) if isinstance(r, list) else ()
        clean.append({_js.trim(str(k)).lower(): _js.string("" if v is None else v) for k, v in entries})
    format = csv_format(list(clean[0].keys()) if clean else [])
    if not format:
        raise ImportError("This CSV is not an Umami export or Runlight's visit format", "import_csv_format")
    cutoff = runlight.retention_cutoff(site_id) or 0
    own = runlight.store.first_own_visit(site_id)
    end = min(math.inf if own is None else own, runlight.now())
    hits = [h for h in (csv_hit(row, format) for row in clean) if h is not None and cutoff <= h["hit"]["ts"] < end]
    hits.sort(key=lambda h: h["hit"]["ts"])
    for h in hits:
        h["hit"]["ts"] = _js.whole(h["hit"]["ts"])
    skipped = len(clean) - len(hits)
    if not hits:
        return {"pageviews": 0, "events": 0, "visits": 0, "skipped": skipped}
    counts = _write_step(runlight, site_id, hits[0]["hit"]["ts"], hits[-1]["hit"]["ts"] + 1, hits)
    return {**counts, "skipped": skipped}
