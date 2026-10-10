"""The route-level part of hardening.test.ts: a link domain's check, and the warning about trustProxy left at its
default. The rest belongs to the core, safefetch, and the stores."""

from __future__ import annotations

import pytest

from runlight.http import Request, Response
from support.routes import body, owner, runlight


class _Answers404:
    def fetch(self, url, init=None):
        return Response("no", 404)


def test_a_link_domains_check_says_where_the_domain_should_point_for_its_setup_steps() -> None:
    rl = runlight({"site": {"hostnames": ["example.com"]}, "fetcher": _Answers404()})
    rl.init()
    rl.store.add_link_domain("go.example.net", "default", 0)
    check = body(rl.routes({"token": "secret"}).handle(owner("/runlight/api/link-domains/go.example.net/check")))
    assert check["target"]["host"] == "example.com", "this dashboard's own name, for a CNAME"
    assert isinstance(check["target"]["addresses"], list)
    assert check["working"] is False


def test_with_trust_proxy_left_at_its_default_a_public_address_with_no_proxy_header_is_warned_about_once(
    capsys: pytest.CaptureFixture[str],
) -> None:
    bare = Request("https://example.com/e")
    forwarded = Request("https://example.com/e", headers={"x-forwarded-for": "8.8.4.4"})
    quiet = runlight({"site": {"hostnames": ["example.com"]}, "trustProxy": True})
    assert quiet.client_ip(bare, {"ip": "8.8.8.8"}) == "8.8.8.8"
    assert capsys.readouterr().err == "", "trustProxy set on purpose is never second-guessed"

    rl = runlight({"site": {"hostnames": ["example.com"]}})
    rl.client_ip(forwarded, {"ip": "10.0.0.2"})
    rl.client_ip(bare, {"ip": "127.0.0.1"})
    rl.client_ip(bare, {"ip": "192.168.1.5"})
    assert capsys.readouterr().err == "", "a proxy's header, or a private or loopback address, says nothing"
    assert rl.client_ip(bare, {"ip": "8.8.8.8"}) == "8.8.8.8"
    rl.client_ip(bare, {"ip": "1.1.1.1"})
    said = capsys.readouterr().err.splitlines()
    assert len(said) == 1, "said once"
    assert "trust_proxy=False" in said[0]
