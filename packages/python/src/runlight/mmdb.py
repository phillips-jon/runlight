"""A reader for MaxMind DB files (the MMDB format that MaxMind's GeoLite2 and
DB-IP's free databases use), in plain Python so location needs no extension or
library. It answers what the TypeScript server's mmdb-lib answers: the record
for an address, maps as dicts with string keys, or None when the address is not
in the database.

A database opened from a file is read a page at a time as lookups need it, so a
130 MB city database costs each request a few hundred kilobytes of reads.

Format: https://maxmind.github.io/MaxMind-DB/
"""

from __future__ import annotations

import ipaddress
import os
import struct
from typing import Any, BinaryIO

_METADATA_MARKER = b"\xab\xcd\xefMaxMind.com"
# The metadata sits in the file's last 128 KiB.
_METADATA_MAX = 131072
_PAGE = 4096
# Pages kept from a file at once; a lookup reads a few dozen.
_PAGES_KEPT = 256
# Number.MAX_SAFE_INTEGER: a uint64 or uint128 past it comes back as its decimal text.
_MAX_SAFE = 2**53 - 1


class Mmdb:
    """A MaxMind DB, from its bytes or (with `handle`) read from an open file as lookups need it."""

    def __init__(self, data: bytes = b"", handle: BinaryIO | None = None) -> None:
        self._data = data
        self._handle = handle
        self._pages: dict[int, bytes] = {}
        self._size = len(data) if handle is None else os.fstat(handle.fileno()).st_size
        tail_start = max(0, self._size - _METADATA_MAX)
        at = self._read(tail_start, self._size - tail_start).rfind(_METADATA_MARKER)
        if at < 0:
            raise ValueError("Not a MaxMind DB file: no metadata")
        start = tail_start + at + len(_METADATA_MARKER)
        metadata, _ = self._decode(start, start)
        if not isinstance(metadata, dict) or not all(k in metadata for k in ("node_count", "record_size", "ip_version")):
            raise ValueError("Not a MaxMind DB file: bad metadata")
        self.metadata: dict[str, Any] = metadata
        self._node_count = int(metadata["node_count"])
        self._record_size = int(metadata["record_size"])
        if self._record_size not in (24, 28, 32):
            raise ValueError(f"Unsupported record size {self._record_size}")
        self._node_bytes = self._record_size // 4
        self._data_start = self._node_count * self._node_bytes + 16
        self._ipv4_start: int | None = None

    @classmethod
    def open(cls, file: str) -> Mmdb:
        """A database read from its file as lookups need it. Raises OSError when the file cannot be read."""
        if not os.path.isfile(file):
            raise OSError(f"Could not read {file}")
        return cls(b"", open(file, "rb"))  # noqa: SIM115

    def close(self) -> None:
        if self._handle is not None:
            self._handle.close()

    def _read(self, at: int, length: int) -> bytes:
        """`length` bytes from `at`, fewer at the end of the database."""
        if self._handle is None:
            return self._data[at : at + length]
        out = bytearray()
        end = min(at + length, self._size)
        while at < end:
            number = at // _PAGE
            page = self._pages.get(number)
            if page is None:
                if len(self._pages) >= _PAGES_KEPT:
                    self._pages = {}
                self._handle.seek(number * _PAGE)
                page = self._handle.read(_PAGE)
                self._pages[number] = page
            offset = at - number * _PAGE
            piece = page[offset : offset + end - at]
            if not piece:
                break
            out += piece
            at += len(piece)
        return bytes(out)

    def _byte(self, at: int) -> int:
        data = self._read(at, 1)
        if not data:
            raise ValueError("Invalid MaxMind DB: read past the end")
        return data[0]

    def get(self, ip: str) -> Any:
        """The record for an address, or None. Raises ValueError for text that is not an IP address."""
        try:
            address = ipaddress.ip_address(ip)
        except ValueError:
            raise ValueError(f"Not an IP address: {ip}") from None
        packed = address.packed
        v6 = len(packed) == 16
        if v6 and int(self.metadata["ip_version"]) == 4:
            raise ValueError(f"An IPv6 address cannot be looked up in an IPv4-only database: {ip}")
        node = 0 if v6 or int(self.metadata["ip_version"]) == 4 else self._ipv4()
        bits = len(packed) * 8
        i = 0
        while i < bits and node < self._node_count:
            bit = (packed[i >> 3] >> (7 - (i & 7))) & 1
            node = self._record(node, bit)
            i += 1
        # The node count itself means no record, and so does a tree that ends before the address does.
        if node <= self._node_count:
            return None
        value, _ = self._decode(self._data_start + node - self._node_count - 16, self._data_start)
        return value

    def _ipv4(self) -> int:
        """IPv4 addresses live under ::/96 in an IPv6 tree: the node 96 left turns down."""
        if self._ipv4_start is None:
            node = 0
            i = 0
            while i < 96 and node < self._node_count:
                node = self._record(node, 0)
                i += 1
            self._ipv4_start = node
        return self._ipv4_start

    def _record(self, node: int, right: int) -> int:
        b = self._read(node * self._node_bytes, self._node_bytes)
        if len(b) < self._node_bytes:
            raise ValueError("Invalid MaxMind DB: read past the end")
        if self._record_size == 24:
            at = right * 3
            return (b[at] << 16) | (b[at + 1] << 8) | b[at + 2]
        if self._record_size == 28:
            if right == 0:
                return ((b[3] & 0xF0) << 20) | (b[0] << 16) | (b[1] << 8) | b[2]
            return ((b[3] & 0x0F) << 24) | (b[4] << 16) | (b[5] << 8) | b[6]
        return int.from_bytes(b[right * 4 : right * 4 + 4], "big")

    def _decode(self, at: int, base: int) -> tuple[Any, int]:
        """Decodes the value at `at`; pointers are offsets from `base`. Gives the value and the offset just past it."""
        control = self._byte(at)
        at += 1
        kind = control >> 5
        if kind == 1:
            # A pointer: up to four more bytes of offset, then the value found there.
            ss = (control >> 3) & 3
            vvv = control & 7
            if ss == 0:
                pointer = (vvv << 8) | self._byte(at)
            elif ss == 1:
                pointer = ((vvv << 16) | (self._byte(at) << 8) | self._byte(at + 1)) + 2048
            elif ss == 2:
                pointer = ((vvv << 24) | (self._byte(at) << 16) | (self._byte(at + 1) << 8) | self._byte(at + 2)) + 526336
            else:
                pointer = int.from_bytes(self._read(at, 4), "big")
            value, _ = self._decode(base + pointer, base)
            return value, at + ss + 1
        if kind == 0:
            kind = 7 + self._byte(at)
            at += 1
        size = control & 0x1F
        if size >= 29:
            extra = size - 28
            n = int.from_bytes(self._read(at, extra), "big")
            size = {29: 29, 30: 285, 31: 65821}[size] + n
            at += extra
        if kind == 2:  # UTF-8 string, each malformed sequence U+FFFD as Node reads it
            return self._read(at, size).decode("utf-8", "replace"), at + size
        if kind == 3:  # double
            return struct.unpack(">d", self._read(at, 8))[0], at + 8
        if kind == 4:  # bytes
            return self._read(at, size), at + size
        if kind in (5, 6):  # uint16, uint32
            return int.from_bytes(self._read(at, size), "big"), at + size
        if kind == 7:  # map
            out: dict[str, Any] = {}
            for _ in range(size):
                key, at = self._decode(at, base)
                value, at = self._decode(at, base)
                out[str(key)] = value
            return out, at
        if kind == 8:  # int32
            n = int.from_bytes(self._read(at, size), "big")
            if size == 4 and n >= 0x80000000:
                n -= 0x100000000
            return n, at + size
        if kind in (9, 10):  # uint64, uint128
            n = int.from_bytes(self._read(at, size), "big")
            return (n if n <= _MAX_SAFE else str(n)), at + size
        if kind == 11:  # array
            items = []
            for _ in range(size):
                value, at = self._decode(at, base)
                items.append(value)
            return items, at
        if kind == 14:  # boolean, its value in the size
            return size != 0, at
        if kind == 15:  # float
            return struct.unpack(">f", self._read(at, 4))[0], at + 4
        raise ValueError(f"Invalid MaxMind DB: unknown data type {kind}")
