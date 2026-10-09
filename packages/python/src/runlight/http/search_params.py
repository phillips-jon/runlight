"""Query parameters as JavaScript's URLSearchParams reads and writes them."""

from __future__ import annotations

import re
import urllib.parse
from collections.abc import Iterator, Mapping

from .._js import well_formed

_FORM_SAFE = re.compile(r"[^A-Za-z0-9*\-._ ]")


class SearchParams:
    """Query parameters as URLSearchParams has them: pairs kept in order, `+` read as a space, and written back in
    the application/x-www-form-urlencoded form."""

    def __init__(self, init: str | Mapping[str, object] | list[tuple[str, str]] | None = None) -> None:
        self._pairs: list[tuple[str, str]] = []
        if init is None:
            return
        if isinstance(init, Mapping):
            self._pairs = [(str(k), str(v)) for k, v in init.items()]
            return
        if isinstance(init, list):
            self._pairs = [(str(k), str(v)) for k, v in init]
            return
        text = init[1:] if init.startswith("?") else init
        for part in text.split("&"):
            if part == "":
                continue
            name, eq, value = part.partition("=")
            self._pairs.append((self._decode(name), self._decode(value if eq else "")))

    def get(self, name: str) -> str | None:
        for key, value in self._pairs:
            if key == name:
                return value
        return None

    def get_all(self, name: str) -> list[str]:
        return [value for key, value in self._pairs if key == name]

    def has(self, name: str) -> bool:
        return any(key == name for key, _ in self._pairs)

    def __contains__(self, name: object) -> bool:
        return isinstance(name, str) and self.has(name)

    def set(self, name: str, value: str) -> None:
        out: list[tuple[str, str]] = []
        found = False
        for pair in self._pairs:
            if pair[0] != name:
                out.append(pair)
            elif not found:
                out.append((name, value))
                found = True
        if not found:
            out.append((name, value))
        self._pairs = out

    def append(self, name: str, value: str) -> None:
        self._pairs.append((name, value))

    def delete(self, name: str) -> None:
        self._pairs = [pair for pair in self._pairs if pair[0] != name]

    def keys(self) -> list[str]:
        return [key for key, _ in self._pairs]

    def items(self) -> list[tuple[str, str]]:
        return list(self._pairs)

    def __iter__(self) -> Iterator[tuple[str, str]]:
        return iter(list(self._pairs))

    def __len__(self) -> int:
        return len(self._pairs)

    def sort(self) -> None:
        """URLSearchParams.sort: a stable sort by name in UTF-16 code unit order."""
        from .._js import order_key

        self._pairs.sort(key=lambda pair: order_key(pair[0]))

    def to_string(self) -> str:
        return "&".join(f"{encode(k)}={encode(v)}" for k, v in self._pairs)

    def __str__(self) -> str:
        return self.to_string()

    @staticmethod
    def _decode(text: str) -> str:
        # Bytes that are not UTF-8 become U+FFFD, as URLSearchParams decodes them.
        return urllib.parse.unquote(text.replace("+", " "), errors="replace")


def encode(text: str) -> str:
    """The form encoding: letters, digits, and *-._ as they are, spaces as +, the rest escaped as UTF-8."""
    text = well_formed(text)
    return _FORM_SAFE.sub(lambda m: "".join(f"%{b:02X}" for b in m.group(0).encode("utf-8")), text).replace(" ", "+")
