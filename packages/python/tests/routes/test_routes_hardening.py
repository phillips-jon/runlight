"""The route-level part of hardening.test.ts: a link domain's check. The rest belongs to the core, safefetch, and
the stores."""

from __future__ import annotations

from runlight.http import Response
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
