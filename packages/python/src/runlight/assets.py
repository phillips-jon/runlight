"""The dashboard, the tracker, the world map, and the locales: the TypeScript SDK's generated files
(generated/dashboard.ts and generated/tracker.ts), which scripts/python-assets.mts copies into runlight/assets,
so this port serves the very same bytes. Each is read on first use.

DASHBOARD_JS, DASHBOARD_CSS, DASHBOARD_HASH, WORLD_JSON, WORLD_HASH, LOCALES (language to its messages as JSON
text, English left out), LOCALES_HASH, ENGLISH (the English messages as JSON text), TRACKER, TRACKER_HASH,
PICKER, and BUILD (assets/build.json: the versions, the hashes, and the icon).
"""

from __future__ import annotations

import functools
import json
from pathlib import Path
from typing import Any

DIR = Path(__file__).parent / "assets"


@functools.cache
def _text(name: str) -> str:
    try:
        return (DIR / name).read_text(encoding="utf-8")
    except FileNotFoundError:  # pragma: no cover
        raise RuntimeError(f"Runlight: assets/{name} is missing; run npm run python-assets.") from None


@functools.cache
def _build() -> dict[str, Any]:
    return json.loads(_text("build.json"))


@functools.cache
def _locales() -> dict[str, str]:
    return json.loads(_text("locales.json"))


def __getattr__(name: str) -> Any:
    if name == "BUILD":
        return _build()
    if name == "DASHBOARD_JS":
        return _text("dashboard.js")
    if name == "DASHBOARD_CSS":
        return _text("dashboard.css")
    if name == "WORLD_JSON":
        return _text("world.json")
    if name == "TRACKER":
        return _text("tracker.js")
    if name == "PICKER":
        return _text("picker.js")
    if name == "ENGLISH":
        return _locales()["en"]
    if name == "LOCALES":
        return {k: v for k, v in _locales().items() if k != "en"}
    hashes = {
        "DASHBOARD_HASH": "dashboardHash",
        "WORLD_HASH": "worldHash",
        "LOCALES_HASH": "localesHash",
        "TRACKER_HASH": "trackerHash",
    }
    if name in hashes:
        return str(_build()[hashes[name]])
    raise AttributeError(name)
