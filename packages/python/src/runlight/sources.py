"""Pages and where visits came from.

A Page is a dict {"hostname", "path", "utm": {"source", "medium", "campaign", "term", "content"}, "ref", "paid"}:
`ref` is a `ref` or `source` query parameter, used when there is no utm_source, and `paid` says a click id such
as gclid was present (the id itself is never kept). An Attribution is a dict {"referrerHost", "referrerPath",
"source", "channel"}, the channel one of Direct, Organic Search, Paid Search, Social, Email, AI, Referral, or
Campaign.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Any

from . import _js
from .data.sources import SOURCE_PATTERNS, SOURCES
from .http import Url

CLICK_IDS = ["gclid", "gbraid", "wbraid", "dclid", "fbclid", "msclkid", "ttclid", "twclid", "li_fat_id", "yclid"]
PAID_MEDIUMS = re.compile(r"(cpc|ppc|paid|paidsearch|paid_search|paid-search|sem|cpm|cpv|display|banner|retargeting)\Z")
EMAIL_MEDIUMS = re.compile(r"(e-?mail|newsletter|mail)\Z")
SOCIAL_MEDIUMS = re.compile(
    r"(social|social-network|social-media|sm|social_network|social_media|paid_social|paid-social|paidsocial)\Z"
)

# Later entries win, as Map.set does: the alias "kit" names Newsletter, not Kit.
_by_host: dict[str, dict[str, Any]] = {}
_by_alias: dict[str, dict[str, Any]] = {}
for _source in SOURCES:
    for _host in _source["hosts"]:
        _by_host[_host] = _source
    for _alias in _source.get("aliases", []):
        _by_alias[_alias] = _source


def _clip(value: str | None, max: int = 200) -> str:
    return _js.slice16(_js.trim(value or ""), 0, max)


def strip_www(host: str) -> str:
    lower = host.lower()
    return lower[4:] if lower.startswith("www.") else lower


def source_for_host(host: str) -> dict[str, Any] | None:
    """The most specific known source for a host: mail.google.com before
    google.com. Android apps send their package name as the referrer
    (com.google.android.gm for Gmail), which is matched the same way. Hosts
    known only by their shape (click trackers, webmail) come last."""
    clean = strip_www(host)
    candidate = clean
    while "." in candidate:
        found = _by_host.get(candidate)
        if found is not None:
            return found
        candidate = candidate[candidate.index(".") + 1 :]
    for rule in SOURCE_PATTERNS:
        if rule["pattern"].search(clean):
            return {"name": rule["name"] if rule["name"] is not None else clean, "kind": rule["kind"], "hosts": []}
    return None


def source_for_alias(value: str) -> dict[str, Any] | None:
    key = _js.trim(value.lower())
    found = _by_alias.get(key)
    return found if found is not None else _by_host.get(strip_www(key))


_HTTP = re.compile(r"https?://", re.IGNORECASE | re.ASCII)


def recorded_path(input: str) -> str | None:
    """A path a person wrote, in the form paths are recorded: the path of a pasted URL, with a leading
    slash, percent-encoded as the browser's URL parser encodes it, and with a hash route kept, as
    parse_page keeps it. None when it is not a path or a URL."""
    if _HTTP.match(input):
        url = Url.parse(input)
    else:
        url = Url.parse(input if input.startswith("/") else f"/{input}", "https://x.invalid")
    return None if url is None else parse_page(url)["path"]


_RUN = re.compile(r"(?:%[0-9A-Fa-f]{2})+")
_MEANINGFUL = re.compile(f"[{_js.WHITESPACE}/?#%]")


def _keeps_meaning(text: str) -> bool:
    """/[\\s/?#%\\p{C}]/u.test(text): white space, a mark that changes a path, or a control, format, surrogate,
    private use, or unassigned character."""
    return bool(_MEANINGFUL.search(text)) or any(unicodedata.category(c).startswith("C") for c in text)


def readable_path(path: str) -> str:
    """A recorded path as people write it, for showing and exporting: /caf%C3%A9 as /café. Only text is
    decoded; an encoded slash, space, or other mark that would change the path's meaning stays as it is."""

    def decode(m: re.Match[str]) -> str:
        run = m.group(0)
        text = _js.decode_uri_component(run)
        if text is None:
            return run
        return run if _keeps_meaning(text) else text

    return _RUN.sub(decode, path)


def parse_page(url: Url) -> dict[str, Any]:
    q = url.search_params
    path = url.pathname or "/"
    # The tracker only sends a hash when the site asked for hash routing.
    if _js.length(url.hash) > 1:
        path += url.hash
    return {
        "hostname": strip_www(url.hostname),
        "path": _js.slice16(path, 0, 1000),
        "utm": {
            "source": _clip(q.get("utm_source")),
            "medium": _clip(q.get("utm_medium")).lower(),
            "campaign": _clip(q.get("utm_campaign")),
            "term": _clip(q.get("utm_term")),
            "content": _clip(q.get("utm_content")),
        },
        "ref": _clip(q.get("ref") if q.get("ref") is not None else q.get("source")),
        "paid": any(q.has(id) for id in CLICK_IDS),
    }


def attribute(page: dict[str, Any], referrer: str, internal_hosts: list[str]) -> dict[str, Any]:
    """Where a visit came from. `internal_hosts` are the site's own hostnames: a
    referrer on one of them is navigation within the site, not a source."""
    referrer_host = ""
    referrer_path = ""
    if referrer:
        # Not a URL is treated as no referrer.
        url = Url.parse(referrer)
        # Android apps refer as android-app://<package>/.
        if url is not None and url.protocol in ("http:", "https:", "android-app:"):
            host = strip_www(url.hostname)
            if host != page["hostname"] and host not in internal_hosts:
                referrer_host = host
                referrer_path = "" if url.protocol == "android-app:" else _js.slice16(url.pathname, 0, 500)

    tagged = page["utm"]["source"] or page["ref"]
    known = source_for_alias(tagged) if tagged else source_for_host(referrer_host) if referrer_host else None
    source = known["name"] if known is not None else (tagged or referrer_host)
    if known is not None:
        kind = known["kind"]
    elif referrer_host:
        by_host = source_for_host(referrer_host)
        kind = by_host["kind"] if by_host is not None else None
    else:
        kind = None
    medium = page["utm"]["medium"]

    if (page["paid"] or PAID_MEDIUMS.match(medium)) and kind == "search":
        channel = "Paid Search"
    elif kind == "ai":
        channel = "AI"
    elif EMAIL_MEDIUMS.match(medium) or kind == "email":
        channel = "Email"
    elif kind == "search":
        channel = "Organic Search"
    elif SOCIAL_MEDIUMS.match(medium) or kind == "social":
        channel = "Social"
    elif page["utm"]["source"] or page["utm"]["medium"] or page["utm"]["campaign"]:
        channel = "Campaign"
    elif referrer_host or page["ref"]:
        channel = "Referral"
    else:
        channel = "Direct"

    return {"referrerHost": referrer_host, "referrerPath": referrer_path, "source": source, "channel": channel}
