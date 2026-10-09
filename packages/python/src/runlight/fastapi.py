"""Runlight in a FastAPI (or Starlette) app.

    from fastapi import FastAPI
    from runlight import Runlight
    from runlight.store import Stores
    import runlight.fastapi

    app = FastAPI()
    rl = Runlight(store=Stores.sqlite("data/runlight.db"), site={"hostnames": ["example.com"]})
    runlight.fastapi.init_app(app, rl)

The dashboard and API answer under /runlight, short links at /go/{slug}, and any link domain added in Settings,
in front of the app's own routes (through runlight.asgi.RunlightMiddleware). Page requests from known AI agents are
recorded on the way. Runlight's work runs in worker threads, off the event loop.
"""

from __future__ import annotations

from typing import Any

from .asgi import RunlightMiddleware


def init_app(app: Any, runlight: Any, routes: Any = None, observe: bool = True, **routes_options: Any) -> None:
    """Adds Runlight as middleware in front of a FastAPI or Starlette app. Routes options (the TS RoutesOptions, in
    snake_case: base_path, token, accounts, origin, ...) go to runlight.routes() when no routes are given."""
    if routes is None:
        routes = runlight.routes(**routes_options)
    app.add_middleware(RunlightMiddleware, runlight=runlight, routes=routes, observe=observe)
    app.state.runlight = runlight
