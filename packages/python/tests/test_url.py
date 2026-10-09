"""Replays conformance/url.json: URLs, query strings, and numbers read and written as JavaScript does."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from runlight import _js
from runlight.http import SearchParams, Url

FIXTURE = json.loads((Path(__file__).parents[3] / "conformance" / "url.json").read_text())

CASES = [(c["input"], None, c["expect"]) for c in FIXTURE["urls"]] + [
    (c["input"], c["base"], c["expect"]) for c in FIXTURE["relative"]
]


@pytest.mark.parametrize(("text", "base", "expect"), CASES, ids=[json.dumps([c[0], c[1]]) for c in CASES])
def test_url(text: str, base: str | None, expect: dict | None) -> None:
    url = Url.parse(text, base)
    if expect is None:
        assert url is None, f"{text} should not parse"
        return
    assert url is not None, f"{text} should parse"
    assert {
        "href": url.href,
        "protocol": url.protocol,
        "username": url.username,
        "password": url.password,
        "hostname": url.hostname,
        "port": url.port,
        "host": url.host,
        "origin": url.origin,
        "pathname": url.pathname,
        "search": url.search,
        "hash": url.hash,
    } == expect


def test_queries() -> None:
    for case in FIXTURE["queries"]:
        params = SearchParams(case["input"])
        assert [list(p) for p in params] == case["pairs"], case["input"]
        assert params.to_string() == case["string"], case["input"]
    for case in FIXTURE["written"]:
        params = SearchParams()
        for name, value in case["pairs"]:
            params.append(name, value)
        assert params.to_string() == case["string"]


def test_numbers() -> None:
    for case in FIXTURE["numbers"]:
        n = float(case["n"]) if isinstance(case["n"], str) else case["n"]
        assert _js.number_text(n) == case["text"], case["n"]


def test_json_matches_stringify() -> None:
    assert _js.dumps({"a": 1.0, "b": [1e21, 1e-7, 0.1], "c": " /é", "2": None, "1": _js.UNDEFINED}) == (
        '{"2":null,"a":1,"b":[1e+21,1e-7,0.1],"c":" /é"}'
    )
    assert _js.dumps([_js.UNDEFINED, float("nan")]) == "[null,null]"
    assert _js.dumps({"a": [1, {}]}, 2) == '{\n  "a": [\n    1,\n    {}\n  ]\n}'


def test_text_helpers() -> None:
    assert _js.length("a😀") == 3
    assert _js.slice16("a😀b", 0, 2) == "a�"
    assert _js.cut("a😀b", 2) == "a"
    assert _js.js_round(-2.5) == -2
    assert _js.js_round(0.49999999999999994) == 0
    assert _js.number(" 0x10 ") == 16
    assert _js.number("1e3") == 1000
    assert _js.number("abc") != _js.number("abc")
    assert _js.decode_uri_component("%E0%A4%A") is None
    assert _js.encode_uri_component("a b/ü!") == "a%20b%2F%C3%BC!"
    assert _js.compare("￿", "😀") == 1
    assert _js.to_fixed(1.005, 2) == "1.00"
    assert _js.to_fixed(2.5, 0) == "3"
