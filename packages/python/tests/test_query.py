"""Replays the query fixture written from the TypeScript SDK."""

from __future__ import annotations

from support import fixtures

from runlight import query


def test_dimension_lists() -> None:
    fixture = fixtures.load("query")
    assert query.EVENT_DIMENSIONS == fixture["eventDimensions"]
    assert list(query.EVENT_DIMENSIONS) == list(fixture["eventDimensions"])
    assert query.SESSION_DIMENSIONS == fixture["sessionDimensions"]
    assert list(query.SESSION_DIMENSIONS) == list(fixture["sessionDimensions"])
    assert query.DIMENSIONS == fixture["dimensions"]
    assert query.MAX_FILTERS == fixture["maxFilters"]


def test_dimension_tests() -> None:
    for case in fixtures.load("query")["dimensionTests"]:
        value = case["value"]
        assert [query.is_dimension(value), query.is_session_dimension(value), query.is_event_dimension(value)] == [
            case["isDimension"],
            case["isSessionDimension"],
            case["isEventDimension"],
        ], value


def test_parse_filter() -> None:
    for case in fixtures.load("query")["filters"]:
        assert query.parse_filter(case["text"]) == case["filter"], fixtures.label(case["text"])
