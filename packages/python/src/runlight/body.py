"""Capped reads of an answer's body. The cap belongs on the request too: pass
`maxBytes` to the Fetcher, which stops reading past it and raises BodyTooLong,
so an install or a page that answers without end never fills memory. These
check the same limit again on an answer in hand, reading a streamed body only
as far as the limit, and decode the text as TextDecoder does."""

from __future__ import annotations

from typing import Any

from . import _js
from .http import BodyTooLong, Response

__all__ = ["BodyTooLong", "read_json_capped", "read_text_capped"]


def read_text_capped(response: Response, max_bytes: int) -> str:
    """Reads a response body as text, up to max_bytes. Past that it stops reading
    and raises BodyTooLong."""
    declared = _js.number(response.headers.get("content-length"))
    if declared > max_bytes:
        raise BodyTooLong(f"Body over {max_bytes} bytes")
    chunks: list[bytes] = []
    size = 0
    stream = iter(response.chunks())
    for chunk in stream:
        size += len(chunk)
        if size > max_bytes:
            # Cancels the rest, where the body is a generator.
            close = getattr(stream, "close", None)
            if callable(close):
                close()
            raise BodyTooLong(f"Body over {max_bytes} bytes")
        chunks.append(chunk)
    return _js.utf8(b"".join(chunks))


def read_json_capped(response: Response, max_bytes: int) -> Any:
    """Reads a response body as JSON, up to max_bytes, as read_text_capped does. Raises ValueError, as JSON.parse
    throws, when it is not JSON."""
    return _js.loads(read_text_capped(response, max_bytes))
