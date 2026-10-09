"""The SDK's version and the HTTP API's, read from assets/build.json, which scripts/python-assets.mts writes from
the TypeScript SDK, so the two always report the same."""

from __future__ import annotations

from typing import Any


def __getattr__(name: str) -> Any:
    from . import assets

    if name == "VERSION":
        return str(assets.BUILD["version"])
    if name == "API_VERSION":
        # Bumped when the HTTP API changes shape, so the dashboard and the hub can tell.
        return int(assets.BUILD["apiVersion"])
    raise AttributeError(name)
