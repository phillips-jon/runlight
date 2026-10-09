"""The dashboard's assistant: questions about the stats, answered by a model
the owner chooses, through the same read-only tools as the MCP server. The
model runs on the server, so the key never reaches a browser, and each tool
reads the API with the asking person's own access.

Two protocols cover the providers: Anthropic's Messages API, and OpenAI's
Chat Completions, which OpenAI, Gemini (through its compatible endpoint),
OpenRouter, Ollama, LM Studio, and most others speak. Plain HTTP through a
Fetcher, no SDKs.

Settings are dicts {provider, model, baseUrl, key}; messages are lists of {role: "user" | "assistant", content};
the context (what the person is looking at, so "this week" and "this page" mean what they see) is
{site: {id, name, timezone}, today, view, language}.
"""

from __future__ import annotations

import re
import time
import unicodedata
from collections.abc import Callable
from typing import Any

from . import _js
from .http import Fetcher, FetchError, Url, UrllibFetcher
from .mcp import INSTRUCTIONS, TOOLS, ApiRead, call_tool

# Each provider: id, name, protocol ("anthropic" or "openai"), baseUrl (the API's address, filled in for known
# services and asked for otherwise), model (one to start with, or "" when the person picks one), and key ("yes",
# "no" for a model on your own machine, or "optional").
PROVIDERS: list[dict[str, str]] = [
    {"id": "anthropic", "name": "Anthropic (Claude)", "protocol": "anthropic", "baseUrl": "https://api.anthropic.com/v1", "model": "claude-sonnet-5-5", "key": "yes"},  # noqa: E501
    {"id": "openai", "name": "OpenAI", "protocol": "openai", "baseUrl": "https://api.openai.com/v1", "model": "", "key": "yes"},
    {"id": "gemini", "name": "Google Gemini", "protocol": "openai", "baseUrl": "https://generativelanguage.googleapis.com/v1beta/openai", "model": "", "key": "yes"},  # noqa: E501
    {"id": "openrouter", "name": "OpenRouter", "protocol": "openai", "baseUrl": "https://openrouter.ai/api/v1", "model": "", "key": "yes"},
    {"id": "ollama", "name": "Ollama", "protocol": "openai", "baseUrl": "http://localhost:11434/v1", "model": "", "key": "no"},
    {"id": "lmstudio", "name": "LM Studio", "protocol": "openai", "baseUrl": "http://localhost:1234/v1", "model": "", "key": "no"},
    {"id": "custom", "name": "Another OpenAI-compatible service", "protocol": "openai", "baseUrl": "", "model": "", "key": "optional"},
]


class AssistantError(Exception):
    """What went wrong with the assistant, as a code the dashboard says in its own words; a service's own text goes in
    `detail`."""

    def __init__(self, message: str, code: str, params: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = params or {}


MAX_ROUNDS = 8
# However many rounds a question takes, the answer comes within this long or the assistant stops.
DEADLINE_MS = 120_000
MAX_TOKENS = 1500


def _system(context: dict[str, Any]) -> str:
    site = context["site"]
    return f"""{INSTRUCTIONS}

You are the assistant inside this Runlight dashboard. Today is {context["today"]} in {site["timezone"]}. The person is looking at the site "{site["name"]}" (id {site["id"]}) for {context["view"]}. Unless they ask about another site or range, use this site and these dates.

When a question needs numbers, read them with the tools first and never guess one. Answer in a few short sentences or a short list, in plain language, and name the dates you looked at.

Rule: answer only the newest message. If it asks nothing new (thanks, a greeting, "great", "that helps"), reply with one short friendly sentence, call no tools, and do not repeat, summarise, or re-check any earlier answer. Only go back to earlier numbers when the person asks about them again. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a percent and in seconds or minutes. Write in the language whose code is "{context["language"]}"."""  # noqa: E501


TOO_LONG = "That question took too long to answer. Try asking something narrower."


def _clock() -> int:
    return int(time.time() * 1000)


def _in_time(deadline: int, now: Callable[[], int], cancelled: Callable[[], bool] | None) -> None:
    """Stops when the question's time is up or the person has left, before more work starts."""
    if cancelled is not None and cancelled():
        raise AssistantError("The question was cancelled.", "assistant_cancelled")
    if now() >= deadline:
        raise AssistantError(TOO_LONG, "assistant_slow")


def _host(url: str) -> str:
    """new URL(url).host, which throws a TypeError for text that is no address."""
    parsed = Url.parse(url)
    if parsed is None:
        raise TypeError("Invalid URL")
    return parsed.host


def _keep16(text: str, units: int) -> str:
    """text.slice(0, units) in UTF-16 units, keeping half of a pair that is cut in two as JavaScript does, so
    JSON.stringify writes it as the same escape."""
    if text.isascii():
        return text[:units]
    data = text.encode("utf-16-le", "surrogatepass")[: units * 2]
    return data.decode("utf-16-le", "surrogatepass")


def _service_message(data: Any) -> str:
    """The service's own message from an error answer, never the request (it carries the key); "" when there is
    none."""
    error = _js.UNDEFINED if data is None else _js.get(data, "error")
    if isinstance(error, str):
        return error
    message = None if error is None or error is _js.UNDEFINED else _js.get(error, "message")
    return message if isinstance(message, str) else ""


def _post(
    fetcher: Fetcher,
    url: str,
    headers: dict[str, str],
    body: Any,
    deadline: int,
    now: Callable[[], int],
    cancelled: Callable[[], bool] | None,
) -> Any:
    _in_time(deadline, now, cancelled)
    left = deadline - now()
    try:
        answer = fetcher.fetch(
            url,
            {
                "method": "POST",
                "headers": {"content-type": "application/json", **headers},
                "body": _js.dumps(body),
                "timeoutMs": min(90_000, left),
            },
        )
    except Exception as error:
        host = _host(url)
        if isinstance(error, FetchError) and error.timed_out:
            raise AssistantError(f"Could not reach {host}: it took too long to answer", "assistant_timeout", {"host": host}) from None
        raise AssistantError(f"Could not reach {host}: the connection failed", "unreachable", {"host": host}) from None
    ok, data = _js.try_loads(answer.content())
    if not ok:
        data = None
    if not answer.ok:
        # The service's own message, never the request (it carries the key).
        message = _service_message(data)
        host = _host(url)
        if not message:
            raise AssistantError(f"{host}: it answered {answer.status}", "assistant_status", {"host": host, "status": str(answer.status)})
        detail = _keep16(message, 300)
        raise AssistantError(f"{host}: {detail}", "assistant_refused", {"host": host, "detail": detail})
    return {} if data is None else data


def _tool_text(name: Any, args: Any, read_api: ApiRead) -> dict[str, Any]:
    try:
        result = call_tool({"name": name, "arguments": args if _js.truthy(args) and _js.is_object(args) else {}}, read_api)
        content = result["content"]
        text = content[0].get("text") if content else None
        return {"text": "" if text is None else text, "error": result.get("isError") is True}
    except Exception as error:
        return {"text": str(error), "error": True}


# Code points with Unicode's Extended_Pictographic property, as Node 24's regular expressions have them.
_PICTOGRAPHIC_RANGES = (
    "a9 ae 203c 2049 2122 2139 2194-2199 21a9-21aa 231a-231b 2328 23cf 23e9-23f3 23f8-23fa 24c2 25aa-25ab 25b6 25c0 "
    "25fb-25fe 2600-2604 260e 2611 2614-2615 2618 261d 2620 2622-2623 2626 262a 262e-262f 2638-263a 2640 2642 2648-2653 "
    "265f-2660 2663 2665-2666 2668 267b 267e-267f 2692-2697 2699 269b-269c 26a0-26a1 26a7 26aa-26ab 26b0-26b1 26bd-26be "
    "26c4-26c5 26c8 26ce-26cf 26d1 26d3-26d4 26e9-26ea 26f0-26f5 26f7-26fa 26fd 2702 2705 2708-270d 270f 2712 2714 2716 "
    "271d 2721 2728 2733-2734 2744 2747 274c 274e 2753-2755 2757 2763-2764 2795-2797 27a1 27b0 27bf 2934-2935 2b05-2b07 "
    "2b1b-2b1c 2b50 2b55 3030 303d 3297 3299 1f004 1f02c-1f02f 1f094-1f09f 1f0af-1f0b0 1f0c0 1f0cf-1f0d0 1f0f6-1f0ff "
    "1f170-1f171 1f17e-1f17f 1f18e 1f191-1f19a 1f1ae-1f1e5 1f201-1f20f 1f21a 1f22f 1f232-1f23a 1f23c-1f23f 1f249-1f25f "
    "1f266-1f321 1f324-1f393 1f396-1f397 1f399-1f39b 1f39e-1f3f0 1f3f3-1f3f5 1f3f7-1f3fa 1f400-1f4fd 1f4ff-1f53d "
    "1f549-1f54e 1f550-1f567 1f56f-1f570 1f573-1f57a 1f587 1f58a-1f58d 1f590 1f595-1f596 1f5a4-1f5a5 1f5a8 1f5b1-1f5b2 "
    "1f5bc 1f5c2-1f5c4 1f5d1-1f5d3 1f5dc-1f5de 1f5e1 1f5e3 1f5e8 1f5ef 1f5f3 1f5fa-1f64f 1f680-1f6c5 1f6cb-1f6d2 "
    "1f6d5-1f6e5 1f6e9 1f6eb-1f6f0 1f6f3-1f6ff 1f7da-1f7ff 1f80c-1f80f 1f848-1f84f 1f85a-1f85f 1f888-1f88f 1f8ae-1f8af "
    "1f8bc-1f8bf 1f8c2-1f8cf 1f8d9-1f8ff 1f90c-1f93a 1f93c-1f945 1f947-1f9ff 1fa58-1fa5f 1fa6e-1faff 1fc00-1fffd"
)


def _ranges_class(ranges: str) -> str:
    parts = []
    for item in ranges.split():
        first, _, last = item.partition("-")
        parts.append(f"\\U{int(first, 16):08x}" + (f"-\\U{int(last, 16):08x}" if last else ""))
    return "".join(parts)


# /\p{Extended_Pictographic}|️/gu
_PICTOGRAPHIC = re.compile(f"[{_ranges_class(_PICTOGRAPHIC_RANGES)}\\ufe0f]")

# Words that only acknowledge an answer, in the dashboard's languages; a message of nothing else gets a reply without
# the model.
_THANKS = re.compile(
    "^(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool|nice|perfect|awesome|got it|good"
    "|merci|merci beaucoup|super|parfait|d'accord|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank"
    f"|prima|alles klar|obrigado|obrigada|valeu|ótimo|beleza)[{_js.WHITESPACE}!.,]*)+\\Z",
    re.IGNORECASE,
)

WELCOME = {
    "en": "You're welcome. Ask me anything else about your stats.",
    "fr": "Avec plaisir. Demandez-moi autre chose sur vos statistiques.",
    "es": "De nada. Pregúntame lo que quieras sobre tus estadísticas.",
    "de": "Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.",
    "pt": "De nada. Pergunte o que quiser sobre suas estatísticas.",
}


def acknowledgement(text: str, language: str) -> str | None:
    """A short reply to a message that only says thanks or OK, or None when the message asks something."""
    plain = _js.trim(_PICTOGRAPHIC.sub(" ", text))
    welcome = WELCOME.get(language, WELCOME["en"])
    if not plain and _js.trim(text):
        return welcome
    return welcome if _THANKS.match(plain) else None


def _provider(id: Any) -> dict[str, str] | None:
    return next((p for p in PROVIDERS if p["id"] == id), None)


def _base(settings: dict[str, Any], provider: dict[str, str]) -> str:
    """(settings.baseUrl || provider.baseUrl).replace(/\\/+$/, "")"""
    given = settings.get("baseUrl")
    return re.sub(r"/+\Z", "", given if _js.truthy(given) else provider["baseUrl"])


def chat(
    settings: dict[str, Any],
    messages: list[dict[str, Any]],
    context: dict[str, Any],
    read_api: ApiRead,
    cancelled: Callable[[], bool] | None = None,
    fetcher: Fetcher | None = None,
    now: Callable[[], int] | None = None,
) -> dict[str, Any]:
    """Answers the last question in `messages`, calling tools as the model asks. Returns {reply, tools}: the reply
    and the tools it used. `cancelled` says whether the person has left, checked before each request and tool, as
    TS's AbortSignal is; `now` is the clock in milliseconds."""
    fetcher = fetcher or UrllibFetcher()
    now = now or _clock
    provider = _provider(settings.get("provider"))
    if provider is None:
        raise AssistantError("Choose a provider in Settings, AI Assistant", "assistant_provider")
    base = _base(settings, provider)
    if not base:
        raise AssistantError("Enter the service's address in Settings, AI Assistant", "assistant_address")
    model = settings.get("model") or provider["model"]
    if not model:
        raise AssistantError("Enter a model in Settings, AI Assistant", "assistant_model")
    key = str(settings.get("key") or "")
    used: list[Any] = []
    # "Thanks!" needs no model, no tools, and certainly not the last answer again.
    last = messages[-1].get("content") if messages else None
    thanks = acknowledgement("" if last is None else _js.string(last), context["language"])
    if thanks:
        return {"reply": thanks, "tools": []}
    deadline = now() + DEADLINE_MS
    # The last twenty turns, starting with a question (Anthropic refuses a history that opens with an answer),
    # and with unanswered questions in a row (a reply that never came) joined into one.
    recent = list(messages[-20:])
    while recent and recent[0].get("role") != "user":
        recent.pop(0)
    history: list[dict[str, Any]] = []
    for m in recent:
        content = _keep16(_js.string(m.get("content", _js.UNDEFINED)), 8000)
        if history and history[-1]["role"] == m.get("role"):
            history[-1]["content"] += f"\n\n{content}"
        else:
            history.append({"role": m.get("role"), "content": content})

    if provider["protocol"] == "anthropic":
        tools = [{"name": t["name"], "description": t["description"], "input_schema": t["inputSchema"]} for t in TOOLS]
        convo: list[Any] = history
        for _ in range(MAX_ROUNDS):
            data = _post(
                fetcher,
                f"{base}/messages",
                {"x-api-key": key, "anthropic-version": "2023-06-01"},
                {"model": model, "max_tokens": MAX_TOKENS, "system": _system(context), "tools": tools, "messages": convo},
                deadline,
                now,
                cancelled,
            )
            blocks = _js.get(data, "content")
            if blocks is None or blocks is _js.UNDEFINED:
                blocks = []
            if not isinstance(blocks, list):
                raise TypeError("blocks.filter is not a function")
            calls = [b for b in blocks if _js.get(b, "type") == "tool_use"]
            if _js.get(data, "stop_reason") != "tool_use" or not calls:
                texts = []
                for b in blocks:
                    if _js.get(b, "type") == "text":
                        text = _js.get(b, "text")
                        texts.append("" if text is None or text is _js.UNDEFINED else _js.string(text))
                return {"reply": _js.trim("\n".join(texts)), "tools": used}
            convo.append({"role": "assistant", "content": blocks})
            results = []
            for call in calls:
                # The deadline covers the reading too, however many tools one answer asks for.
                _in_time(deadline, now, cancelled)
                name = _js.get(call, "name")
                name = "" if name is None or name is _js.UNDEFINED else name
                used.append(name)
                out = _tool_text(name, _js.get(call, "input"), read_api)
                result: dict[str, Any] = {"type": "tool_result", "tool_use_id": _js.get(call, "id"), "content": out["text"]}
                if out["error"]:
                    result["is_error"] = True
                results.append(result)
            convo.append({"role": "user", "content": results})
        raise AssistantError("The assistant needed too many steps for that question. Try asking something narrower.", "assistant_steps")

    tools = [{"type": "function", "function": {"name": t["name"], "description": t["description"], "parameters": t["inputSchema"]}} for t in TOOLS]
    convo = [{"role": "system", "content": _system(context)}, *history]
    headers = {"authorization": f"Bearer {key}"} if key else {}
    for _ in range(MAX_ROUNDS):
        # OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services still take max_tokens.
        limit = {"max_completion_tokens": MAX_TOKENS} if provider["id"] == "openai" else {"max_tokens": MAX_TOKENS}
        data = _post(fetcher, f"{base}/chat/completions", headers, {"model": model, **limit, "messages": convo, "tools": tools}, deadline, now, cancelled)
        message = _first_message(data)
        calls = _js.get(message, "tool_calls")
        count = _js.UNDEFINED if calls is None or calls is _js.UNDEFINED else _js.get(calls, "length")
        content = _js.get(message, "content")
        if not _js.truthy(count):
            return {"reply": _js.trim("" if content is None or content is _js.UNDEFINED else _js.string(content)), "tools": used}
        if not isinstance(calls, list):
            raise TypeError("message.tool_calls is not iterable")
        convo.append({"role": "assistant", "content": None if content is _js.UNDEFINED else content, "tool_calls": calls})
        for call in calls:
            _in_time(deadline, now, cancelled)
            function = _js.get(call, "function")
            name = _js.get(function, "name")
            used.append(None if name is _js.UNDEFINED else name)
            given = _js.get(function, "arguments")
            try:
                args = _js.loads(_js.string(given) if _js.truthy(given) else "{}")
            except (ValueError, RecursionError):
                args = {}
            out = _tool_text(name, args, read_api)
            convo.append({"role": "tool", "tool_call_id": _js.get(call, "id"), "content": out["text"]})
    raise AssistantError("The assistant needed too many steps for that question. Try asking something narrower.", "assistant_steps")


def _first_message(data: Any) -> Any:
    """data.choices?.[0]?.message ?? {}"""
    choices = _js.get(data, "choices")
    if choices is None or choices is _js.UNDEFINED:
        return {}
    first = _js.get(choices, 0)
    if first is None or first is _js.UNDEFINED:
        return {}
    message = _js.get(first, "message")
    return {} if message is None or message is _js.UNDEFINED else message


# ICU's root collation of the printable ASCII characters, as Node's localeCompare orders them: each group shares a
# primary weight (a letter and its capital).
_ICU_ASCII = [
    " ", "_", "-", ",", ";", ":", "!", "?", ".", "'", '"', "(", ")", "[", "]", "{", "}", "@", "*", "/", "\\", "&", "#",
    "%", "`", "^", "+", "<", "=", ">", "|", "~", "$", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "aA", "bB",
    "cC", "dD", "eE", "fF", "gG", "hH", "iI", "jJ", "kK", "lL", "mM", "nN", "oO", "pP", "qQ", "rR", "sS", "tT", "uU",
    "vV", "wW", "xX", "yY", "zZ",
]  # fmt: skip
_ICU_RANK = {c: i for i, group in enumerate(_ICU_ASCII) for c in group}


def _locale_key(text: str) -> Any:
    """A sort key for `a.localeCompare(b)` as Node's ICU orders model ids: printable ASCII by ICU's root order,
    accented letters with their base letter and then by accent, and lower case before upper. Other characters
    follow, by code point."""
    primary = []
    accents = []
    cases = []
    for ch in text:
        base = unicodedata.normalize("NFD", ch)
        letter = base[0]
        rank = _ICU_RANK.get(letter)
        primary.append(rank if rank is not None else len(_ICU_ASCII) + ord(letter))
        accents.append(base[1:])
        cases.append(1 if letter != letter.lower() else 0)
    return (primary, accents, cases)


def list_models(settings: dict[str, Any], fetcher: Fetcher | None = None) -> list[dict[str, str]]:
    """The models a service offers with a key, from its own list: Anthropic's
    /models, or the /models of an OpenAI-compatible API. Newest or most
    relevant first where the service orders them; otherwise by name.
    `settings` is {provider, baseUrl, key}."""
    fetcher = fetcher or UrllibFetcher()
    provider = _provider(settings.get("provider"))
    if provider is None:
        raise AssistantError("Choose a provider", "assistant_provider")
    base = _base(settings, provider)
    if not base:
        raise AssistantError("Enter the service's address first", "assistant_address")
    key = str(settings.get("key") or "")
    if provider["key"] == "yes" and not key:
        raise AssistantError(f"Enter your {provider['name']} key first", "assistant_key", {"provider": provider["name"]})
    if provider["protocol"] == "anthropic":
        headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
    else:
        headers = {"authorization": f"Bearer {key}"} if key else {}
    try:
        answer = fetcher.fetch(f"{base}/models{'?limit=100' if provider['protocol'] == 'anthropic' else ''}", {"headers": headers, "timeoutMs": 20_000})
    except Exception:
        host = _host(base)
        raise AssistantError(f"Could not reach {host}", "unreachable", {"host": host}) from None
    ok, data = _js.try_loads(answer.content())
    if not ok:
        data = None
    if not answer.ok:
        message = _service_message(data)
        host = _host(base)
        if not message:
            raise AssistantError(f"{host}: it answered {answer.status}", "assistant_status", {"host": host, "status": str(answer.status)})
        detail = _keep16(message, 300)
        raise AssistantError(f"{host}: {detail}", "assistant_refused", {"host": host, "detail": detail})
    listed = _js.UNDEFINED if data is None else _js.get(data, "data")
    if listed is None or listed is _js.UNDEFINED:
        listed = []
    if not isinstance(listed, list):
        raise TypeError("data.data.filter is not a function")
    models = []
    for m in listed:
        id = _js.get(m, "id")
        if not isinstance(id, str) or not id:
            continue
        # Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the prefix.
        id = re.sub(r"^models/", "", id)
        display = _js.get(m, "display_name")
        models.append({"id": id, "name": display if isinstance(display, str) else id})
    if not models:
        host = _host(base)
        raise AssistantError(f"{host} listed no models. Type the model's name instead.", "assistant_no_models", {"host": host})
    # Anthropic lists newest first already; others come in no useful order.
    if provider["protocol"] == "anthropic":
        return models
    return sorted(models, key=lambda m: _locale_key(m["id"]))
