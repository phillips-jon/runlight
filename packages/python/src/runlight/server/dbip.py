"""Location for servers with no platform headers (Cloudflare, Vercel, and
Netlify send their own, and those always win), from DB-IP's free databases
(CC BY 4.0, https://db-ip.com), or any MMDB file the owner points at.

The port of packages/server/src/geo.ts. Downloaded on first start and
refreshed each month; lookups read the open file a page at a time.
"""

from __future__ import annotations

import datetime
import gzip
import os
import re
import shutil
import urllib.error
import urllib.request
from collections.abc import Callable
from typing import Any

from .. import _js
from ..http import Fetcher
from ..mmdb import Mmdb

GeoLookup = Callable[[str], "dict[str, Any] | None"]

_DISTRICT = re.compile(f"[{_js.WHITESPACE}]*\\([^)]*\\)[{_js.WHITESPACE}]*\\Z")


def city_name(name: str) -> str:
    """A city as people say it: DB-IP adds districts in brackets, as in "Toronto (Old Toronto)"."""
    return _js.trim(_DISTRICT.sub("", name, count=1))


def _at(value: Any, *path: str | int) -> Any:
    """value?.a?.b, through a record read from a database: None where a step is missing."""
    for key in path:
        if isinstance(value, dict) and isinstance(key, str) and key in value:
            value = value[key]
        elif isinstance(value, list) and isinstance(key, int) and 0 <= key < len(value):
            value = value[key]
        else:
            return None
    return value


def lookup_from(reader: Any) -> GeoLookup:
    """A lookup from anything with get(ip): the Mmdb reader, or a stand-in. DB-IP's records follow MaxMind's city
    layout, with names but no subdivision codes. A lookup that fails answers None."""

    def lookup(ip: str) -> dict[str, Any] | None:
        try:
            found = reader.get(ip)
        except Exception:
            return None
        country = _at(found, "country", "iso_code")
        if not _js.truthy(country):
            return None
        sub = _at(found, "subdivisions", 0)
        region = _at(sub, "iso_code")
        if region is None:
            region = _at(sub, "names", "en")
        city = _at(found, "city", "names", "en")
        city = "" if city is None else city
        return {"country": country, "region": "" if region is None else region, "city": city_name(city) if isinstance(city, str) else city}

    return lookup


def file_lookup(file: str) -> GeoLookup:
    """A lookup from an MMDB file the owner supplies, such as MaxMind's GeoLite2 City."""
    return lookup_from(Mmdb.open(file))


def month(ms: int) -> str:
    """"2026-10", the month DB-IP names each release after."""
    return (datetime.datetime(1970, 1, 1, tzinfo=datetime.UTC) + datetime.timedelta(milliseconds=ms)).strftime("%Y-%m")


def _download(url: str, file: str) -> bool:
    """Downloads a file straight to disk, since a city database is too big to hold in memory. Says whether it got
    one."""
    if not url.startswith("https://"):
        return False
    try:
        with urllib.request.urlopen(url, timeout=600) as answer:  # noqa: S310 (https only, checked above)
            if answer.status != 200 or not answer.geturl().startswith("https://"):
                return False
            with open(file, "wb") as out:
                shutil.copyfileobj(answer, out, 1 << 20)
        return True
    except urllib.error.HTTPError:
        return False


class DbIp:
    """Keeps a DB-IP database current in `dir` and answers lookups from it, as the TS server's Geo does. `mode` is
    "city" or "country". `lookup` answers nothing until the first file opens, so startup never waits; refresh()
    opens the newest file on disk, then fetches this month's if it is missing, and is safe to call often.

    The download goes through `fetcher` when one is given (it holds the whole answer in memory), else straight to
    disk with urllib, since a city database is large."""

    def __init__(self, dir: str, mode: str, log: Callable[[str], None] = print, fetcher: Fetcher | None = None) -> None:
        self.dir = dir
        self.mode = mode
        self._log = log
        self._fetcher = fetcher
        self._reader: Mmdb | None = None
        self._loaded = ""
        os.makedirs(dir, exist_ok=True)

    def lookup(self, ip: str) -> dict[str, Any] | None:
        return lookup_from(self._reader)(ip) if self._reader is not None else None

    def _file(self, release: str) -> str:
        return os.path.join(self.dir, f"dbip-{self.mode}-lite-{release}.mmdb")

    def newest(self) -> str | None:
        """The newest release on disk, or None before the first download."""
        found = sorted(
            name for name in os.listdir(self.dir) if name.startswith(f"dbip-{self.mode}-lite-") and name.endswith(".mmdb")
        )
        return os.path.join(self.dir, found[-1]) if found else None

    def _open(self, file: str) -> None:
        reader = Mmdb.open(file)
        if self._reader is not None:
            self._reader.close()
        self._reader = reader
        self._loaded = os.path.basename(file)[-12:-5]

    def refresh(self, now: int) -> None:
        """Opens the newest file on disk, then fetches this month's if it is missing. Safe to call often."""
        current = month(now)
        if self._loaded == current:
            return
        newest = self.newest()
        if newest and os.path.basename(newest) != os.path.basename(self._file(self._loaded or "none")):
            self._open(newest)
        if os.path.isfile(self._file(current)):
            return
        self._fetch(current, now)

    def _get(self, url: str, file: str) -> bool:
        if self._fetcher is None:
            return _download(url, file)
        answer = self._fetcher.fetch(url, {"timeoutMs": 10 * 60_000})
        if not answer.ok:
            return False
        with open(file, "wb") as out:
            out.write(answer.content())
        return True

    def _fetch(self, release: str, now: int) -> None:
        # A new month's file appears a day or so after the month starts; until then, last month's is current.
        today = datetime.datetime(1970, 1, 1, tzinfo=datetime.UTC) + datetime.timedelta(milliseconds=now)
        last_month = (today.replace(day=15) - datetime.timedelta(days=30)).strftime("%Y-%m")
        for name in (release, last_month):
            if os.path.isfile(self._file(name)):
                if self._loaded != name:
                    self._open(self._file(name))
                return
            url = f"https://download.db-ip.com/free/dbip-{self.mode}-lite-{name}.mmdb.gz"
            gz = f"{self._file(name)}.gz.partial"
            partial = f"{self._file(name)}.partial"
            try:
                if not self._get(url, gz):
                    continue
                with gzip.open(gz, "rb") as source, open(partial, "wb") as out:
                    shutil.copyfileobj(source, out, 1 << 20)
                # A file that does not open as a database is never kept.
                Mmdb.open(partial).close()
                os.replace(partial, self._file(name))
                self._open(self._file(name))
                # Older releases go once the new one opens.
                for old in os.listdir(self.dir):
                    if old.startswith(f"dbip-{self.mode}-lite-") and old != os.path.basename(self._file(name)):
                        try:
                            os.unlink(os.path.join(self.dir, old))
                        except OSError:
                            pass
                self._log(f"Runlight: location data from DB-IP ({name}) is ready.")
                return
            except Exception as error:
                self._log(f"Runlight: could not download location data from {url}: {error}")
            finally:
                for leftover in (gz, partial):
                    try:
                        os.unlink(leftover)
                    except OSError:
                        pass
