"""The WSGI middleware, called as a WSGI server calls it, and served by wsgiref on a real socket."""

from __future__ import annotations

import http.client
import io
import threading
from collections.abc import Iterator, Mapping
from typing import Any
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server

import pytest
from adapter_scenario import APP_PAGE, CHROME, NOW, Answer, check_everything, make_runlight, routes_for

from runlight import _js
from runlight.wsgi import RunlightMiddleware, app, to_request


def hello_app(environ: Mapping[str, Any], start_response: Any) -> list[bytes]:
    start_response("200 OK", [("content-type", "text/plain")])
    return [APP_PAGE.encode()]


def wsgi_client(application: Any) -> Any:
    def call(method: str, path: str, headers: Mapping[str, str] | None = None, body: bytes = b"", host: str = "example.com") -> Answer:
        target, _, query = path.partition("?")
        environ: dict[str, Any] = {
            "REQUEST_METHOD": method,
            "SCRIPT_NAME": "",
            "PATH_INFO": target,
            "QUERY_STRING": query,
            "SERVER_NAME": host,
            "SERVER_PORT": "443",
            "SERVER_PROTOCOL": "HTTP/1.1",
            "REMOTE_ADDR": "203.0.113.9",
            "HTTP_HOST": host,
            "wsgi.url_scheme": "https",
            "wsgi.input": io.BytesIO(body),
            "wsgi.errors": io.StringIO(),
            "wsgi.version": (1, 0),
            "wsgi.multithread": True,
            "wsgi.multiprocess": False,
            "wsgi.run_once": False,
        }
        if body:
            environ["CONTENT_LENGTH"] = str(len(body))
        for name, value in (headers or {}).items():
            key = name.upper().replace("-", "_")
            if key in ("CONTENT_TYPE", "CONTENT_LENGTH"):
                environ[key] = value
            else:
                environ[f"HTTP_{key}"] = value
        started: dict[str, Any] = {}

        def start_response(status: str, pairs: list[tuple[str, str]], exc_info: Any = None) -> None:
            started["status"] = int(status.split(" ")[0])
            started["headers"] = pairs

        result = application(environ, start_response)
        try:
            data = b"".join(result)
        finally:
            close = getattr(result, "close", None)
            if close is not None:
                close()
        return Answer(started["status"], started["headers"], data)

    return call


def test_everything_through_the_middleware() -> None:
    rl = make_runlight()
    check_everything(rl, wsgi_client(RunlightMiddleware(hello_app, rl, routes_for(rl))))


def test_runlight_on_its_own_answers_404_elsewhere_and_observes_nothing() -> None:
    rl = make_runlight()
    check_everything(rl, wsgi_client(app(rl, routes_for(rl))), passes_through=False, observes=False)


def test_the_request_keeps_its_path_query_and_address() -> None:
    environ = {
        "REQUEST_METHOD": "POST",
        "PATH_INFO": "/runlight/api/cafÃ©",
        "QUERY_STRING": "site=a&b=%2F",
        "HTTP_HOST": "example.com",
        "HTTP_X_FORWARDED_PROTO": "https",
        "HTTP_X_FORWARDED_FOR": "198.51.100.4",
        "REMOTE_ADDR": "203.0.113.9",
        "CONTENT_TYPE": "application/json",
        "CONTENT_LENGTH": "2",
        "wsgi.url_scheme": "http",
        "wsgi.input": io.BytesIO(b"{}"),
    }
    request = to_request(environ)
    assert request.url == "https://example.com/runlight/api/caf%C3%A9?site=a&b=%2F"
    assert request.remote_address == "203.0.113.9"
    assert request.headers.get("x-forwarded-for") == "198.51.100.4"
    assert request.headers.get("content-type") == "application/json"
    assert request.text() == "{}"


class _Quiet(WSGIRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        pass


@pytest.fixture
def served() -> Iterator[tuple[Any, int]]:
    rl = make_runlight()
    server = make_server("127.0.0.1", 0, RunlightMiddleware(hello_app, rl, routes_for(rl)), WSGIServer, _Quiet)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield rl, server.server_address[1]
    server.shutdown()
    server.server_close()


def test_a_real_server_carries_cookies_and_bodies(served: tuple[Any, int]) -> None:
    rl, port = served
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request("GET", "/runlight/cookies", headers={"host": "example.com"})
    answer = connection.getresponse()
    answer.read()
    assert answer.status == 200
    assert answer.headers.get_all("set-cookie") == [
        "a=1; Path=/; HttpOnly; SameSite=Lax",
        "b=2; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT",
    ]
    body = _js.dumps({"k": "pageview", "u": "https://example.com/post"})
    connection.request("POST", "/runlight/e", body=body, headers={"host": "example.com", "user-agent": CHROME})
    hit = connection.getresponse()
    hit.read()
    assert hit.status == 202
    connection.request("GET", "/hello", headers={"host": "example.com"})
    page = connection.getresponse()
    assert page.read().decode() == APP_PAGE
    connection.close()
    # A body too large is a 413 the server can send: no hop-by-hop header, which wsgiref would turn into a 500.
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request("POST", "/runlight/e", body=b"x" * (20 * 1024), headers={"host": "example.com"})
    large = connection.getresponse()
    large.read()
    assert large.status == 413
    connection.close()
    assert rl.store.db.all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview' AND ts = ?", [NOW])[0]["n"] == 1
