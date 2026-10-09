"""The tracker's rate limit, per address."""

from __future__ import annotations

import hashlib
import secrets
import threading
from collections.abc import Callable

from . import _js


class RateLimit:
    """Counts tracker requests per address in fixed one-minute windows, in memory.
    Addresses are hashed with a key made at start, so the map never holds an IP,
    and the whole map is dropped at the end of each window.

    Python servers keep the process between requests, as Node does, so the counts live here; several worker
    processes each count on their own, as the TypeScript SDK's processes do. A lock keeps threads from losing
    counts."""

    def __init__(self, per_minute: int, now: Callable[[], int]) -> None:
        self._per_minute = per_minute
        self._now = now
        self._window = 0
        self._counts: dict[str, int] = {}
        self._key = secrets.token_bytes(16)
        self._lock = threading.Lock()

    def allow(self, ip: str) -> bool:
        """True while this address is under its limit for the current minute."""
        # No address (a bare adapter with no context) cannot be told apart, so it is not limited.
        if not ip:
            return True
        window = self._now() // 60_000
        id = self._hash(ip)
        with self._lock:
            if window != self._window:
                self._window = window
                self._counts.clear()
            count = self._counts.get(id, 0) + 1
            self._counts[id] = count
        return count <= self._per_minute

    def _hash(self, ip: str) -> str:
        return hashlib.sha256(self._key + _js.encode(ip)).hexdigest()[:16]
