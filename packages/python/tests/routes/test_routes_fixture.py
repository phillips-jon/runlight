"""Replays packages/php/tests/fixtures/routes.json, which scripts/php-fixtures-routes.mts writes from the
TypeScript SDK: the dashboard's page, the tracker, refusals with their codes, and OAuth's documents, each answer
byte for byte with every header, and the helpers routes.ts and oauth.ts export."""

from __future__ import annotations

import hashlib

import pytest

from runlight.http import Request
from runlight.routes import coded, host_name, manage_path
from support.conformance import TEXT_BODY_TYPE
from support.fixtures import load
from support.routes import runlight

FIXTURE = load("routes")


@pytest.mark.parametrize("index", range(len(FIXTURE["exchanges"])), ids=[e["name"] for e in FIXTURE["exchanges"]])
def test_answers_as_the_typescript_does(index: int) -> None:
    exchange = FIXTURE["exchanges"][index]
    now = FIXTURE["now"]
    rl = runlight({**exchange["runlight"], "now": lambda: now})
    routes = rl.routes(exchange["routes"])
    for answer in exchange["answers"]:
        ask = answer["ask"]
        method = ask.get("method", "GET")
        label = f"{method} {ask['path']}"
        headers = {k.lower(): v for k, v in (ask.get("headers") or {}).items()}
        if "body" in ask and "content-type" not in headers:
            headers["content-type"] = TEXT_BODY_TYPE
        response = routes.handle(Request("https://example.com" + ask["path"], method, headers, ask.get("body", "")))
        assert response.status == answer["status"], f"{label}: status"
        got = {name: values if name == "set-cookie" else ", ".join(values) for name, values in response.headers.all().items()}
        assert dict(sorted(got.items())) == dict(sorted(answer["headers"].items())), f"{label}: headers"
        text = response.text()
        if "sha256" in answer:
            assert hashlib.sha256(text.encode("utf-8")).hexdigest() == answer["sha256"], f"{label}: body"
        else:
            assert text == answer["text"], f"{label}: body"


def test_coded_errors_are_the_same_bytes() -> None:
    for case in FIXTURE["coded"]:
        error, code, status, params, headers = case["args"]
        response = coded(error, code, status, params, headers)
        assert response.status == case["status"]
        assert response.text() == case["text"], code
        got = {name: ", ".join(values) for name, values in response.headers.all().items()}
        assert dict(sorted(got.items())) == dict(sorted(case["headers"].items())), code


def test_host_names_are_bare_as_the_typescript_makes_them() -> None:
    for given, want in FIXTURE["hostName"]:
        assert host_name(given) == want, given


def test_manage_paths_are_the_same() -> None:
    for method, path, want in FIXTURE["managePath"]:
        assert manage_path(method, path) is want, f"{method} {path}"


def test_pkce_s256_matches_the_typescript() -> None:
    from runlight.oauth import s256

    for verifier, want in FIXTURE["s256"]:
        assert s256(verifier) == want, verifier
    # RFC 7636's own example.
    assert s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"


def test_resource_metadata_url() -> None:
    from runlight.oauth import resource_metadata_url

    for origin, base, want in FIXTURE["resourceMetadataUrl"]:
        assert resource_metadata_url(origin, base) == want
