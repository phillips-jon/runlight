"""Capped reads: body's checks, and the Fetcher's maxBytes, truncate, and resolve against a real server."""

from __future__ import annotations

import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import pytest

from runlight.body import BodyTooLong, read_json_capped, read_text_capped
from runlight.http import Response, UrllibFetcher


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        parts = urlsplit(self.path)
        if parts.path == "/bytes":
            n = int(parse_qs(parts.query)["n"][0])
            body = b"a" * n
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=UTF-8")
            self.end_headers()
            try:
                for at in range(0, n, 8192):
                    self.wfile.write(body[at : at + 8192])
            except (BrokenPipeError, ConnectionResetError):
                # The reader stopped at its cap.
                pass
            return
        body = f"host {self.headers.get('host')}".encode()
        self.send_response(200)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args: object) -> None:
        pass


@pytest.fixture(scope="module")
def port() -> Iterator[int]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server.server_address[1]
    server.shutdown()


def test_text_is_read_up_to_the_cap() -> None:
    assert read_text_capped(Response("hello"), 5) == "hello"
    assert read_json_capped(Response('{"a":1}'), 100) == {"a": 1}
    # As TextDecoder reads bytes that are not UTF-8.
    assert read_text_capped(Response(b"a\xffb"), 10) == "a�b"
    assert read_text_capped(Response(b"\xef\xbb\xbfx"), 10) == "x"
    with pytest.raises(BodyTooLong, match="Body over 4 bytes"):
        read_text_capped(Response("hello"), 4)


def test_a_streamed_body_is_read_only_as_far_as_the_cap() -> None:
    read: list[int] = []

    def chunks() -> Iterator[bytes]:
        for i in range(100):
            read.append(i)
            yield b"x" * 10

    with pytest.raises(BodyTooLong):
        read_text_capped(Response(chunks()), 25)
    assert read == [0, 1, 2]


def test_a_declared_length_over_the_cap_is_refused_unread() -> None:
    with pytest.raises(BodyTooLong):
        read_text_capped(Response("", 200, {"content-length": "1000"}), 10)


def test_the_fetcher_stops_reading_past_max_bytes(port: int) -> None:
    fetcher = UrllibFetcher()
    url = f"http://127.0.0.1:{port}/bytes?n=300000"
    assert len(fetcher.fetch(url, {"maxBytes": 300_000}).content()) == 300_000
    with pytest.raises(BodyTooLong, match="Body over 100000 bytes"):
        fetcher.fetch(url, {"maxBytes": 100_000})
    start = fetcher.fetch(url, {"maxBytes": 100_000, "truncate": True})
    assert start.status == 200
    # With truncate, the start comes back.
    assert start.text() == "a" * 100_000
    assert (start.headers.get("content-type") or "").split(";")[0] == "text/html"


def test_the_fetcher_connects_to_the_pinned_address(port: int) -> None:
    answer = UrllibFetcher().fetch(f"http://pinned.invalid:{port}/", {"resolve": [f"pinned.invalid:{port}:127.0.0.1"]})
    assert answer.text() == f"host pinned.invalid:{port}"
