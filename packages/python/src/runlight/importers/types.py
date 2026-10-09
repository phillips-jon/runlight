"""The shapes every link importer hands back, as dicts with the TypeScript's keys.

- ForeignLink, a link as another shortener describes it, before it becomes a Runlight link: `sourceId` (the
  other service's id, so a re-run recognises the link), `slug`, `domain` (the short link's domain there;
  shortener-owned domains such as bit.ly and dub.sh are not kept), `name`, `url`, and `createdAt` (ms).
- ForeignClick, one click with whatever the other service knows about it: `ts` (ms), and whichever of `visit`
  (groups clicks into one visit, when the service has visits), `referrer`, `path` and `query` (of the short URL
  as clicked, for campaign tags), `country`, `region`, `city`, `browser`, `os`, `device`, `screen`, and
  `language` the service gives. A field it does not give is left out; one it gives as null stays None.
- DailyClicks, clicks per day for services that only keep counts: `day` (YYYY-MM-DD, UTC) and `clicks`.
- ImportStep, what one step of an import did (the page keeps calling until `cursor` is None): `cursor`, `done`
  and `total` (links handled so far and in all, for the progress bar; total is None when the service does not
  say), `links`, `clicks`, `skipped`, and `failed` (a list of {slug, reason, code?, params?}).

An importer is an object with `step(input)`: it does a bounded slice of work (a few links) and hands back a
cursor, so imports run in small requests that fit any host's time limit and can show progress. Credentials come
with every step and are never stored. `input` holds:

- credentials: dict[str, str]
- cursor: str | None
- known: callable(source_id, slug=None, url=None) -> bool, whether a link from this source is already in
  Runlight, so its history need not be fetched again: imported from this source before, or the same slug to the
  same destination brought in some other way
- now: Runlight's clock, in milliseconds: the date of a link the source gives none for, and where Umami's
  history ends
- http: the importers.http.Http its requests go through (the Runlight's fetcher); a default one when left out

and it returns {cursor, total, links: [{link, clicks?, daily?, known?}]}.
"""

from __future__ import annotations

from typing import Any, Protocol

Credentials = dict[str, str]


class Importer(Protocol):
    def step(self, input: dict[str, Any]) -> dict[str, Any]: ...


class ImportError(Exception):  # noqa: A001 (the TypeScript's name, kept)
    """Why an import stopped, as a code the dashboard says in its own words."""

    def __init__(self, message: str, code: str, params: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = params or {}
