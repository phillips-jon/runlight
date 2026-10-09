"""Link imports from other shorteners, a step at a time."""

from __future__ import annotations

import math
from typing import Any

from .. import _js
from .bitly import bitly
from .dub import dub
from .http import Http
from .rebrandly import rebrandly
from .shortio import shortio
from .types import Credentials, Importer, ImportError
from .umami import umami
from .write import imported_link_id, same_url, write_link

IMPORTERS: dict[str, Importer] = {"umami": umami, "dub": dub, "bitly": bitly, "shortio": shortio, "rebrandly": rebrandly}


def import_step(runlight: Any, site: str, source: str, credentials: Credentials, cursor: str | None, done: int | float) -> dict[str, Any]:
    """One step of an import: fetch the next few links from the source, write
    each with its history, and report progress. The cursor carries where to
    pick up, so the page calls this until the cursor comes back None.

    The importer makes its requests through the Runlight's fetcher, and reads the Runlight's clock as its `now`."""
    importer = IMPORTERS.get(source)
    if importer is None:
        raise ImportError(f"Runlight cannot import from {source}", "import_source", {"source": source})
    runlight.init()

    def known(source_id: Any, slug: Any = None, url: Any = None) -> bool:
        if runlight.store.link_by_id(imported_link_id(source, _js.string(source_id))):
            return True
        if not _js.truthy(slug) or not _js.truthy(url):
            return False
        taken = runlight.store.link_by_slug(_js.string(slug))
        return bool(taken and same_url(taken["url"], _js.string(url)))

    result = importer.step({"credentials": credentials, "cursor": cursor, "known": known, "now": runlight.now(), "http": Http(runlight.fetcher)})
    step: dict[str, Any] = {"cursor": result["cursor"], "done": done, "total": result["total"], "links": 0, "clicks": 0, "skipped": 0, "failed": []}
    for item in result["links"]:
        if item.get("known"):
            step["done"] += 1
            step["skipped"] += 1
            continue
        written = write_link(runlight, site, source, item["link"], item)
        step["done"] += 1
        if written["status"] == "created":
            step["links"] += 1
            step["clicks"] += written["clicks"]
        elif written["status"] == "skipped":
            step["skipped"] += 1
        else:
            failed: dict[str, Any] = {"slug": item["link"]["slug"], "reason": written.get("reason") or ""}
            if written.get("code"):
                failed["code"] = written["code"]
                failed["params"] = written.get("params") or {}
            step["failed"].append(failed)
    # Links the source skipped (deleted ones) still count toward progress.
    total = result["total"]
    if not result["cursor"] and total is not None:
        n = _js.number(total)
        step["done"] = math.nan if math.isnan(n) else max(step["done"], n)
    return step
