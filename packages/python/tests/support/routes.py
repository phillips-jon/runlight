"""What the route tests share: a Runlight on an in-memory SQLite, and requests written as the TypeScript tests
write them."""

from __future__ import annotations

import os
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from typing import Any

from runlight import _js
from runlight.http import Request, Response

from support.conformance import ENV, TEXT_BODY_TYPE


def runlight(options: Mapping[str, Any] | None = None) -> Any:
    """A Runlight with these options, and an in-memory SQLite unless a store is given."""
    from runlight import Runlight
    from runlight.store import Stores

    given = dict(options or {})
    given.setdefault("store", Stores.sqlite(":memory:"))
    return Runlight(given)


def req(path: str, method: str = "GET", headers: Mapping[str, str] | None = None, body: str | None = None) -> Request:
    all_headers = dict(headers or {})
    # JavaScript's Request gives a string body this type when none is named.
    if body is not None and "content-type" not in all_headers:
        all_headers["content-type"] = TEXT_BODY_TYPE
    return Request(f"https://example.com{path}", method, all_headers, body or "")


def owner(path: str, method: str = "GET", body: Any = None, token: str = "secret") -> Request:
    """A JSON request with a bearer token, as the tests' owner sends it."""
    headers = {"authorization": f"Bearer {token}"}
    if body is not None:
        headers["content-type"] = "application/json"
    return req(path, method, headers, None if body is None else _js.dumps(body))


def body(response: Response) -> Any:
    """The answer's body as JSON."""
    return _js.loads(response.text())


@contextmanager
def clear_env() -> Iterator[None]:
    """The environment the SDK reads defaults from, cleared, and put back after."""
    saved = {name: os.environ.pop(name, None) for name in ENV}
    try:
        yield
    finally:
        for name, value in saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
