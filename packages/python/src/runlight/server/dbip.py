"""Location for servers with no platform headers (Cloudflare, Vercel, and
Netlify send their own, and those always win), from DB-IP's free databases
(CC BY 4.0, https://db-ip.com), or any MMDB file the owner points at.

The port of packages/server/src/geo.ts, split as the PHP port splits it: the
scheduled check downloads each month's release with refresh(), and requests
read the newest file on disk with lookup(), a page at a time.
"""

from __future__ import annotations

import datetime
import glob
import gzip
import os
import re
import shutil
import sys
import urllib.error
import urllib.request
from collections.abc import Callable
from typing import Any

from .. import _js
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
    """Downloads a file straight to disk, since a city database is too big to hold in memory. This is the one
    download that does not go through a Fetcher, which keeps whole answers in memory. Says whether it got one."""
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
    """Keeps a DB-IP database current in `dir` and answers lookups from the newest one there. `mode` is "city" or
    "country". `download(url, file)` writes the gzipped file at the URL to the file and says whether it got one;
    `log` takes each line it has to say."""

    def __init__(
        self,
        dir: str,
        mode: str,
        download: Callable[[str, str], bool] | None = None,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self.dir = dir
        self.mode = mode
        self._download = download or _download
        self._log = log or (lambda line: print(line, file=sys.stderr))

    def _file(self, release: str) -> str:
        return os.path.join(self.dir, f"dbip-{self.mode}-lite-{release}.mmdb")

    def newest(self) -> str | None:
        """The newest release on disk, or None before the first download."""
        found = sorted(glob.glob(os.path.join(glob.escape(self.dir), f"dbip-{self.mode}-lite-*.mmdb")))
        return found[-1] if found else None

    def lookup(self) -> GeoLookup | None:
        """A lookup answering from the newest release on disk, opened at the first lookup, or None when there is
        none yet. Lookups that fail answer nothing, as they do before the first download in TypeScript."""
        file = self.newest()
        if file is None:
            return None
        opened: list[GeoLookup] = []

        def lookup(ip: str) -> dict[str, Any] | None:
            if not opened:
                try:
                    opened.append(lookup_from(Mmdb.open(file)))
                except Exception:
                    return None
            return opened[0](ip)

        return lookup

    def refresh(self, now: int) -> None:
        """Fetches this month's release when it is missing. A new month's file appears a day or so after the month
        starts, so until then last month's is fetched when that is missing too. Older releases go once a new
        one is ready. Safe to call often: once this month's file is there it reads only the folder."""
        current = month(now)
        if os.path.isfile(self._file(current)):
            return
        try:
            os.makedirs(self.dir, exist_ok=True)
        except OSError:
            self._log(f"Runlight: could not make the folder for location data, {self.dir}")
            return
        today = datetime.datetime(1970, 1, 1, tzinfo=datetime.UTC) + datetime.timedelta(milliseconds=now)
        last_month = (today.replace(day=15) - datetime.timedelta(days=30)).strftime("%Y-%m")
        for release in (current, last_month):
            if os.path.isfile(self._file(release)):
                return
            url = f"https://download.db-ip.com/free/dbip-{self.mode}-lite-{release}.mmdb.gz"
            gz = f"{self._file(release)}.gz.partial"
            partial = f"{self._file(release)}.partial"
            try:
                if not self._download(url, gz):
                    continue
                with gzip.open(gz, "rb") as source, open(partial, "wb") as out:
                    shutil.copyfileobj(source, out, 1 << 20)
                # A file that does not open as a database is never kept.
                Mmdb.open(partial).close()
                os.replace(partial, self._file(release))
                for old in glob.glob(os.path.join(glob.escape(self.dir), f"dbip-{self.mode}-lite-*")):
                    if old != self._file(release):
                        try:
                            os.unlink(old)
                        except OSError:
                            pass
                self._log(f"Runlight: location data from DB-IP ({release}) is ready.")
                return
            except Exception as error:
                self._log(f"Runlight: could not download location data from {url}: {error}")
            finally:
                for leftover in (gz, partial):
                    try:
                        os.unlink(leftover)
                    except OSError:
                        pass
