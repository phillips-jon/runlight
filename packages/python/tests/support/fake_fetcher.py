"""A Fetcher that records every request and answers from a function, so a test can require the exact method,
URL, headers, and body a service is sent. Headers are recorded as the TS fixtures record them: lowercase names in
name order, as iterating Fetch Headers gives them."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from runlight.http import Headers, Response


class FakeFetcher:
    def __init__(self, answer: Callable[[str, dict[str, Any]], Response]) -> None:
        self.answer = answer
        self.requests: list[dict[str, Any]] = []
        self.inits: list[dict[str, Any]] = []

    def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
        init = init or {}
        headers = dict(Headers(init.get("headers")).items())
        body = init.get("body")
        self.requests.append({
            "method": init.get("method", "GET"),
            "url": url,
            "headers": headers,
            "body": "" if body is None else body if isinstance(body, str) else body.decode("utf-8"),
        })  # fmt: skip
        self.inits.append(init)
        return self.answer(url, init)
