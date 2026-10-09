"""Headers matched without regard to case, as the Fetch API's are."""

from __future__ import annotations

from collections.abc import Iterator, Mapping
from typing import Any, Union

HeadersInit = Union["Headers", Mapping[str, Any], list[tuple[str, str]], None]


class Headers:
    """Header names are matched without regard to case, as the Fetch API's Headers are. get() joins repeated values
    with ", "; Set-Cookie is kept apart, since its values may hold commas, and read back with get_set_cookie()."""

    def __init__(self, init: HeadersInit = None) -> None:
        self._values: dict[str, list[str]] = {}
        if init is None:
            return
        if isinstance(init, Headers):
            self._values = {k: list(v) for k, v in init._values.items()}
            return
        items = init.items() if isinstance(init, Mapping) else init
        for name, value in items:
            if isinstance(value, (list, tuple)):
                for one in value:
                    self.append(str(name), str(one))
            else:
                self.append(str(name), str(value))

    def get(self, name: str) -> str | None:
        values = self._values.get(name.lower())
        return None if values is None else ", ".join(values)

    def has(self, name: str) -> bool:
        return name.lower() in self._values

    def __contains__(self, name: object) -> bool:
        return isinstance(name, str) and self.has(name)

    def set(self, name: str, value: str) -> None:
        self._values[name.lower()] = [self._clean(value)]

    def append(self, name: str, value: str) -> None:
        self._values.setdefault(name.lower(), []).append(self._clean(value))

    def delete(self, name: str) -> None:
        self._values.pop(name.lower(), None)

    def get_set_cookie(self) -> list[str]:
        return list(self._values.get("set-cookie", []))

    def all(self) -> dict[str, list[str]]:
        """Lowercase name to its values, in the order they were first set."""
        return {k: list(v) for k, v in self._values.items()}

    def items(self) -> Iterator[tuple[str, str]]:
        """Name and joined value pairs in name order, as iterating Fetch Headers gives them."""
        for name in sorted(self._values):
            if name == "set-cookie":
                for value in self._values[name]:
                    yield name, value
            else:
                yield name, ", ".join(self._values[name])

    def __iter__(self) -> Iterator[tuple[str, str]]:
        return self.items()

    def pairs(self) -> list[tuple[str, str]]:
        """Every value as its own pair, in the order set: what goes on the wire."""
        return [(name, value) for name, values in self._values.items() for value in values]

    def copy(self) -> Headers:
        return Headers(self)

    def __repr__(self) -> str:
        return f"Headers({self._values!r})"

    @staticmethod
    def _clean(value: str) -> str:
        # Header values never carry a line break, so nothing a caller passes can add a header of its own.
        # Fetch trims HTTP white space (tab, space, CR, LF) at both ends.
        return value.replace("\r", "").replace("\n", "").replace("\0", "").strip(" \t")
