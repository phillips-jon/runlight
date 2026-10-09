"""Short links: create, change, delete, and import, with the rules every route shares.

LinkInput: {url, name?, slug?, domain?}, where domain is a link domain added in Settings, or "" (the default) for
the app's own.
"""

from __future__ import annotations

import re
import secrets
from typing import Any

from . import _js
from .hash import random_id
from .http import Url
from .sources import strip_www

SLUG_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}\Z")
_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"


def random_slug() -> str:
    """Six characters from an alphabet without look-alikes (no 0/o, 1/l)."""
    return "".join(_ALPHABET[b % len(_ALPHABET)] for b in secrets.token_bytes(6))


class LinkError(Exception):
    """A link that cannot be made. `code` and `params` let the dashboard say it in its own language."""

    def __init__(self, message: str, code: str, params: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = params or {}


def _text(value: Any) -> str:
    """String(value ?? "")."""
    return "" if value is None or value is _js.UNDEFINED else _js.string(value)


def _clean_url(value: Any) -> str:
    text = _js.trim(_text(value))
    url = Url.parse(text)
    if url is None:
        raise LinkError("The destination must be a full URL, starting with https://", "link_url")
    if url.protocol not in ("https:", "http:"):
        raise LinkError("The destination must start with http:// or https://", "link_protocol")
    if _js.length(text) > 2000:
        raise LinkError("The destination is longer than 2,000 characters", "link_long")
    return url.href


def _default_name(url: str) -> str:
    u = Url(url)
    return _js.cut(f"{strip_www(u.hostname)}{'' if u.pathname == '/' else u.pathname}", 100)


class Links:
    def __init__(self, runlight: Any) -> None:
        self._runlight = runlight

    def _domain_for(self, site: str, value: Any) -> str:
        domain = strip_www(_js.trim(_text(value)))
        if not domain:
            return ""
        known = self._runlight.store.link_domains()
        if not any(d["domain"] == domain and d["site"] == site for d in known):
            raise LinkError(f"Add {domain} as a link domain in Settings first", "link_domain", {"domain": domain})
        return domain

    def _free_slug(self, wanted: str | None, except_: str | None = None) -> str:
        """Slugs are unique across every domain, so a link can always fall back to the app's own path."""
        if wanted is not None and wanted != "":
            if not SLUG_PATTERN.match(wanted):
                raise LinkError("A slug is letters, digits, dashes, and underscores, up to 100", "link_slug")
            taken = self._runlight.store.link_by_slug(wanted)
            if taken and taken["id"] != except_:
                raise LinkError(f"/{wanted} is already taken", "link_taken", {"slug": wanted})
            return wanted
        for _ in range(8):
            slug = random_slug()
            if not self._runlight.store.link_by_slug(slug):
                return slug
        raise LinkError("Could not find a free slug; try again", "link_no_slug")

    def create(self, site: str, input: dict[str, Any]) -> dict[str, Any]:
        self._runlight.init()
        url = _clean_url(input.get("url"))
        domain = self._domain_for(site, input.get("domain"))
        slug = input.get("slug")
        slug = self._free_slug(_js.trim(slug) if slug is not None else None)
        now = self._runlight.now()
        name = input.get("name")
        link = {
            "id": random_id(),
            "site": site,
            "domain": domain,
            "slug": slug,
            "name": _js.cut((_js.trim(name) if name is not None else "") or _default_name(url), 100),
            "url": url,
            "createdAt": now,
            "updatedAt": now,
        }
        self._runlight.store.insert_link(link)
        return link

    def update(self, id: str, input: dict[str, Any]) -> dict[str, Any]:
        self._runlight.init()
        link = self._runlight.store.link_by_id(id)
        if not link:
            raise _js.RangeError("Unknown link")
        nxt = dict(link)
        if input.get("url") is not None:
            nxt["url"] = _clean_url(input["url"])
        if input.get("name") is not None:
            nxt["name"] = _js.cut(_js.trim(_js.string(input["name"])), 100) or _default_name(nxt["url"])
        # Keeping a link's domain needs no check, even while that domain is removed.
        if input.get("domain") is not None and strip_www(_js.trim(input["domain"])) != link["domain"]:
            nxt["domain"] = self._domain_for(link["site"], input["domain"])
        if input.get("slug") is not None:
            nxt["slug"] = self._free_slug(_js.trim(input["slug"]), link["id"])
        nxt["updatedAt"] = self._runlight.now()
        self._runlight.store.update_link(nxt)
        return nxt

    def remove(self, id: str) -> None:
        self._runlight.init()
        if not self._runlight.store.link_by_id(id):
            raise _js.RangeError("Unknown link")
        self._runlight.store.delete_link(id, self._runlight.now())

    def import_(self, site: str, rows: list[dict[str, Any]]) -> dict[str, Any]:
        """Creates many links at once, as from a CSV. Rows that fail are reported with their reason and the rest go
        in. Headers match the Umami fork's export: name or link_name, url or destination_url, slug or link_slug,
        domain or tracking_domain."""
        failed: list[dict[str, Any]] = []
        created = 0
        for i, raw in enumerate(rows):

            def pick(*keys: str, raw: dict[str, Any] = raw) -> str | None:
                for key in keys:
                    value = raw.get(key)
                    if isinstance(value, str) and _js.trim(value):
                        return _js.trim(value)
                return None

            given: dict[str, Any] = {"url": pick("url", "destination_url") or ""}
            for key, keys in (("name", ("name", "link_name")), ("slug", ("slug", "link_slug")), ("domain", ("domain", "tracking_domain"))):
                value = pick(*keys)
                if value is not None:
                    given[key] = value
            try:
                self.create(site, given)
                created += 1
            except LinkError as error:
                # A bad row is reported and skipped; a failing database stops the whole import.
                failed.append({"row": i + 1, "reason": error.message, "code": error.code, "params": error.params})
        return {"created": created, "failed": failed}
