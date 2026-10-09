"""Runlight in front of a Flask app, through Flask's test client, and `flask runlight check`."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from adapter_scenario import APP_PAGE, Answer, check_everything, make_runlight, routes_for
from flask import Flask

import runlight.flask
from runlight import _js


def flask_app(rl: Any) -> Flask:
    app = Flask("adapter_test")

    @app.get("/hello")
    def hello() -> str:
        return APP_PAGE

    runlight.flask.init_app(app, rl, routes_for(rl))
    return app


def flask_client(app: Flask) -> Any:
    client = app.test_client()

    def call(method: str, path: str, headers: Mapping[str, str] | None = None, body: bytes = b"", host: str = "example.com") -> Answer:
        answer = client.open(
            path,
            method=method,
            headers=dict(headers or {}),
            data=body,
            base_url=f"https://{host}",
            environ_overrides={"REMOTE_ADDR": "203.0.113.9"},
        )
        return Answer(answer.status_code, list(answer.headers.items()), answer.get_data())

    return call


def test_everything_through_flask() -> None:
    rl = make_runlight()
    check_everything(rl, flask_client(flask_app(rl)))


def test_init_app_gives_the_routes_and_keeps_the_runlight() -> None:
    rl = make_runlight()
    app = Flask("adapter_test")
    routes = runlight.flask.init_app(app, rl, token="app-token")
    assert app.extensions["runlight"] is rl
    assert routes is not None
    answer = app.test_client().get("/runlight/api/sites", headers={"authorization": "Bearer app-token"})
    assert answer.status_code == 200


def test_the_check_command() -> None:
    rl = make_runlight()
    app = flask_app(rl)
    result = app.test_cli_runner().invoke(args=["runlight", "check"])
    assert result.exit_code == 0, result.output
    assert isinstance(_js.loads(result.output), dict)
