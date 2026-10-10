"""Fetches from addresses that other people's input names, such as the icon
links on a site's home page or a link domain, and only from the public
internet. Only https is fetched, never a private, loopback, link-local,
or metadata address, and redirects are followed by hand under the same
rules. The name is resolved and every address it gives is checked before
each hop, and the request is pinned to the checked addresses (the Fetcher's
`resolve`), so a name that answers differently a moment later gets nowhere.
"""

from __future__ import annotations

import re
import socket
import time
from collections.abc import Callable
from typing import Any

from .http import Fetcher, FetchError, Response, Url, UrllibFetcher

Lookup = Callable[[str], list[str]]


class PrivateAddressError(Exception):
    """Refused before anything was fetched, because the address is not on the public internet."""

    def __init__(self, what: str) -> None:
        super().__init__(f"{what} is not a public address")
        self.name = "PrivateAddressError"


_OCTET = re.compile(r"[0-9]{1,3}\Z")


def _v4(text: str) -> list[int] | None:
    parts = text.split(".")
    if len(parts) != 4 or any(not _OCTET.match(p) or int(p) > 255 for p in parts):
        return None
    return [int(p) for p in parts]


def _public_v4(four: list[int]) -> bool:
    a, b, c = four[0], four[1], four[2]
    if a == 0 or a == 10 or a == 127 or a >= 224:
        return False
    if a == 100 and 64 <= b < 128:
        return False
    if a == 169 and b == 254:
        return False
    if a == 172 and 16 <= b < 32:
        return False
    if a == 192 and b == 168:
        return False
    if a == 192 and b == 0 and c in (0, 2):
        return False
    if a == 198 and b in (18, 19):
        return False
    if a == 198 and b == 51 and c == 100:
        return False
    if a == 203 and b == 0 and c == 113:
        return False
    return True


_BRACKETS = re.compile(r"^\[|\]\Z")
_TAIL = re.compile(r"([0-9]{1,3}(?:\.[0-9]{1,3}){3})\Z")
_GROUP = re.compile(r"[0-9a-f]{1,4}\Z")


def _v6(text: str) -> list[int] | None:
    """An IPv6 address as eight 16-bit groups, or None when it is not one."""
    address = _BRACKETS.sub("", text).split("%")[0].lower()
    # A trailing IPv4 address becomes the last two groups.
    tail = _TAIL.search(address)
    if tail:
        four = _v4(tail.group(1))
        if four is None:
            return None
        address = f"{address[: -len(tail.group(1))]}{(four[0] << 8) | four[1]:x}:{(four[2] << 8) | four[3]:x}"
    halves = address.split("::")
    if len(halves) > 2:
        return None
    head = halves[0].split(":") if halves[0] else []
    rest = halves[1].split(":") if len(halves) == 2 and halves[1] else []
    missing = 8 - len(head) - len(rest)
    if (missing != 0) if len(halves) == 1 else (missing < 1):
        return None
    groups = [*head, *(["0"] * (missing if len(halves) == 2 else 0)), *rest]
    if any(not _GROUP.match(g) for g in groups):
        return None
    return [int(g, 16) for g in groups]


def public_address(ip: str) -> bool:
    """Whether an IP address, v4 or v6, is on the public internet. Anything that is not an address is not."""
    four = _v4(ip)
    if four is not None:
        return _public_v4(four)
    g = _v6(ip)
    if g is None:
        return False

    def embedded(hi: int, lo: int) -> list[int]:
        return [hi >> 8, hi & 255, lo >> 8, lo & 255]

    # IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64 (64:ff9b::/96).
    if all(x == 0 for x in g[:5]) and g[5] in (0xFFFF, 0):
        return False if g[5] == 0 and g[6] == 0 and g[7] <= 1 else _public_v4(embedded(g[6], g[7]))
    if g[0] == 0x64 and g[1] == 0xFF9B and all(x == 0 for x in g[2:6]):
        return _public_v4(embedded(g[6], g[7]))
    # 6to4 carries an IPv4 address in its second and third groups.
    if g[0] == 0x2002:
        return _public_v4(embedded(g[1], g[2]))
    if (g[0] & 0xFE00) == 0xFC00 or (g[0] & 0xFFC0) == 0xFE80 or (g[0] & 0xFF00) == 0xFF00:
        return False
    # Teredo, documentation, and discard prefixes.
    if g[0] == 0x2001 and g[1] in (0, 0xDB8):
        return False
    if g[0] == 0x100 and all(x == 0 for x in g[1:4]):
        return False
    return True


def lookup(name: str) -> list[str]:
    """Every address a name resolves to, v4 and v6, as getaddrinfo() gives them (the hosts file included). Empty
    when it does not resolve."""
    bare = _BRACKETS.sub("", name)
    if _v4(bare) is not None or _v6(bare) is not None:
        return [bare]
    try:
        found = socket.getaddrinfo(bare, None, proto=socket.IPPROTO_TCP)
    except (OSError, UnicodeError):
        return []
    addresses: list[str] = []
    for _family, _type, _proto, _name, address in found:
        text = str(address[0]).split("%")[0]
        if text not in addresses:
            addresses.append(text)
    return addresses


def public_addresses(name: str, lookup: Lookup | None = None) -> list[str]:
    """The public addresses a name resolves to, for setting up DNS records. None where it does not resolve.
    `lookup` stands in for DNS in tests."""
    try:
        addresses = (lookup or _default_lookup)(name)
    except Exception:
        return []
    out: list[str] = []
    for address in addresses:
        if public_address(address) and address not in out:
            out.append(address)
    return out


def resolves_privately(name: str, lookup: Lookup | None = None) -> bool:
    """Whether a name resolves to an address off the public internet. False when it does not resolve. `lookup`
    stands in for DNS in tests."""
    try:
        addresses = (lookup or _default_lookup)(name)
    except Exception:
        return False
    return any(not public_address(address) for address in addresses)


def _default_lookup(name: str) -> list[str]:
    return lookup(name)


_names_only = False


def public_fetch_names_only(on: bool) -> None:
    """For tests: public_fetch asks the Fetcher without looking names up, as TypeScript's publicFetchThroughGlobal
    does, since a test makes them up. Addresses written as an IP, and localhost, are still refused."""
    global _names_only
    _names_only = on


def public_fetch(target: str, init: dict[str, Any], fetcher: Fetcher | None = None) -> Response:
    """Fetches an https URL on the public internet, following up to `redirects`
    redirects that stay on it, within `timeoutMs` in all. Only a GET follows
    redirects; anything else comes back with the redirect as it is. Raises a
    PrivateAddressError for an address off it, and a FetchError with
    `timed_out` when time runs out. A redirect past the last one comes back as
    it is. `maxBytes` and `truncate` go to the Fetcher, for a capped read.
    `lookup` stands in for DNS in tests.

    `init` holds timeoutMs, and optionally method, headers, body, redirects, maxBytes, truncate, and lookup."""
    fetcher = fetcher or UrllibFetcher()
    names_only = _names_only and not init.get("lookup")
    resolve: Lookup = init.get("lookup") or _default_lookup
    method = str(init.get("method") or "GET").upper()
    redirects = (init.get("redirects") or 0) if method == "GET" else 0
    until = time.monotonic() + init["timeoutMs"] / 1000
    url = Url(target)
    hop = 0
    while True:
        if url.protocol != "https:":
            raise PrivateAddressError(url.href)
        host = _BRACKETS.sub("", url.hostname).lower()
        literal = _v4(host) is not None or _v6(host) is not None
        if literal and not public_address(host):
            raise PrivateAddressError(host)
        if host.rstrip(".") == "localhost" or host.rstrip(".").endswith(".localhost"):
            raise PrivateAddressError(host)
        pin: list[str] = []
        if not literal and not names_only:
            # The address checked is the address used: every one the name gives must be public, and the
            # connection is pinned to them, so a second lookup cannot hand back another.
            addresses = resolve(host)
            if not addresses:
                raise FetchError(f"getaddrinfo ENOTFOUND {host}")
            for address in addresses:
                if not public_address(address):
                    raise PrivateAddressError(host)
            port = url.port or "443"
            pin = [f"{host}:{port}:" + ",".join(f"[{a}]" if ":" in a else a for a in addresses)]
        left = int((until - time.monotonic()) * 1000)
        if left <= 0:
            raise _timed_out()
        options: dict[str, Any] = {"headers": init.get("headers") or {}, "redirect": "manual", "timeoutMs": left}
        if method != "GET":
            options["method"] = method
        for key in ("body", "maxBytes", "truncate"):
            if init.get(key) is not None:
                options[key] = init[key]
        if pin:
            options["resolve"] = pin
        try:
            answer = fetcher.fetch(url.href, options)
        except FetchError as error:
            # Whichever way the request gave up, the caller hears that time ran out.
            if error.timed_out or time.monotonic() >= until:
                raise _timed_out() from error
            raise
        location = answer.headers.get("location")
        if answer.status < 300 or answer.status >= 400 or not location or hop >= redirects:
            return answer
        url = Url(location, url.href)
        hop += 1


def _timed_out() -> FetchError:
    return FetchError("The operation was aborted due to timeout", True)


# An install on this machine: http://localhost or http://127.0.0.1, with any port.
_LOCAL_INSTALL = re.compile(r"http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/|\Z)")


def install_address(url: str, local: bool) -> bool:
    """Whether an address can be another Runlight install's: https, or, with `local`, an install on this machine,
    which only code can allow."""
    return bool(re.match(r"https://[^/]+", url)) or (local and bool(_LOCAL_INSTALL.match(url)))


def install_fetch(target: str, init: dict[str, Any], fetcher: Fetcher | None = None) -> Response:
    """Fetches from another Runlight install, which someone signed in named: a public address as public_fetch
    fetches it, with no redirect followed, so a token sent there goes nowhere else. With `local` in `init`, an
    install on this machine is fetched as it is, still without following a redirect."""
    rest = {k: v for k, v in init.items() if k != "local"}
    if init.get("local") and _LOCAL_INSTALL.match(target):
        return (fetcher or UrllibFetcher()).fetch(target, {**rest, "redirect": "manual"})
    return public_fetch(target, {**rest, "redirects": 0}, fetcher)
