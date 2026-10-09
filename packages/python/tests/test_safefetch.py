"""Ports safefetch.test.ts, replays the address checks in the outbound fixture, and covers each hop's checks."""

from __future__ import annotations

import select
import socket
from collections.abc import Callable

import pytest
from support import fixtures
from support.fake_fetcher import FakeFetcher

from runlight.http import FetchError, Response
from runlight.safefetch import PrivateAddressError, public_address, public_addresses, public_fetch
from runlight.safefetch import resolves_privately


def urls(fetcher: FakeFetcher) -> list[str]:
    return [r["url"] for r in fetcher.requests]


def dns(names: dict[str, list[str]]) -> Callable[[str], list[str]]:
    """A DNS stand-in."""
    return lambda name: names.get(name, [])


def hops(answers: list[Response]) -> FakeFetcher:
    queue = list(answers)
    return FakeFetcher(lambda url, init: queue.pop(0) if queue else Response("end"))


def test_only_addresses_on_the_public_internet_count_as_public() -> None:
    for ip in ["93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e"]:
        assert public_address(ip), ip
    for ip in [
        "127.0.0.1", "10.0.0.1", "172.16.5.4", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1",
        "255.255.255.255", "::1", "::", "fe80::1", "fd00::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:7f00:1",
        "::ffff:169.254.169.254", "64:ff9b::a00:1", "2002:a00:1::", "2001:db8::1", "2001:0:4136:e378::1", "[::1]",
        "not an address", "1.2.3", "1.2.3.256",
    ]:  # fmt: skip
        assert not public_address(ip), ip


def test_address_checks_match_typescript() -> None:
    for case in fixtures.load("outbound")["ips"]:
        assert public_address(case["ip"]) == case["public"], case["ip"]


def test_a_public_fetch_never_reaches_the_installs_own_network_however_the_address_is_written() -> None:
    # Something listening locally, which none of these may reach.
    inside = socket.socket()
    inside.bind(("127.0.0.1", 0))
    inside.listen()
    port = inside.getsockname()[1]
    try:
        for url in [
            f"http://127.0.0.1:{port}/", f"https://127.0.0.1:{port}/", f"https://[::1]:{port}/",
            f"https://[::ffff:127.0.0.1]:{port}/", f"https://localhost:{port}/", f"https://LOCALHOST.:{port}/",
            f"https://app.localhost:{port}/",
        ]:  # fmt: skip
            with pytest.raises(PrivateAddressError):
                public_fetch(url, {"timeoutMs": 2000})
        ready, _, _ = select.select([inside], [], [], 0)
        assert ready == [], "nothing connected"
        assert resolves_privately("localhost")
        assert not resolves_privately("name.that.does.not.resolve.invalid")
        assert public_addresses("name.that.does.not.resolve.invalid") == []
        assert public_addresses("8.8.8.8") == ["8.8.8.8"]
        assert public_addresses("localhost") == []
    finally:
        inside.close()


def test_the_checked_addresses_are_pinned() -> None:
    fetcher = FakeFetcher(lambda url, init: Response("ok"))
    answer = public_fetch(
        "https://Example.com/icon",
        {
            "timeoutMs": 2000,
            "headers": {"user-agent": "Runlight"},
            "maxBytes": 10,
            "lookup": dns({"example.com": ["93.184.215.14", "2606:4700::1111"]}),
        },
        fetcher,
    )
    assert answer.text() == "ok"
    assert fetcher.inits[0]["resolve"] == ["example.com:443:93.184.215.14,[2606:4700::1111]"]
    assert fetcher.inits[0]["redirect"] == "manual"
    assert fetcher.inits[0]["maxBytes"] == 10
    assert fetcher.inits[0]["headers"] == {"user-agent": "Runlight"}
    assert urls(fetcher) == ["https://example.com/icon"]

    literal = FakeFetcher(lambda url, init: Response("ok"))
    public_fetch("https://93.184.215.14:8443/", {"timeoutMs": 2000, "lookup": dns({})}, literal)
    # An address needs no pin.
    assert "resolve" not in literal.inits[0]


def test_a_name_with_any_private_address_is_refused() -> None:
    fetcher = FakeFetcher(lambda url, init: Response("ok"))
    for name, addresses in {
        "inside.example": ["10.0.0.5"],
        "mixed.example": ["93.184.215.14", "169.254.169.254"],
        "mapped.example": ["::ffff:127.0.0.1"],
    }.items():
        with pytest.raises(PrivateAddressError, match=f"^{name} is not a public address$"):
            public_fetch(f"https://{name}/", {"timeoutMs": 2000, "lookup": dns({name: addresses})}, fetcher)
    assert urls(fetcher) == []
    with pytest.raises(FetchError):
        public_fetch("https://nowhere.example/", {"timeoutMs": 2000, "lookup": dns({})}, fetcher)


def test_redirects_are_followed_by_hand_under_the_same_rules() -> None:
    lookup = dns({"a.example": ["93.184.215.14"], "b.example": ["1.1.1.1"], "inside.example": ["192.168.0.2"]})

    fetcher = hops([Response.redirect("/next", 301), Response.redirect("https://b.example/last", 302), Response("done")])
    answer = public_fetch("https://a.example/", {"timeoutMs": 2000, "redirects": 3, "lookup": lookup}, fetcher)
    assert answer.text() == "done"
    assert urls(fetcher) == ["https://a.example/", "https://a.example/next", "https://b.example/last"]
    assert fetcher.inits[2]["resolve"] == ["b.example:443:1.1.1.1"]

    fetcher = hops([Response.redirect("https://b.example/", 302)])
    # A redirect past the last comes back as it is.
    assert public_fetch("https://a.example/", {"timeoutMs": 2000, "lookup": lookup}, fetcher).status == 302

    for location, what in {
        "https://10.0.0.1/": "10.0.0.1",
        "https://inside.example/": "inside.example",
        "http://b.example/": "http://b.example/",
        "https://[fe80::1]/": "fe80::1",
    }.items():
        with pytest.raises(PrivateAddressError) as raised:
            public_fetch(
                "https://a.example/",
                {"timeoutMs": 2000, "redirects": 3, "lookup": lookup},
                hops([Response.redirect(location)]),
            )
        assert str(raised.value) == f"{what} is not a public address"


def test_running_out_of_time_says_so() -> None:
    def times_out(url: str, init: dict) -> Response:
        raise FetchError("Operation timed out", True)

    with pytest.raises(FetchError) as raised:
        public_fetch("https://a.example/", {"timeoutMs": 2000, "lookup": dns({"a.example": ["1.1.1.1"]})}, FakeFetcher(times_out))
    assert raised.value.timed_out
    assert str(raised.value) == "The operation was aborted due to timeout"

    def refuses(url: str, init: dict) -> Response:
        raise FetchError("Connection refused")

    with pytest.raises(FetchError, match="Connection refused"):
        public_fetch("https://a.example/", {"timeoutMs": 2000, "lookup": dns({"a.example": ["1.1.1.1"]})}, FakeFetcher(refuses))
