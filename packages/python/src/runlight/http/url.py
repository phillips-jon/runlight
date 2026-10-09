"""An absolute URL, parsed the way browsers and JavaScript's URL do for the schemes Runlight sees."""

from __future__ import annotations

import re
import unicodedata
import urllib.parse

from .search_params import SearchParams

DEFAULT_PORTS = {"http:": "80", "https:": "443", "ws:": "80", "wss:": "443", "ftp:": "21"}

_PATH = ' "#<>?`{}'
_QUERY = " \"#<>'"
_FRAGMENT = ' "<>`'
_USERINFO = ' "#<>?`{}/:;=@[\\]^|'

_SCHEME = re.compile(r"([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)\Z", re.S)
_FORBIDDEN_HOST = re.compile(r"[\x00-\x20#%/:<>?@\[\\\]^|]")
_FORBIDDEN_OPAQUE = re.compile(r"[\x00 #/:<>?@\[\\\]^|]")


class InvalidUrl(ValueError):
    """`new URL()` threw: the text is not a URL."""


class Url:
    """An absolute http or https URL, parsed the way browsers and JavaScript's URL do for those schemes: the host
    lowercased, backslashes read as slashes, dot segments resolved, and the path and query percent-encoded with
    the WHATWG sets, so a path recorded here matches what the tracker sent and what the TypeScript SDK stores.

    Raises InvalidUrl when `text` is not a URL, as `new URL()` throws a TypeError; Url.parse() gives None."""

    protocol: str
    username: str
    password: str
    hostname: str
    port: str
    pathname: str
    search: str
    hash: str

    def __init__(self, text: str, base: str | None = None) -> None:
        self.username = ""
        self.password = ""
        # A URL of another scheme written with an authority, such as android-app://com.google.android.gm/.
        self._has_authority = False
        text = text.strip("".join(chr(c) for c in range(0x21)))
        text = text.replace("\t", "").replace("\n", "").replace("\r", "")
        m = _SCHEME.match(text)
        if not m:
            if base is None:
                raise InvalidUrl(f"Invalid URL: {text}")
            self._resolve(text, Url(base))
            return
        self.protocol = m.group(1).lower() + ":"
        rest = m.group(2)
        if self.protocol not in DEFAULT_PORTS:
            # Not a special scheme (mailto:, data:, javascript:): kept as it came.
            self.hostname = ""
            self.port = ""
            if rest.startswith("//"):
                # An authority after the scheme is an opaque host, kept in its case.
                rest = rest[2:]
                end = _span(rest, "/?#")
                self._opaque_authority(rest[:end])
                self._has_authority = True
                self._tail(rest[end:], "")
                return
            rest, self.hash = _cut(rest, "#")
            self.pathname, self.search = _cut(rest, "?")
            return
        rest = rest.replace("\\", "/").lstrip("/")
        end = _span(rest, "/?#")
        self._authority(rest[:end])
        self._tail(rest[end:], "/")

    @classmethod
    def parse(cls, text: str, base: str | None = None) -> Url | None:
        try:
            return cls(text, base)
        except InvalidUrl:
            return None

    @classmethod
    def can_parse(cls, text: str, base: str | None = None) -> bool:
        return cls.parse(text, base) is not None

    @property
    def host(self) -> str:
        return self.hostname if self.port == "" else f"{self.hostname}:{self.port}"

    @property
    def origin(self) -> str:
        return f"{self.protocol}//{self.host}" if self.protocol in DEFAULT_PORTS else "null"

    @property
    def href(self) -> str:
        if self.protocol not in DEFAULT_PORTS and not self._has_authority:
            return self.protocol + self.pathname + self.search + self.hash
        auth = ""
        if self.username or self.password:
            auth = self.username + (f":{self.password}" if self.password else "") + "@"
        return f"{self.protocol}//{auth}{self.host}{self.pathname}{self.search}{self.hash}"

    def __str__(self) -> str:
        return self.href

    def __repr__(self) -> str:
        return f"Url({self.href!r})"

    def to_json(self) -> str:
        return self.href

    @property
    def search_params(self) -> SearchParams:
        """A copy of the query's parameters; set_search_params() writes changes back."""
        return SearchParams(self.search)

    def set_search_params(self, params: SearchParams) -> None:
        """Replaces the query with these parameters, as changing url.searchParams does."""
        text = params.to_string()
        self.search = f"?{text}" if text else ""

    def set_pathname(self, path: str) -> None:
        """Replaces the path, as assigning url.pathname does."""
        path = path.replace("\t", "").replace("\n", "").replace("\r", "")
        if self.protocol in DEFAULT_PORTS:
            path = path.replace("\\", "/")
        self.pathname = _path(path if path.startswith("/") else f"/{path}")

    def set_search(self, search: str) -> None:
        """Replaces the query, as assigning url.search does: one leading "?" is dropped and the rest
        percent-encoded, and an empty value removes the query."""
        if search == "":
            self.search = ""
            return
        search = search.replace("\t", "").replace("\n", "").replace("\r", "")
        self.search = "?" + _encode(search[1:] if search.startswith("?") else search, _QUERY)

    def set_hash(self, value: str) -> None:
        value = value.replace("\t", "").replace("\n", "").replace("\r", "")
        if value == "":
            self.hash = ""
            return
        self.hash = "#" + _encode(value[1:] if value.startswith("#") else value, _FRAGMENT)

    def copy(self) -> Url:
        return Url(self.href)

    def _resolve(self, text: str, base: Url) -> None:
        self.protocol = base.protocol
        special = self.protocol in DEFAULT_PORTS
        if special:
            text = text.replace("\\", "/")
        if text.startswith("//"):
            # A special scheme skips any further slashes before the host: ///x is the host x.
            rest = text.lstrip("/") if special else text[2:]
            end = _span(rest, "/?#")
            self._authority(rest[:end])
            self._tail(rest[end:], "/")
            return
        self.username = base.username
        self.password = base.password
        self.hostname = base.hostname
        self.port = base.port
        if text == "":
            self.pathname = base.pathname
            self.search = base.search
            self.hash = ""
            return
        if text[0] == "#":
            self.pathname = base.pathname
            self.search = base.search
            self.hash = "#" + _encode(text[1:], _FRAGMENT) if len(text) > 1 else ""
            return
        if text[0] == "?":
            self.pathname = base.pathname
            query, frag = _cut(text[1:], "#")
            self.search = "?" + _encode(query, _QUERY) if query else ""
            self.hash = "#" + _encode(frag[1:], _FRAGMENT) if len(frag) > 1 else ""
            return
        if text[0] == "/":
            self._tail(text, "/")
            return
        directory = base.pathname[: base.pathname.rfind("/") + 1]
        self._tail(directory + text, "/")

    def _authority(self, authority: str) -> None:
        at = authority.rfind("@")
        if at != -1:
            user = authority[:at]
            authority = authority[at + 1 :]
            name, password = _cut(user, ":")
            self.username = _encode(name, _USERINFO)
            self.password = _encode(password[1:], _USERINFO) if password else ""
        port = ""
        if authority.startswith("["):
            close = authority.find("]")
            if close == -1:
                raise InvalidUrl("Invalid URL")
            host = authority[: close + 1].lower()
            after = authority[close + 1 :]
            if after:
                if after[0] != ":":
                    raise InvalidUrl("Invalid URL")
                port = after[1:]
        else:
            colon = authority.rfind(":")
            host = authority if colon == -1 else authority[:colon]
            port = "" if colon == -1 else authority[colon + 1 :]
            host = _domain(host)
        if host == "":
            raise InvalidUrl("Invalid URL")
        if port != "":
            if not (port.isascii() and port.isdigit()) or int(port) > 65535:
                raise InvalidUrl("Invalid URL")
            port = str(int(port))
            if port == DEFAULT_PORTS[self.protocol]:
                port = ""
        self.hostname = host
        self.port = port

    def _opaque_authority(self, authority: str) -> None:
        at = authority.rfind("@")
        if at != -1:
            name, password = _cut(authority[:at], ":")
            self.username = _encode(name, _USERINFO)
            self.password = _encode(password[1:], _USERINFO) if password else ""
            authority = authority[at + 1 :]
        colon = authority.rfind(":")
        host = authority if colon == -1 else authority[:colon]
        port = "" if colon == -1 else authority[colon + 1 :]
        if _FORBIDDEN_OPAQUE.search(host) or (port != "" and (not (port.isascii() and port.isdigit()) or int(port) > 65535)):
            raise InvalidUrl("Invalid URL")
        self.hostname = _encode(host, "")
        self.port = "" if port == "" else str(int(port))

    def _tail(self, rest: str, empty: str) -> None:
        rest, frag = _cut(rest, "#")
        path, query = _cut(rest, "?")
        self.pathname = "" if path == "" and empty == "" else _path(empty if path == "" else path)
        self.search = "?" + _encode(query[1:], _QUERY) if len(query) > 1 else ""
        self.hash = "#" + _encode(frag[1:], _FRAGMENT) if len(frag) > 1 else ""


def _span(text: str, stops: str) -> int:
    for i, ch in enumerate(text):
        if ch in stops:
            return i
    return len(text)


def _cut(text: str, mark: str) -> tuple[str, str]:
    """The part before `mark`, and the rest starting with it."""
    at = text.find(mark)
    return (text, "") if at == -1 else (text[:at], text[at:])


def _domain(host: str) -> str:
    raw = urllib.parse.unquote_to_bytes(host)
    try:
        host = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise InvalidUrl("Invalid URL") from None
    if _FORBIDDEN_HOST.search(host):
        raise InvalidUrl("Invalid URL")
    lower = host.lower()
    if not lower.isascii():
        lower = _to_ascii(lower)
    ipv4 = _ipv4(lower)
    return ipv4 if ipv4 is not None else lower


def _to_ascii(host: str) -> str:
    """UTS 46 ToASCII, nontransitional, for the hosts people type: mapped (case folded, compatibility composed)
    and each label that is not ASCII written in Punycode."""
    mapped = unicodedata.normalize("NFKC", host.casefold().replace("。", ".").replace("．", ".").replace("｡", "."))
    labels = []
    for label in mapped.split("."):
        if label.isascii():
            labels.append(label)
            continue
        try:
            labels.append("xn--" + label.encode("punycode").decode("ascii"))
        except UnicodeError:
            raise InvalidUrl("Invalid URL") from None
    out = ".".join(labels)
    if _FORBIDDEN_HOST.search(out):
        raise InvalidUrl("Invalid URL")
    return out


def _ipv4(host: str) -> str | None:
    """A host written as an IPv4 address in any form browsers accept, normalised to dotted decimal."""
    parts = host.split(".")
    if parts and parts[-1] == "":
        parts.pop()
    if not parts or len(parts) > 4:
        return None
    if not re.fullmatch(r"0x[0-9a-f]*|[0-9]+", parts[-1]):
        return None
    numbers: list[int] = []
    for part in parts:
        if re.fullmatch(r"0x[0-9a-f]*", part):
            numbers.append(int(part[2:] or "0", 16))
        elif re.fullmatch(r"0[0-7]+", part):
            numbers.append(int(part, 8))
        elif re.fullmatch(r"[0-9]+", part):
            numbers.append(int(part))
        else:
            raise InvalidUrl("Invalid URL")
    value = numbers.pop()
    if any(n > 255 for n in numbers):
        raise InvalidUrl("Invalid URL")
    if value >= 256 ** (5 - len(parts)):
        raise InvalidUrl("Invalid URL")
    for i, n in enumerate(numbers):
        value += n * 256 ** (3 - i)
    return ".".join(str((value >> s) & 255) for s in (24, 16, 8, 0))


def _path(path: str) -> str:
    out: list[str] = []
    segments = path.split("/")[1:]
    count = len(segments)
    for i, segment in enumerate(segments):
        lower = segment.lower()
        last = i == count - 1
        if lower in ("..", ".%2e", "%2e.", "%2e%2e"):
            if out:
                out.pop()
            if last:
                out.append("")
        elif lower in (".", "%2e"):
            if last:
                out.append("")
        else:
            out.append(_encode(segment, _PATH))
    return "/" + "/".join(out)


def _encode(text: str, extra: str) -> str:
    """Percent-encodes C0 controls, DEL, characters past ASCII (as UTF-8), and `extra`; existing escapes stay."""
    if text.isascii() and not any(c in extra or ord(c) < 0x21 or ord(c) > 0x7E for c in text):
        return text
    out = []
    for c in text:
        o = ord(c)
        if o < 0x21 or o > 0x7E or c in extra:
            data = c.encode("utf-8", "replace") if not 0xD800 <= o <= 0xDFFF else "�".encode("utf-8")
            out.append("".join(f"%{b:02X}" for b in data))
        else:
            out.append(c)
    return "".join(out)


def encode(text: str, extra: str) -> str:
    """Url._encode for callers that build URL parts the same way."""
    return _encode(text, extra)
