"""A site's icon, for the dashboard header: the best icon its home page
links to, or /favicon.ico. Fetched from the site's own configured origin
(never from request input), cached in memory for a day.

An icon is a dict {"body": bytes, "type": media type}.
"""

from __future__ import annotations

import re
import threading
import time
from typing import Any

from . import _js
from .http import Fetcher, Response, Url
from .safefetch import public_fetch

TIMEOUT_MS = 4000
MAX_BYTES = 256 * 1024
DAY = 86_400_000
# A few hundred sites at most; past that the oldest go, so the cache cannot grow without end.
CACHE_SIZE = 500

_cache: dict[str, dict[str, Any]] = {}
# Lookups under way, so many dashboards opening at once share one.
_pending: dict[str, threading.Lock] = {}
_guard = threading.Lock()

_S = _js.WHITESPACE


def _attr(tag: str, name: str) -> str:
    match = re.search(
        rf"\b{name}[{_S}]*=[{_S}]*(\"([^\"]*)\"|'([^']*)'|([^{_S}>]+))", tag, re.IGNORECASE | re.ASCII
    )
    if not match:
        return ""
    value = match.group(2)
    if value is None:
        value = match.group(3)
    if value is None:
        value = match.group(4)
    return _js.trim(value or "")


_LINK = re.compile(r"<link\b[^>]*>", re.IGNORECASE | re.ASCII)
_SPACES = re.compile(f"[{_S}]+")


def icon_links(html: str, base: str) -> list[str]:
    """Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG icons, then any icon."""
    found: list[tuple[str, int]] = []
    for tag in _LINK.findall(html):
        rel = _SPACES.split(_attr(tag, "rel").lower())
        href = _attr(tag, "href")
        if not href or not ("icon" in rel or "apple-touch-icon" in rel):
            continue
        parsed = Url.parse(href, base)
        if parsed is None:
            continue
        url = parsed.href
        # Only https, which is all the fetch below takes.
        if not url.startswith("https://"):
            continue
        type = _attr(tag, "type").lower()
        if "apple-touch-icon" in rel:
            score = 3
        elif "svg" in type or url.endswith(".svg"):
            score = 2
        elif "png" in type or url.endswith(".png"):
            score = 1
        else:
            score = 0
        found.append((url, score))
    # sorted is stable, as Array.prototype.sort is.
    return [url for url, _score in sorted(found, key=lambda f: -f[1])]


def _get(url: str, fetcher: Fetcher | None, read: dict[str, Any]) -> Response | None:
    """A GET of a public https address, with redirects followed only to public addresses too."""
    try:
        init = {"timeoutMs": TIMEOUT_MS, "redirects": 3, "headers": {"user-agent": "Runlight (+https://runlight.sh)"}}
        return public_fetch(url, {**init, **read}, fetcher)
    except Exception:
        return None


def _read_up_to(response: Response, max: int, whole: bool) -> bytes | None:
    """Up to `max` bytes of a body, reading no further. With `whole`, None when the body is longer, for an
    image that must arrive complete; without, the start of it, enough for a page's head."""
    if whole and _js.number(response.headers.get("content-length") or 0) > max:
        return None
    out = bytearray()
    try:
        for chunk in response.chunks():
            if len(out) + len(chunk) > max:
                if whole:
                    return None
                out += chunk[: max - len(out)]
                return bytes(out)
            out += chunk
    except Exception:
        # A body cut off part way: an image is no use, a page's start still is.
        if whole:
            return None
    return bytes(out)


def _image(url: str, fetcher: Fetcher | None) -> dict[str, Any] | None:
    # An image must arrive whole, so one longer than the cap is no use.
    response = _get(url, fetcher, {"maxBytes": MAX_BYTES})
    if response is None or not response.ok:
        return None
    type = _js.trim((response.headers.get("content-type") or "").split(";")[0]).lower()
    if not type.startswith("image/"):
        return None
    data = _read_up_to(response, MAX_BYTES, True)
    if not data:
        return None
    return {"body": data, "type": type}


def fetch_icon(origin: str, now: int | None = None, fetcher: Fetcher | None = None) -> dict[str, Any] | None:
    """The site's icon, or None when it has none that can be fetched. `now` is in milliseconds, the wall clock
    when left out; `fetcher` makes the requests."""
    if now is None:
        now = time.time_ns() // 1_000_000
    cached = _fresh(origin, now)
    if cached is not None:
        return cached[0]
    with _guard:
        lock = _pending.setdefault(origin, threading.Lock())
    with lock:
        # Another thread may have looked it up while this one waited.
        cached = _fresh(origin, now)
        if cached is not None:
            return cached[0]
        try:
            return _look_up(origin, now, fetcher)
        finally:
            with _guard:
                _pending.pop(origin, None)


def _fresh(origin: str, now: int) -> tuple[dict[str, Any] | None] | None:
    """The cached icon, wrapped so that a remembered "no icon" can be told from nothing cached."""
    cached = _cache.get(origin)
    if cached is not None and now - cached["at"] < (DAY if cached["icon"] else DAY // 24):
        return (cached["icon"],)
    return None


def _look_up(origin: str, now: int, fetcher: Fetcher | None) -> dict[str, Any] | None:
    icon = None
    # The head is all that is needed, so a huge page is not read to the end.
    page = _get(f"{origin}/", fetcher, {"maxBytes": 200_000, "truncate": True})
    if page is not None and page.ok and "html" in (page.headers.get("content-type") or ""):
        html = _js.utf8(_read_up_to(page, 200_000, False) or b"")
        # The answer has no url of its own, as the one Node's https module gives, so links resolve against the
        # origin.
        for url in icon_links(html, origin)[:4]:
            icon = _image(url, fetcher)
            if icon is not None:
                break
    if icon is None:
        icon = _image(f"{origin}/favicon.ico", fetcher)
    with _guard:
        # As Map.set, an origin already cached keeps its place.
        _cache[origin] = {"at": now, "icon": icon}
        if len(_cache) > CACHE_SIZE:
            del _cache[next(iter(_cache))]
    return icon
