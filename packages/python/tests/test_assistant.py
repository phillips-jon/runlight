"""The assistant against tests/fixtures/assistant.json: for each provider and failure, the very requests the
TypeScript sends (bodies compared by SHA-256), the API reads its tools make, and what it answers."""

from __future__ import annotations

import hashlib
from typing import Any

import pytest
from support import fixtures
from test_mcp import read_api

from runlight import _js
from runlight.assistant import AssistantError, acknowledgement, chat, list_models
from runlight.http import FetchError, Response

CONTEXT = {"site": {"id": "default", "name": "Blog", "timezone": "UTC"}, "today": "2026-10-08", "view": "today", "language": "en"}


class RecordingFetcher:
    """A Fetcher that records each request and answers from a queue: a Response, or "timeout" or "network" to fail."""

    def __init__(self, queue: list[Any] | None = None) -> None:
        self.queue = list(queue or [])
        self.requests: list[dict[str, Any]] = []

    def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
        init = init or {}
        self.requests.append(
            {
                "url": url,
                "method": init.get("method", "GET"),
                "headers": dict(init.get("headers") or {}),
                "body": init.get("body"),
                "timeoutMs": init.get("timeoutMs"),
            }
        )
        if not self.queue:
            raise RuntimeError("No canned answer left")
        answer = self.queue.pop(0)
        if answer == "timeout":
            raise FetchError("The operation timed out", True)
        if answer == "network":
            raise FetchError("Could not connect")
        return answer


def test_scenarios_send_the_same_requests_and_answer_the_same() -> None:
    for scenario in fixtures.load("assistant")["scenarios"]:
        name = scenario["name"]
        queue = [c["throws"] if "throws" in c else Response(c["body"], c["status"], {"content-type": "application/json"}) for c in scenario["responses"]]
        fetcher = RecordingFetcher(queue)
        tools: list[Any] = []
        try:
            if scenario["call"] == "chat":
                result = chat(scenario["settings"], scenario["messages"], scenario["context"], read_api(tools, "assistant"), fetcher=fetcher)
            else:
                result = list_models(scenario["settings"], fetcher)
            assert "result" in scenario, f"{name} answered {_js.dumps(result)}"
            assert _js.dumps(result) == _js.dumps(scenario["result"]), name
        except AssistantError as error:
            assert "error" in scenario, f"{name} threw {error}"
            assert str(error) == scenario["error"]["message"], name
            assert error.code == scenario["error"]["code"], name
            assert _js.dumps(error.params) == _js.dumps(scenario["error"]["params"]), name
        assert _js.dumps(tools) == _js.dumps(scenario["tools"]), f"{name} read the API differently"
        assert len(fetcher.requests) == len(scenario["requests"]), name
        for i, expected in enumerate(scenario["requests"]):
            sent = fetcher.requests[i]
            assert sent["url"] == expected["url"], f"{name} request {i}"
            assert sent["method"] == expected["method"], f"{name} request {i}"
            assert _js.dumps(sent["headers"]) == _js.dumps(expected["headers"]), f"{name} request {i} headers"
            body = sent["body"]
            sha = None if body is None else hashlib.sha256(_js.encode(body)).hexdigest()
            assert sha == expected["bodySha256"], f"{name} request {i} body: {body}"


def test_acknowledgements_match() -> None:
    for case in fixtures.load("assistant")["acknowledgements"]:
        assert acknowledgement(case["text"], case["language"]) == case["reply"], _js.dumps([case["text"], case["language"]])


def test_thanks_gets_a_short_reply_without_the_model_or_the_tools() -> None:
    for text in ["Thanks!", "thank you", "Thanks!! 🙏", "ok", "Great, thanks.", "👍", "merci beaucoup", "Danke schön!", "valeu"]:
        assert acknowledgement(text, "en") is not None, text
    for text in ["Thanks, and what about last week?", "What was my bounce rate?", "ok so which pages?", "great results?"]:
        assert acknowledgement(text, "en") is None, text
    assert "plaisir" in (acknowledgement("merci", "fr") or "")


def test_each_request_has_the_time_left_and_the_deadline_stops_the_rest() -> None:
    clock = [1_000_000]

    def tool_use(id: str) -> Response:
        return Response(_js.dumps({"stop_reason": "tool_use", "content": [{"type": "tool_use", "id": id, "name": "list_sites", "input": {}}]}))

    fetcher = RecordingFetcher([tool_use("a"), tool_use("b"), tool_use("c")])
    log: list[Any] = []
    read = read_api(log)

    def slow_api(path: str, params: Any) -> Response:
        clock[0] += 50_000
        return read(path, params)

    with pytest.raises(AssistantError) as caught:
        chat({"provider": "anthropic", "model": "m", "baseUrl": "", "key": "k"}, [{"role": "user", "content": "All of it"}], CONTEXT, slow_api, fetcher=fetcher, now=lambda: clock[0])
    assert caught.value.code == "assistant_slow"
    assert [r["timeoutMs"] for r in fetcher.requests] == [90_000, 70_000, 20_000]
    assert len(log) == 3


def test_a_cancelled_question_stops_before_its_next_request() -> None:
    fetcher = RecordingFetcher([])
    log: list[Any] = []
    with pytest.raises(AssistantError) as caught:
        chat({"provider": "openai", "model": "m", "baseUrl": "", "key": "k"}, [{"role": "user", "content": "Hi?"}], CONTEXT, read_api(log), lambda: True, fetcher)
    assert caught.value.code == "assistant_cancelled"
    assert str(caught.value) == "The question was cancelled."
    assert fetcher.requests == []


def test_models_are_listed_within_twenty_seconds() -> None:
    fetcher = RecordingFetcher([Response('{"data":[{"id":"b"},{"id":"a"}]}')])
    assert list_models({"provider": "ollama", "baseUrl": "", "key": ""}, fetcher) == [{"id": "a", "name": "a"}, {"id": "b", "name": "b"}]
    assert fetcher.requests[0]["timeoutMs"] == 20_000
    assert fetcher.requests[0]["url"] == "http://localhost:11434/v1/models"
