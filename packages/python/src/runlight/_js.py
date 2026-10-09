"""The few places JavaScript and Python disagree about text and numbers,
settled the JavaScript way.

The TypeScript SDK writes the answers, the stored rows, and the outgoing
bodies, so this port reproduces them byte for byte: JSON.stringify (number
forms, key order, escaping), String(value), Number(value), Math.round,
trim() with JavaScript's idea of white space, decodeURIComponent's
strictness, truthiness, lengths and slices counted in UTF-16 units, and
comparing text with `<`, which orders by UTF-16 code units.

Python's str can hold a lone surrogate, which UTF-8 cannot. A slice that cuts
a surrogate pair in two leaves U+FFFD in place of the lone half, which is
what the TypeScript SDK stores once it writes the text out as UTF-8.
"""

from __future__ import annotations

import json
import math
import re
import urllib.parse
from collections.abc import Mapping
from typing import Any

# What JavaScript's \s and trim() treat as white space, for use inside a character class.
WHITESPACE = "\\t\\n\\x0b\\x0c\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff"
SPACE = re.compile(f"[{WHITESPACE}]")
SPACES = re.compile(f"[{WHITESPACE}]+")
_LEADING = re.compile(f"^[{WHITESPACE}]+")
_TRAILING = re.compile(f"[{WHITESPACE}]+\\Z")

# Number.MAX_SAFE_INTEGER. Past it JavaScript holds an integer as the nearest double.
MAX_SAFE_INTEGER = 2**53 - 1

_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
# Control characters, the quote, the backslash, and lone surrogates.
_NEEDS_ESCAPE = re.compile('["\\\\\x00-\x1f\ud800-\udfff]')
# An array index is a canonical integer below 2**32 - 1; JavaScript lists those keys first.
_INDEX_KEY = re.compile(r"(?:0|[1-9][0-9]{0,9})\Z")


class _Undefined:
    """JavaScript's undefined: JSON.stringify leaves out a field holding it, and writes null for it in an array."""

    _one: _Undefined | None = None

    def __new__(cls) -> _Undefined:
        if cls._one is None:
            cls._one = super().__new__(cls)
        return cls._one

    def __repr__(self) -> str:
        return "undefined"

    def __bool__(self) -> bool:
        return False


UNDEFINED = _Undefined()


# Text


def trim(text: str) -> str:
    """String.prototype.trim."""
    return _TRAILING.sub("", _LEADING.sub("", text))


def trim_start(text: str) -> str:
    return _LEADING.sub("", text)


def trim_end(text: str) -> str:
    """String.prototype.trimEnd."""
    return _TRAILING.sub("", text)


def length(text: str) -> int:
    """String#length: UTF-16 code units."""
    if text.isascii():
        return len(text)
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


def slice16(text: str, start: int, end: int | None = None) -> str:
    """String.prototype.slice, counting UTF-16 code units. A surrogate pair cut in half leaves U+FFFD."""
    if text.isascii():
        count = len(text)
        a = max(0, count + start) if start < 0 else min(start, count)
        b = count if end is None else (max(0, count + end) if end < 0 else min(end, count))
        return text[a:b] if b > a else ""
    data = text.encode("utf-16-le", "surrogatepass")
    count = len(data) // 2
    a = max(0, count + start) if start < 0 else min(start, count)
    b = count if end is None else (max(0, count + end) if end < 0 else min(end, count))
    if b <= a:
        return ""
    return data[a * 2 : b * 2].decode("utf-16-le", "replace")


def cut(text: str, units: int) -> str:
    """text.slice(0, units), counting UTF-16 code units. Where JavaScript would cut a pair in two and keep half of
    a character, this leaves the whole character out, as the PHP port does."""
    if text.isascii() or length(text) <= units:
        return text[:units] if text.isascii() else text
    data = text.encode("utf-16-le", "surrogatepass")[: units * 2]
    last = int.from_bytes(data[-2:], "little") if data else 0
    if 0xD800 <= last <= 0xDBFF:
        data = data[:-2]
    return data.decode("utf-16-le", "replace")


def well_formed(text: str) -> str:
    """Text with any lone surrogate made U+FFFD, as JavaScript writes one out as UTF-8."""
    if text.isascii():
        return text
    try:
        text.encode("utf-8")
        return text
    except UnicodeEncodeError:
        return text.encode("utf-16-le", "surrogatepass").decode("utf-16-le", "replace")


def utf8(data: bytes | str) -> str:
    """Bytes read as TextDecoder reads them: a byte order mark dropped, and each ill-formed sequence one U+FFFD."""
    if isinstance(data, str):
        return data
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return data.decode("utf-8", "replace")


def encode(text: str) -> bytes:
    """Text as UTF-8 bytes, as TextEncoder writes it (a lone surrogate as U+FFFD)."""
    return well_formed(text).encode("utf-8")


def compare(a: str, b: str) -> int:
    """Orders two strings as JavaScript's `<` does, by UTF-16 code units: -1, 0, or 1."""
    if a == b:
        return 0
    return -1 if order_key(a) < order_key(b) else 1


def order_key(text: str) -> Any:
    """A sort key that orders text by UTF-16 code units, as JavaScript's default sort and `<` do."""
    if text.isascii():
        return text.encode("ascii")
    return text.encode("utf-16-be", "surrogatepass")


def locale_key(text: str) -> Any:
    """A sort key for `a.localeCompare(b)` in English, close to ICU's root collation without ICU: white space,
    then punctuation, then symbols, then digits, then letters; letters compared without accents or case first,
    then accents, then lower case before upper."""
    import unicodedata

    primary = []
    accents = []
    cases = []
    for ch in text:
        base = unicodedata.normalize("NFD", ch)
        letter = base[0]
        category = unicodedata.category(letter)
        rank = {"Z": 0, "P": 1, "S": 2, "N": 3, "L": 4}.get(category[0], 2)
        primary.append((rank, letter.casefold() if rank == 4 else letter))
        accents.append(base[1:])
        cases.append(0 if letter == letter.lower() else 1)
    return (primary, accents, cases)


def lower(text: str) -> str:
    return text.lower()


def upper(text: str) -> str:
    return text.upper()


def decode_uri_component(text: str) -> str | None:
    """decodeURIComponent, or None where it would throw: a broken escape or bytes that are not UTF-8."""
    if re.search(r"%(?![0-9A-Fa-f]{2})", text):
        return None
    try:
        return urllib.parse.unquote(text, errors="strict")
    except UnicodeDecodeError:
        return None


_URI_SAFE = "-_.!~*'()"


def encode_uri_component(text: str) -> str:
    """encodeURIComponent(text)."""
    return urllib.parse.quote(well_formed(text), safe=_URI_SAFE)


def encode_uri(text: str) -> str:
    """encodeURI(text)."""
    return urllib.parse.quote(well_formed(text), safe=_URI_SAFE + ";,/?:@&=+$#")


# Numbers


def is_number(value: Any) -> bool:
    """typeof value === "number", for Python's numbers (bool is not one)."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_finite(value: Any) -> bool:
    """Number.isFinite."""
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    return isinstance(value, float) and math.isfinite(value)


def is_integer(value: Any) -> bool:
    """Number.isInteger."""
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    return isinstance(value, float) and math.isfinite(value) and value == math.floor(value)


def is_safe_integer(value: Any) -> bool:
    return is_integer(value) and abs(value) <= MAX_SAFE_INTEGER


def whole(value: float | int) -> float | int:
    """A whole float as an int, so it reads, compares, and binds as one; anything else as it is."""
    if isinstance(value, float) and math.isfinite(value) and value == math.floor(value) and abs(value) <= 2**63:
        return int(value)
    return value


def js_round(value: float | int) -> float | int:
    """Math.round: halves go up, toward positive infinity, so -2.5 becomes -2. An int for a finite value."""
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if not math.isfinite(value):
        return value
    floor = math.floor(value)
    # A double's distance from its floor is exact, so 0.49999999999999994 stays 0.
    return floor + 1 if value - floor >= 0.5 else floor


def _decimal(value: float) -> tuple[str, int]:
    """The shortest digits that round-trip, and where the decimal point goes: value = 0.DIGITS * 10**point."""
    text = repr(float(value))
    if "e" in text:
        mantissa, exponent = text.split("e")
        digits = mantissa.replace(".", "")
        point = int(exponent) + 1
    else:
        whole_part, _, fraction = text.partition(".")
        if whole_part == "0":
            stripped = fraction.lstrip("0")
            point = -(len(fraction) - len(stripped))
            digits = stripped
        else:
            digits = whole_part + fraction
            point = len(whole_part)
    digits = digits.rstrip("0")
    return (digits or "0"), point


def number_text(value: Any) -> str:
    """String(number): the text a template literal or JSON.stringify gives a number."""
    if isinstance(value, int) and not isinstance(value, bool) and abs(value) <= MAX_SAFE_INTEGER:
        return str(value)
    value = float(value)
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "Infinity" if value > 0 else "-Infinity"
    if value == 0:
        return "0"
    digits, point = _decimal(abs(value))
    k = len(digits)
    if k <= point <= 21:
        text = digits + "0" * (point - k)
    elif 0 < point <= 21:
        text = f"{digits[:point]}.{digits[point:]}"
    elif -6 < point <= 0:
        text = f"0.{'0' * -point}{digits}"
    else:
        exponent = point - 1
        mantissa = digits if k == 1 else f"{digits[0]}.{digits[1:]}"
        text = f"{mantissa}e{'-' if exponent < 0 else '+'}{abs(exponent)}"
    return f"-{text}" if value < 0 else text


def to_fixed(value: float | int, digits: int) -> str:
    """Number.prototype.toFixed for the values the SDK formats (below 1e21): the exact decimal, rounded half up."""
    from decimal import ROUND_HALF_UP, Decimal

    if not math.isfinite(value):
        return number_text(value)
    exact = Decimal(float(value))
    quantum = Decimal(1).scaleb(-digits)
    text = str(exact.quantize(quantum, rounding=ROUND_HALF_UP))
    if text.startswith("-") and float(text) == 0:
        # (-0.0001).toFixed(2) is "-0.00" in JavaScript too, but (-0).toFixed(2) is "0.00".
        return text if value < 0 else text[1:]
    return text


_NUMBER = re.compile(r"[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\Z")
_RADIX = re.compile(r"0([xXoObB])([0-9a-zA-Z]+)\Z")


def number(value: Any) -> float | int:
    """Number(value). Whole results come back as int, NaN and the infinities as floats."""
    if value is None or value is False:
        return 0
    if value is True:
        return 1
    if value is UNDEFINED:
        return math.nan
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, list):
        return number(string(value))
    if not isinstance(value, str):
        return math.nan
    text = trim(value)
    if text == "":
        return 0
    m = _RADIX.match(text)
    if m:
        base = {"x": 16, "o": 8, "b": 2}[m.group(1).lower()]
        try:
            return whole(float(int(m.group(2), base)))
        except ValueError:
            return math.nan
    if text in ("Infinity", "+Infinity"):
        return math.inf
    if text == "-Infinity":
        return -math.inf
    if not _NUMBER.match(text):
        return math.nan
    return whole(float(text))


def parse_int(value: Any, radix: int = 10) -> float | int:
    """parseInt(value, radix) for radix 10 and 16."""
    text = trim_start(string(value))
    m = re.match(r"([+-]?)(0[xX])?([0-9a-zA-Z]*)", text)
    assert m is not None
    sign, prefix, rest = m.groups()
    if prefix and radix in (16, 0):
        radix = 16
    elif prefix:
        rest = "0"
    if radix == 0:
        radix = 10
    digits = ""
    for ch in rest:
        if int(ch, 36) < radix if ch.isalnum() and ch.isascii() else False:
            digits += ch
        else:
            break
    if not digits:
        return math.nan
    n = int(digits, radix)
    return -n if sign == "-" else n


def parse_float(value: Any) -> float | int:
    """parseFloat(value)."""
    text = trim_start(string(value))
    if text.startswith(("Infinity", "+Infinity")):
        return math.inf
    if text.startswith("-Infinity"):
        return -math.inf
    m = re.match(r"[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?", text)
    if not m:
        return math.nan
    return whole(float(m.group(0)))


def string(value: Any) -> str:
    """String(value) for the values the SDK passes it."""
    if value is None:
        return "null"
    if value is UNDEFINED:
        return "undefined"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return number_text(value)
    if isinstance(value, str):
        return value
    if isinstance(value, (list, tuple)):
        # An array is its items joined with commas, null and undefined as nothing.
        return ",".join("" if v is None or v is UNDEFINED else string(v) for v in value)
    if isinstance(value, Mapping):
        return "[object Object]"
    return str(value)


def truthy(value: Any) -> bool:
    """Whether JavaScript reads a value as true."""
    if value is None or value is UNDEFINED or value is False or value == "" and isinstance(value, str):
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0 and not (isinstance(value, float) and math.isnan(value))
    return True


def is_object(value: Any) -> bool:
    """typeof value === "object" and not null: an array or an object."""
    return isinstance(value, (dict, list))


def is_plain_object(value: Any) -> bool:
    """A JSON object (not an array)."""
    return isinstance(value, dict)


def get(value: Any, key: str | int) -> Any:
    """value[key]: UNDEFINED when there is no such property, and a TypeError for a property of null or undefined."""
    if value is None or value is UNDEFINED:
        which = "null" if value is None else "undefined"
        raise TypeError(f"Cannot read properties of {which} (reading '{key}')")
    if isinstance(value, dict):
        return value.get(str(key), UNDEFINED) if str(key) in value else UNDEFINED
    if isinstance(value, list):
        if key == "length":
            return len(value)
        if isinstance(key, int) or (isinstance(key, str) and key.isdigit()):
            i = int(key)
            return value[i] if 0 <= i < len(value) else UNDEFINED
        return UNDEFINED
    if isinstance(value, str) and key == "length":
        return length(value)
    return UNDEFINED


# JSON


def quote(text: str) -> str:
    """A string as JSON.stringify writes it."""

    def escape(match: re.Match[str]) -> str:
        c = match.group(0)
        return _ESCAPES.get(c) or f"\\u{ord(c):04x}"

    return '"' + _NEEDS_ESCAPE.sub(escape, text) + '"'


def object_keys(mapping: Mapping[Any, Any]) -> list[Any]:
    """Property order: array-index keys ascending, then the rest as inserted."""
    keys = list(mapping.keys())
    indexes = [k for k in keys if _INDEX_KEY.match(str(k)) and int(str(k)) < 4_294_967_295]
    if not indexes:
        return keys
    taken = set(indexes)
    rest = [k for k in keys if k not in taken]
    return sorted(indexes, key=lambda k: int(str(k))) + rest


def dumps(value: Any, indent: int | str | None = None) -> str:
    """JSON.stringify: dicts, lists, tuples, strings, numbers, True, False, None, and anything with a to_json().
    UNDEFINED is left out of an object and written as null in an array; NaN and the infinities as null.
    `indent` is JSON.stringify's third argument."""
    if indent is None:
        return _write(value)
    pad = " " * indent if isinstance(indent, int) else indent
    return _pretty(value, "", pad)


def _write(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return quote(value)
    if isinstance(value, int):
        return number_text(value)
    if isinstance(value, float):
        return number_text(value) if math.isfinite(value) else "null"
    if isinstance(value, Mapping):
        parts = []
        for key in object_keys(value):
            item = value[key]
            if item is UNDEFINED or callable(item) and not hasattr(item, "to_json"):
                continue
            parts.append(f"{quote(str(key))}:{_write(item)}")
        return "{" + ",".join(parts) + "}"
    if isinstance(value, (list, tuple)):
        return "[" + ",".join("null" if v is UNDEFINED else _write(v) for v in value) + "]"
    to_json = getattr(value, "to_json", None)
    if callable(to_json):
        return _write(to_json())
    if value is UNDEFINED:
        return "null"
    raise TypeError(f"{type(value).__name__} is not JSON serializable")


def _pretty(value: Any, indent: str, pad: str) -> str:
    inner = indent + pad
    if isinstance(value, (list, tuple)):
        if not value:
            return "[]"
        items = [inner + _pretty(None if v is UNDEFINED else v, inner, pad) for v in value]
        return "[\n" + ",\n".join(items) + "\n" + indent + "]"
    if isinstance(value, Mapping):
        parts = []
        for key in object_keys(value):
            item = value[key]
            if item is UNDEFINED:
                continue
            parts.append(f"{inner}{quote(str(key))}: {_pretty(item, inner, pad)}")
        return "{\n" + ",\n".join(parts) + "\n" + indent + "}" if parts else "{}"
    to_json = getattr(value, "to_json", None)
    if callable(to_json):
        return _pretty(to_json(), indent, pad)
    return _write(value)


def _no_constant(name: str) -> Any:
    raise ValueError(f"Unexpected token {name} in JSON")


def _js_float(text: str) -> float | int:
    return whole(float(text))


def _js_int(text: str) -> float | int:
    n = int(text)
    # Past 2^53 JavaScript holds the nearest double.
    return n if abs(n) <= MAX_SAFE_INTEGER else whole(float(n)) if abs(n) < 2**63 else float(n)


def loads(text: str | bytes) -> Any:
    """JSON.parse. Raises ValueError for text that is not JSON (NaN and Infinity included, as JavaScript has it).
    Numbers come back as JavaScript holds them: a whole number as an int, anything else as a float."""
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    return json.loads(text, parse_constant=_no_constant, parse_float=_js_float, parse_int=_js_int)


def try_loads(text: str | bytes) -> tuple[bool, Any]:
    """JSON.parse of a body as Response.json() reads it: a byte order mark skipped and bytes that are not UTF-8 read
    as U+FFFD. Gives whether it parsed, and the value."""
    try:
        return True, loads(utf8(text) if isinstance(text, bytes) else (text[1:] if text.startswith("﻿") else text))
    except (ValueError, RecursionError):
        return False, None
