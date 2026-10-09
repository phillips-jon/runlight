"""Where a visitor is, from a hosting platform's headers or a database lookup.

A Location is a dict {"country", "region", "city"}: the country ISO 3166-1 alpha-2 in upper case, the region
ISO 3166-2 such as "US-CA". A GeoLookup is a callable(ip) giving a dict with any of those keys, or None, such as
one made from an MMDB file.

Where the TypeScript would throw a TypeError on a value of the wrong type (a number for a city), this raises one
too, and the callers catch it where the TypeScript does.
"""

from __future__ import annotations

import base64
import binascii
import re
from collections.abc import Callable
from typing import Any

from . import _js
from .http import Headers

GeoLookup = Callable[[str], "dict[str, Any] | None"]

EMPTY = {"country": "", "region": "", "city": ""}


def _decode(value: str | None) -> str:
    if not value:
        return ""
    decoded = _js.decode_uri_component(value)
    return _js.trim(decoded if decoded is not None else value)


def _text(value: Any) -> str:
    """`value ?? ""`, which must then be a string: anything else has no string methods in JavaScript."""
    if value is None or value is _js.UNDEFINED:
        return ""
    if not isinstance(value, str):
        raise TypeError("Not a string")
    return value


_COUNTRY = re.compile(r"[A-Z]{2}\Z")
_REGION_CODE = re.compile(r"([A-Za-z]{2}-)?[A-Za-z0-9]{1,3}\Z")
_REGION_PREFIX = re.compile(r"[A-Z]{2}-")


def _clean(location: dict[str, Any]) -> dict[str, str]:
    country = _js.slice16(_text(location.get("country")).upper(), 0, 2)
    if not _COUNTRY.match(country) or country in ("XX", "T1"):
        country = ""
    # A code ("CA", "US-CA") is kept as ISO 3166-2; a name from a database
    # that has no codes ("California") is kept readable, as "US-California".
    raw = _js.trim(_text(location.get("region")))
    region = raw.upper() if _REGION_CODE.match(raw) else _js.slice16(raw, 0, 80)
    if region and not _REGION_PREFIX.match(region) and country:
        region = f"{country}-{region}"
    if not country:
        region = ""
    city = _js.slice16(_text(location.get("city")), 0, 100) if country else ""
    return {"country": country, "region": region, "city": city}


def _field(value: Any, key: str) -> Any:
    """`value?.key` on a parsed JSON value: None (undefined) for anything but an object holding the key."""
    return value.get(key) if isinstance(value, dict) else None


_ATOB_SPACE = re.compile("[\t\n\f\r ]")
_ATOB_ALPHABET = re.compile(r"[A-Za-z0-9+/]*\Z")


def _atob(text: str) -> str:
    """atob(): forgiving base64 to a binary string, each byte one character. Raises ValueError where it throws."""
    text = _ATOB_SPACE.sub("", text)
    if len(text) % 4 == 0:
        text = re.sub(r"={1,2}\Z", "", text)
    if len(text) % 4 == 1 or not _ATOB_ALPHABET.match(text):
        raise ValueError("The string to be decoded is not correctly encoded.")
    try:
        data = base64.b64decode(text + "=" * (-len(text) % 4))
    except binascii.Error as error:
        raise ValueError("The string to be decoded is not correctly encoded.") from error
    return data.decode("latin-1")


def location_from_headers(headers: Headers) -> dict[str, str] | None:
    """Location from the headers a hosting platform adds, if any."""
    vercel = headers.get("x-vercel-ip-country")
    if vercel:
        return _clean(
            {
                "country": vercel,
                "region": _decode(headers.get("x-vercel-ip-country-region")),
                "city": _decode(headers.get("x-vercel-ip-city")),
            }
        )
    cloudflare = headers.get("cf-ipcountry")
    if cloudflare:
        return _clean(
            {
                "country": cloudflare,
                "region": _decode(headers.get("cf-region-code")),
                "city": _decode(headers.get("cf-ipcity")),
            }
        )
    netlify = headers.get("x-nf-geo")
    if netlify:
        try:
            geo = _js.loads(_atob(netlify))
            if geo is None:
                # Reading a field of null is a TypeError.
                return None
            country = _field(_field(geo, "country"), "code")
            region = _field(_field(geo, "subdivision"), "code")
            city = _field(geo, "city")
            return _clean(
                {
                    "country": country if country is not None else "",
                    "region": region if region is not None else "",
                    "city": city if city is not None else "",
                }
            )
        except (ValueError, TypeError, RecursionError):
            return None
    return None


def locate(headers: Headers, ip: str, lookup: GeoLookup | None = None) -> dict[str, str]:
    from_headers = location_from_headers(headers)
    if from_headers is not None and from_headers["country"]:
        return from_headers
    if lookup is not None and ip:
        try:
            found = lookup(ip)
            if _js.truthy(found):
                return _clean(found)  # type: ignore[arg-type]
        except Exception:
            # A broken lookup must never lose the event.
            pass
    return dict(EMPTY)
