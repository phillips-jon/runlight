"""Runlight: privacy friendly web analytics that lives inside your Python app.

    from runlight import Runlight
    from runlight.store import Stores

    rl = Runlight(store=Stores.sqlite("./data/runlight.db"), site={"name": "example.com", "hostnames": ["example.com"]})
    routes = rl.routes()          # routes.handle(request) answers /runlight/*
    # or mount it: runlight.wsgi, runlight.asgi, runlight.django, runlight.flask, runlight.fastapi

Then add <script defer src="/runlight/s.js"></script> to your pages.
"""

from __future__ import annotations

from typing import Any

from .http import Headers, Request, Response, Url

__all__ = [
    "API_VERSION",
    "LINK_DOMAIN_CHECK",
    "SESSION_IDLE_MS",
    "VERSION",
    "Headers",
    "Request",
    "Response",
    "Runlight",
    "SettingsError",
    "Stores",
    "Url",
    "runlight",
]


def runlight(options: Any = None, **kwargs: Any) -> Any:
    """A Runlight, as runlight() in the TypeScript SDK makes one."""
    from .core import Runlight

    return Runlight(options, **kwargs)


def __getattr__(name: str) -> Any:
    if name in ("Runlight", "SettingsError", "SESSION_IDLE_MS", "LINK_DOMAIN_CHECK"):
        from . import core

        return getattr(core, name)
    if name == "Stores":
        from .store import Stores

        return Stores
    if name in ("VERSION", "API_VERSION"):
        from . import version

        return getattr(version, name)
    raise AttributeError(name)
