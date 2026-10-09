"""Runlight in a Django project configured here: the middleware through Django's test client and its WSGI and ASGI
handlers, the RUNLIGHT settings, and `manage.py runlight_check`."""

from __future__ import annotations

import asyncio
import io
from collections.abc import Iterator, Mapping
from typing import Any

import django
import pytest
from adapter_scenario import APP_PAGE, COOKIES, TOKEN, Answer, check_everything, make_runlight, routes_for
from django.conf import settings

if not settings.configured:
    settings.configure(
        DEBUG=False,
        SECRET_KEY="adapter-test",
        ALLOWED_HOSTS=["example.com", "links.example.org", "testserver"],
        INSTALLED_APPS=["runlight.django"],
        MIDDLEWARE=["runlight.django.RunlightMiddleware"],
        ROOT_URLCONF=__name__,
        DATABASES={},
        USE_TZ=True,
        RUNLIGHT=None,
    )
    django.setup()

from django.core.handlers.asgi import ASGIHandler  # noqa: E402
from django.core.handlers.wsgi import WSGIHandler  # noqa: E402
from django.core.management import call_command  # noqa: E402
from django.http import HttpResponse  # noqa: E402
from django.test import Client, override_settings  # noqa: E402
from django.urls import path  # noqa: E402

import runlight.django as runlight_django  # noqa: E402
from runlight import _js  # noqa: E402
from runlight.serve import Front  # noqa: E402


def hello(request: Any) -> HttpResponse:
    return HttpResponse(APP_PAGE, content_type="text/plain")


urlpatterns = [path("hello", hello)]


@pytest.fixture
def rl() -> Iterator[Any]:
    """A Runlight served by the middleware, with the scenario's routes (which add /runlight/cookies)."""
    made = make_runlight()
    with override_settings(RUNLIGHT=made):
        runlight_django.reset()
        runlight_django._front = Front(made, routes_for(made))
        yield made
    runlight_django.reset()


def django_client() -> Any:
    client = Client()

    def call(method: str, path: str, headers: Mapping[str, str] | None = None, body: bytes = b"", host: str = "example.com") -> Answer:
        given = dict(headers or {})
        content_type = given.pop("content-type", "application/octet-stream")
        answer = client.generic(
            method, path, data=body, content_type=content_type, secure=True, headers=given, HTTP_HOST=host, REMOTE_ADDR="203.0.113.9"
        )
        content = b"".join(answer.streaming_content) if answer.streaming else answer.content
        return Answer(answer.status_code, list(answer.items()), content)

    return call


def test_everything_through_django(rl: Any) -> None:
    check_everything(rl, django_client())


def test_set_cookie_lines_arrive_intact_through_the_wsgi_handler(rl: Any) -> None:
    handler = WSGIHandler()
    started: dict[str, Any] = {}

    def start_response(status: str, headers: list[tuple[str, str]], exc_info: Any = None) -> None:
        started["status"] = status
        started["headers"] = headers

    environ = {
        "REQUEST_METHOD": "GET",
        "PATH_INFO": "/runlight/cookies",
        "QUERY_STRING": "",
        "SERVER_NAME": "example.com",
        "SERVER_PORT": "443",
        "HTTP_HOST": "example.com",
        "REMOTE_ADDR": "203.0.113.9",
        "wsgi.url_scheme": "https",
        "wsgi.input": io.BytesIO(b""),
        "wsgi.errors": io.StringIO(),
    }
    body = b"".join(handler(environ, start_response))
    assert started["status"].startswith("200")
    assert [v for k, v in started["headers"] if k.lower() == "set-cookie"] == COOKIES
    assert body == b"{}"


def test_set_cookie_lines_arrive_intact_through_the_asgi_handler(rl: Any) -> None:
    handler = ASGIHandler()
    sent: list[dict[str, Any]] = []
    scope = {
        "type": "http",
        "method": "GET",
        "path": "/runlight/cookies",
        "raw_path": b"/runlight/cookies",
        "query_string": b"",
        "scheme": "https",
        "headers": [(b"host", b"example.com")],
        "client": ("203.0.113.9", 1234),
        "server": ("example.com", 443),
    }

    messages = [{"type": "http.request", "body": b"", "more_body": False}]

    async def receive() -> dict[str, Any]:
        if messages:
            return messages.pop(0)
        # The client stays until the answer is sent.
        await asyncio.sleep(3600)
        return {"type": "http.disconnect"}

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    asyncio.run(handler(scope, receive, send))
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 200
    assert [v.decode() for k, v in start["headers"] if k.lower() == b"set-cookie"] == COOKIES


def test_the_settings_name_the_runlight_and_its_routes() -> None:
    made = make_runlight()
    with override_settings(RUNLIGHT=made, RUNLIGHT_ROUTES={"token": TOKEN}):
        runlight_django.reset()
        try:
            client = Client()
            answer = client.get("/runlight/api/sites", headers={"authorization": f"Bearer {TOKEN}"}, HTTP_HOST="example.com")
            assert answer.status_code == 200
            assert client.get("/runlight/api/sites", HTTP_HOST="example.com").status_code == 401
        finally:
            runlight_django.reset()
    with override_settings(RUNLIGHT=f"{__name__}:made_by_function"):
        assert runlight_django.runlight() is MADE


MADE = make_runlight()


def made_by_function() -> Any:
    return MADE


def test_the_check_command(rl: Any) -> None:
    out = io.StringIO()
    call_command("runlight_check", stdout=out)
    assert isinstance(_js.loads(out.getvalue()), dict)
