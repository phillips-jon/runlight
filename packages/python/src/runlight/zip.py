"""A ZIP file of text files, stored without compression, and the CSV that goes
in it. Small and plain, so it needs no library."""

from __future__ import annotations

import re
import struct
import time
import zlib
from datetime import datetime, timezone
from typing import Any

from . import _js


def _dos_time(ms: int) -> tuple[int, int]:
    """DOS date and time, as ZIP stores them: the time, then the day."""
    at = datetime.fromtimestamp(ms // 1000, timezone.utc)
    return (
        ((at.hour << 11) | (at.minute << 5) | (at.second // 2)) & 0xFFFF,
        (((at.year - 1980) << 9) | (at.month << 5) | at.day) & 0xFFFF,
    )


def zip(files: list[dict[str, str]], now: int | None = None) -> bytes:
    """The ZIP's bytes. Every entry carries the time `now` (epoch milliseconds, as the TypeScript's Date), in
    UTC; the wall clock when it is left out."""
    dos_time, day = _dos_time(now if now is not None else time.time_ns() // 1_000_000)
    parts: list[bytes] = []
    central: list[bytes] = []
    offset = 0
    for file in files:
        # TextEncoder writes UTF-8, with U+FFFD for a lone surrogate.
        name = _js.encode(file["name"])
        data = _js.encode(file["text"])
        crc = zlib.crc32(data)
        # 0x0800: names are UTF-8. Method 0: stored.
        parts.append(
            struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0x0800, 0, dos_time, day, crc, len(data), len(data), len(name), 0)
        )
        parts.append(name)
        parts.append(data)
        central.append(
            struct.pack(
                "<IHHHHHHIIIHHHHHII",
                0x02014B50, 20, 20, 0x0800, 0, dos_time, day, crc, len(data), len(data), len(name), 0, 0, 0, 0, 0,
                offset,
            )  # fmt: skip
        )
        central.append(name)
        offset += 30 + len(name) + len(data)
    size = sum(len(c) for c in central)
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(files), len(files), size, offset, 0)
    return b"".join(parts) + b"".join(central) + end


_FORMULA = re.compile("[=+\\-@\\t\\r]")
_NUMBER = re.compile(r"-?[0-9]+(\.[0-9]+)?\Z")
_QUOTE = re.compile('[",\\n\\r]')


def csv_row(values: list[Any]) -> str:
    """One CSV row, quoting what needs it; a leading =, +, -, or @ is escaped so a spreadsheet will not run it."""

    def cell(v: Any) -> str:
        s = "" if v is None or v is _js.UNDEFINED else _js.string(v)
        if _FORMULA.match(s) and not _NUMBER.match(s):
            s = f"'{s}"
        return '"' + s.replace('"', '""') + '"' if _QUOTE.search(s) else s

    return ",".join(cell(v) for v in values)


def csv(header: list[str], rows: list[list[Any]]) -> str:
    return "\r\n".join([csv_row(header), *(csv_row(row) for row in rows)]) + "\r\n"
