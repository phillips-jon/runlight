"""Replays tracker bodies through parse_payload, as the TypeScript SDK read them."""

from __future__ import annotations

from support import fixtures

from runlight import _js
from runlight.payload import MAX_BODY, parse_payload


def test_fixture() -> None:
    fixture = fixtures.load("payload")
    assert MAX_BODY == fixture["maxBody"]
    for case in fixture["cases"]:
        payload = parse_payload(case["text"])
        if payload is not None:
            payload["url"] = payload["url"].href
            payload["props"] = None if payload["props"] is None else _js.dumps(payload["props"])
        assert _js.dumps(payload) == _js.dumps(case["payload"]), fixtures.label(case["text"])


def test_props_with_index_keys_stay_an_object() -> None:
    payload = parse_payload('{"k":"event","u":"https://example.com/","n":"x","p":{"1":"b","0":"a"}}')
    assert list(payload["props"]) == ["0", "1"]
    assert _js.dumps(payload["props"]) == '{"0":"a","1":"b"}'


def test_deep_nesting_parses_as_javascript_reads_it() -> None:
    deep = "[" * 3000 + "]" * 3000
    payload = parse_payload('{"k":"pageview","u":"https://example.com/","x":' + deep + "}")
    assert payload is not None
    assert payload["kind"] == "pageview"
