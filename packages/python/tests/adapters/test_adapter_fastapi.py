"""Runlight in front of a FastAPI app, through FastAPI's TestClient."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from adapter_scenario import APP_PAGE, Answer, check_everything, make_runlight, routes_for
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
from fastapi.testclient import TestClient

import runlight.fastapi


def fastapi_app(rl: Any, **options: Any) -> FastAPI:
    app = FastAPI()

    @app.get("/hello", response_class=PlainTextResponse)
    def hello() -> str:
        return APP_PAGE

    if options:
        runlight.fastapi.init_app(app, rl, **options)
    else:
        runlight.fastapi.init_app(app, rl, routes_for(rl))
    return app


def fastapi_client(app: FastAPI) -> Any:
    client = TestClient(app, client=("203.0.113.9", 50000))

    def call(method: str, path: str, headers: Mapping[str, str] | None = None, body: bytes = b"", host: str = "example.com") -> Answer:
        answer = client.request(method, f"https://{host}{path}", headers=dict(headers or {}), content=body or None, follow_redirects=False)
        return Answer(answer.status_code, list(answer.headers.multi_items()), answer.content)

    return call


def test_everything_through_fastapi() -> None:
    rl = make_runlight()
    check_everything(rl, fastapi_client(fastapi_app(rl)))


def test_routes_options_and_the_runlight_on_the_app() -> None:
    rl = make_runlight()
    app = fastapi_app(rl, token="app-token")
    assert app.state.runlight is rl
    with TestClient(app) as client:
        answer = client.get("https://example.com/runlight/api/sites", headers={"authorization": "Bearer app-token"})
        assert answer.status_code == 200
        assert client.get("https://example.com/hello").text == APP_PAGE
