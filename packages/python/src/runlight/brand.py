"""The Runlight mark."""

from __future__ import annotations

from typing import Any


def __getattr__(name: str) -> Any:
    if name == "RUNLIGHT_ICON":
        # The Runlight mark for the dashboard's tab: an R in a rounded lamp housing, one corner lit. A data: URL.
        from . import assets

        return str(assets.BUILD["icon"])
    raise AttributeError(name)
