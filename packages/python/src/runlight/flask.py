"""Runlight in a Flask app.

    from runlight import Runlight
    from runlight.store import Stores
    import runlight.flask

    rl = Runlight(store=Stores.sqlite("data/runlight.db"), site={"hostnames": ["example.com"]})
    runlight.flask.init_app(app, rl)

The dashboard and API answer under /runlight, short links at /go/{slug}, and any link domain added in Settings,
in front of the app's own views (through runlight.wsgi.RunlightMiddleware). Page requests from known AI agents are
recorded on the way. `flask runlight check` runs the scheduled upkeep, for cron.
"""

from __future__ import annotations

from typing import Any

try:
    import flask  # noqa: F401
except ImportError as error:  # pragma: no cover
    raise ImportError("runlight.flask needs Flask: pip install flask") from error

from .wsgi import RunlightMiddleware


def init_app(app: Any, runlight: Any, routes: Any = None, observe: bool = True, **routes_options: Any) -> Any:
    """Serves Runlight in front of a Flask app and adds the `flask runlight check` command. Routes options (the
    TS RoutesOptions, in snake_case: base_path, token, accounts, origin, ...) go to runlight.routes() when no routes
    are given. Gives the routes."""
    middleware = RunlightMiddleware(app.wsgi_app, runlight, routes, observe, **routes_options)
    app.wsgi_app = middleware
    app.extensions["runlight"] = runlight

    import click
    from flask.cli import AppGroup

    group = AppGroup("runlight", help="Runlight's scheduled upkeep.")

    @group.command("check")
    def check() -> None:
        """Rotates salts, sends due reports, applies retention, and builds rollups."""
        from . import _js

        click.echo(_js.dumps(runlight.check()))

    app.cli.add_command(group)
    return middleware.front.routes
