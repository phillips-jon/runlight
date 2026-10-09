"""Requests and responses shaped like the Fetch API's, so the routes read the same as the TypeScript SDK's."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from typing import Any, Union

from .. import _js
from .headers import Headers, HeadersInit
from .url import Url

Body = Union[str, bytes, Iterable[bytes]]


class Request:
    """An incoming request: an absolute URL, a method, headers, and a body read as text or JSON.
    `remote_address` is the address the request came from, before any proxy header is read."""

    def __init__(
        self,
        url: str,
        method: str = "GET",
        headers: HeadersInit = None,
        body: str | bytes | None = None,
        remote_address: str = "",
    ) -> None:
        self.url = url
        self.method = method.upper()
        self.headers = Headers(headers)
        self._body = body.encode("utf-8") if isinstance(body, str) else (body or b"")
        self.remote_address = remote_address

    def body(self) -> bytes:
        """The body as it came, in bytes."""
        return self._body

    def text(self) -> str:
        """The body as text, as request.text() decodes it."""
        return _js.utf8(self._body)

    def json(self) -> Any:
        """The body as JSON. Raises ValueError when it is not."""
        return _js.loads(self.text())

    def parsed_url(self) -> Url:
        return Url(self.url)

    def with_(
        self,
        url: str | None = None,
        method: str | None = None,
        headers: HeadersInit = None,
        body: str | bytes | None = None,
    ) -> Request:
        """The same request with other parts, as `new Request(request, init)` makes one."""
        return Request(
            self.url if url is None else url,
            self.method if method is None else method,
            self.headers if headers is None else headers,
            self._body if body is None else body,
            self.remote_address,
        )

    def __repr__(self) -> str:
        return f"Request({self.method} {self.url})"


class Response:
    """An answer: a status, headers, and a body of text, bytes, or (for answers too long to hold at once) an
    iterable of byte chunks."""

    def __init__(self, body: Body | None = None, status: int = 200, headers: HeadersInit = None) -> None:
        self._body: Body = b"" if body is None else body
        self.status = status
        self.headers = Headers(headers)

    @classmethod
    def json(cls, data: Any, status: int = 200, headers: Mapping[str, str] | None = None) -> Response:
        all_headers = {"content-type": "application/json"}
        all_headers.update(headers or {})
        return cls(_js.dumps(data), status, all_headers)

    @classmethod
    def redirect(cls, location: str, status: int = 302) -> Response:
        return cls("", status, {"location": location})

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    @property
    def streamed(self) -> bool:
        return not isinstance(self._body, (str, bytes))

    def content(self) -> bytes:
        """The whole body in bytes; a streamed body is read to its end and kept."""
        if isinstance(self._body, bytes):
            return self._body
        if isinstance(self._body, str):
            return _js.encode(self._body)
        data = b"".join(self._body)
        self._body = data
        return data

    def text(self) -> str:
        """The whole body as text, as response.text() decodes it."""
        if isinstance(self._body, str):
            return self._body
        return _js.utf8(self.content())

    def json_body(self) -> Any:
        """The body as JSON, as response.json() reads it. Raises ValueError when it is not."""
        ok, value = _js.try_loads(self.content())
        if not ok:
            raise ValueError("The body is not JSON")
        return value

    def chunks(self) -> Iterable[bytes]:
        """The body in byte chunks, for a server to write as they come."""
        if isinstance(self._body, str):
            return [_js.encode(self._body)]
        if isinstance(self._body, bytes):
            return [self._body]
        return (chunk.encode("utf-8") if isinstance(chunk, str) else chunk for chunk in self._body)

    def __repr__(self) -> str:
        return f"Response({self.status})"
