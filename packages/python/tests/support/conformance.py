"""Plays a scenario from conformance/http.json exactly as play() in packages/sdk/test/http-conformance.ts does,
and returns each step's answer, normalized, in the shape of the file's `expect`: dicts with status, headers, body,
text, files, found, fetched, or pass.

The scenario's options become the Runlight options, and a target (the core) takes the requests. Keep this file in
step with the TypeScript runner: FORMAT_SHA256 fails a test when the file's description of the format changes.
"""

from __future__ import annotations

import json
import os
import re
import zlib
from collections.abc import Callable
from pathlib import Path
from typing import Any

from runlight import _js
from runlight.http import BodyTooLong, FetchError, Headers, Request, Response, SearchParams, Url

FILE = Path(__file__).resolve().parents[4] / "conformance" / "http.json"

# The SHA-256 of http.json's description this runner was written against.
FORMAT_SHA256 = "87a6f2d7f8acd8026aa4c9ede697d21457a0b9c1a2bfc01488aa2d9598def68f"

# Environment the SDK reads defaults from, cleared while a scenario plays so nothing outside it counts.
ENV = ["RUNLIGHT_TOKEN", "RUNLIGHT_SECRET", "CRON_SECRET", "RUNLIGHT_OBSERVE_KEY", "NODE_ENV"]

# The content type JavaScript's Request gives a string body sent with none, which the TypeScript answers were
# made with.
TEXT_BODY_TYPE = "text/plain;charset=UTF-8"

# Headers every implementation must send the same, where it sends them.
HEADERS = [
    "content-type",
    "cache-control",
    "location",
    "set-cookie",
    "www-authenticate",
    "allow",
    "content-disposition",
    "content-security-policy",
    "x-frame-options",
    "referrer-policy",
    "x-content-type-options",
    "x-robots-tag",
    "access-control-allow-origin",
    "access-control-allow-methods",
    "access-control-allow-headers",
    "access-control-max-age",
]

# The version and the implementation differ between ports and releases, so they are placeholders too.
RANDOM = {"token", "secret", "hint", "version", "library", "language", "ticket", "recovery"}

_S = _js.WHITESPACE
_QUERY_SECRET = re.compile(f"([?&](?:code|ticket|secret|code_challenge)=)[^&#{_S}\"'<>]+")
_HEX_RUN = re.compile(r"(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])")
_KEY_RUN = re.compile(r"(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])")
_WHOLE_KEY = re.compile(r"rlo?_[A-Za-z0-9]+\Z")
_WHOLE_HEX = re.compile(r"[a-f0-9]{24}\Z")
_COOKIE = re.compile(r"^([^=;]+)=([^;]*)")


def load() -> dict[str, Any]:
    return json.loads(FILE.read_text(encoding="utf-8"))


def scrub(text: str) -> str:
    """Random parts inside a longer string: secrets in a query, and long runs of hex such as ids and signatures."""
    text = _QUERY_SECRET.sub(r"\1<value>", text)
    text = _HEX_RUN.sub("<hex>", text)
    return _KEY_RUN.sub("<key>", text)


def normalize(value: Any, key: str = "") -> Any:
    """Ids and other random values become "<key>", so answers compare across runs and implementations."""
    if isinstance(value, list):
        return [normalize(v, key) for v in value]
    if isinstance(value, dict):
        return {k: normalize(v, k) for k, v in value.items()}
    if isinstance(value, str):
        if key in RANDOM or _WHOLE_KEY.match(value) or _WHOLE_HEX.match(value):
            return f"<{key or 'value'}>"
        return scrub(value)
    return value


def cookie_shape(header: str) -> str:
    """A Set-Cookie header with its value as <value>, unless it clears the cookie."""
    return _COOKIE.sub(lambda m: f"{m.group(1)}={'<value>' if m.group(2) else ''}", header, count=1)


def dig(value: Any, path: str) -> Any:
    """`path.split(".").reduce((v, k) => (v && typeof v === "object" ? v[k] : undefined), value)`."""
    for k in path.split("."):
        if isinstance(value, dict):
            value = value.get(k)
        elif isinstance(value, list):
            value = value[int(k)] if k.isdigit() and int(k) < len(value) else None
        else:
            return None
    return value


def js_string(value: Any) -> str:
    """`String(value ?? "")`."""
    if value is None:
        return ""
    if isinstance(value, list):
        return ",".join(js_string(v) for v in value)
    if isinstance(value, dict):
        return "[object Object]"
    return _js.string(value)


def unzip(data: bytes) -> list[dict[str, str]]:
    """The files in a ZIP, stored or deflated, by their local headers."""
    files = []
    at = 0
    while at + 30 <= len(data) and int.from_bytes(data[at : at + 4], "little") == 0x04034B50:
        method = int.from_bytes(data[at + 8 : at + 10], "little")
        size = int.from_bytes(data[at + 18 : at + 22], "little")
        name_length = int.from_bytes(data[at + 26 : at + 28], "little")
        extra = int.from_bytes(data[at + 28 : at + 30], "little")
        name = _js.utf8(data[at + 30 : at + 30 + name_length])
        start = at + 30 + name_length + extra
        body = data[start : start + size]
        if method == 8:
            body = zlib.decompress(body, -15)
        files.append({"name": name, "text": _js.utf8(body)})
        at = start + size
    return files


def sent_body(text: str, content_type: str) -> Any:
    """A body another server was sent, as JSON or form fields when it is one of those, else its text."""
    if content_type.startswith("application/x-www-form-urlencoded"):
        return dict(SearchParams(text).items())
    ok, value = _js.try_loads(text)
    return value if ok else text


class UpstreamFetcher:
    """The servers a scenario stands in for, as the fake fetch in http-conformance.ts plays them: a request goes to
    the first upstream whose url its URL starts with (and whose method matches, when one is given); a request
    none matches fails as a network error does. Every request is recorded, matched or not."""

    def __init__(self, upstream: list[dict[str, Any]]) -> None:
        self.upstream = upstream
        self.fetched: list[dict[str, Any]] = []

    def fetch(self, url: str, init: dict[str, Any] | None = None) -> Response:
        init = init or {}
        method = str(init.get("method") or "GET").upper()
        given = dict(sorted(Headers(init.get("headers")).items(), key=lambda kv: _js.order_key(kv[0])))
        raw = init.get("body")
        text = _js.utf8(raw) if isinstance(raw, bytes) else str(raw or "")
        seen: dict[str, Any] = {"method": method, "url": url}
        if given:
            seen["headers"] = given
        if text:
            seen["body"] = sent_body(text, given.get("content-type", ""))
        self.fetched.append({"seen": seen, "text": text})
        match = next(
            (u for u in self.upstream if url.startswith(u["url"]) and (not u.get("method") or u["method"] == method)),
            None,
        )
        if match is None:
            raise FetchError("fetch failed")
        has_body = "body" in match
        body = "" if not has_body else (match["body"] if isinstance(match["body"], str) else _js.dumps(match["body"]))
        # typeof null is "object" too, so a null body is sent as JSON.
        headers = (
            {"content-type": "application/json"}
            if has_body and (match["body"] is None or isinstance(match["body"], (dict, list)))
            else {}
        )
        for name, value in (match.get("headers") or {}).items():
            headers[name] = str(value)
        # The cap a real Fetcher keeps, so code that reads only the start of a page sees what it would.
        data = body.encode("utf-8")
        max_bytes = init.get("maxBytes")
        if max_bytes is not None and len(data) > int(max_bytes):
            if not init.get("truncate"):
                raise BodyTooLong(f"Body over {max_bytes} bytes")
            data = data[: int(max_bytes)]
        return Response(data, int(match.get("status") or 200), headers)

    def take(self) -> list[dict[str, Any]]:
        out = self.fetched
        self.fetched = []
        return out


def runlight_options(scenario: dict[str, Any]) -> dict[str, Any]:
    """The options Runlight gets, without the store, the clock, and the fetcher."""
    options = scenario.get("options") or {}
    out: dict[str, Any] = {}
    if options.get("managedSites"):
        out["managedSites"] = True
    elif scenario.get("sites"):
        out["sites"] = scenario["sites"]
    else:
        out["site"] = scenario["site"]
    if options.get("secret"):
        out["secret"] = options["secret"]
    if "rateLimit" in options:
        out["rateLimit"] = options["rateLimit"]
    return out


def routes_options(scenario: dict[str, Any]) -> dict[str, Any]:
    """The options routes() gets. The token is always there: a string, "" for none, or None to leave the routes
    open, never left out, which would read RUNLIGHT_TOKEN."""
    options = scenario.get("options") or {}
    out: dict[str, Any] = {
        "token": scenario["token"],
        "observeKey": options.get("observeKey", ""),
        "cronSecret": options.get("cronSecret", ""),
    }
    if options.get("accounts"):
        out["accounts"] = True
    if options.get("origin"):
        out["origin"] = options["origin"]
    return out


class CoreTarget:
    """The core, through its public API."""

    def __init__(self, runlight: dict[str, Any], routes: dict[str, Any]) -> None:
        from runlight import Runlight

        self.rl = Runlight(runlight)
        self.routes = self.rl.routes(routes)
        self._links = self.rl.link_handler()

    def handle(self, request: Request) -> Response:
        return self.routes.handle(request)

    def links(self, request: Request) -> Response:
        return self._links(request)

    def link_domain(self, request: Request) -> Response | None:
        return self.rl.link_domain_response(request)

    def idle(self) -> None:
        self.rl.idle()


class Player:
    def __init__(self) -> None:
        # The clock, in epoch milliseconds, as the scenario's steps move it.
        self.now = 0

    def play(self, scenario: dict[str, Any], make_target: Callable[[dict, dict], Any], store: Any = None) -> list[dict[str, Any]]:
        saved = {name: os.environ.pop(name, None) for name in ENV}
        try:
            fetcher = UpstreamFetcher(scenario.get("upstream") or [])
            self.now = int(scenario["start"])
            options = {**({} if store is None else {"store": store}), **runlight_options(scenario)}
            options["now"] = lambda: self.now
            options["fetcher"] = fetcher
            target = make_target(options, routes_options(scenario))
            kept: dict[str, str] = {}
            jars: dict[str, dict[str, str]] = {}
            answers = []
            for i, step in enumerate(scenario["steps"]):
                try:
                    answers.append(self._step(step, target, fetcher, kept, jars))
                except Exception as error:
                    raise RuntimeError(
                        f"{scenario['name']}: step {i + 1}, {step['method']} {step['path']}: {error!r}"
                    ) from error
            return answers
        finally:
            for name, value in saved.items():
                if value is not None:
                    os.environ[name] = value

    def _step(self, step: dict, target: Any, fetcher: UpstreamFetcher, kept: dict, jars: dict) -> dict[str, Any]:
        self.now += int(step.get("advance") or 0)
        headers = {str(k).lower(): self._fill_totp(str(v), kept) for k, v in (step.get("headers") or {}).items()}
        body = None
        if "form" in step:
            fields = self._fill_deep(step["form"], kept)
            body = SearchParams({str(k): str(v) for k, v in fields.items()}).to_string()
            headers.setdefault("content-type", "application/x-www-form-urlencoded")
        elif "body" in step:
            body = (
                self._fill_totp(step["body"], kept)
                if isinstance(step["body"], str)
                else _js.dumps(self._fill_deep(step["body"], kept))
            )
        # JavaScript's Request gives a string body this type when none is named, and the core may read it.
        if body is not None:
            headers.setdefault("content-type", TEXT_BODY_TYPE)
        jar_name = step.get("jar", "main")
        jar = None
        if jar_name is not False:
            jar = jars.setdefault(str(jar_name), {})
        if jar and "cookie" not in headers:
            headers["cookie"] = "; ".join(f"{k}={v}" for k, v in jar.items())
        to = step.get("to", "routes")
        prefix = "/runlight" if to == "routes" and not step.get("absolute") else ""
        raw = f"https://{step.get('host', 'example.com')}{prefix}{self._fill_totp(step['path'], kept)}"
        # request.url is the parsed URL, as `new Request(url)` gives it.
        parsed = Url.parse(raw)
        request = Request(parsed.href if parsed else raw, step["method"], headers, body)
        fetcher.take()
        if to == "links":
            answer = target.links(request)
        elif to == "linkDomain":
            answer = target.link_domain(request)
        else:
            answer = target.handle(request)
        # Work the request started after answering (retention) finishes before the next one.
        target.idle()
        sent_out = fetcher.take()
        outbound = [normalize(f["seen"]) for f in sent_out]
        if answer is None:
            out: dict[str, Any] = {"pass": True}
            if outbound:
                out["fetched"] = outbound
            return out
        return self._answer(step, answer, sent_out, outbound, kept, jar)

    def _answer(self, step: dict, answer: Response, sent_out: list, outbound: list, kept: dict, jar: dict | None) -> dict:
        data = answer.content()
        text = _js.utf8(data)
        media = (answer.headers.get("content-type") or "").split(";")[0].strip()
        parsed: Any = None
        has_parsed = False
        if media != "application/zip" and text:
            has_parsed, parsed = _js.try_loads(text)
        for name, spec in (step.get("capture") or {}).items():
            kept[name] = capture(spec, answer, text, parsed if has_parsed else None, sent_out)
        for cookie in answer.headers.get_set_cookie():
            if jar is None:
                continue
            pair, *attributes = cookie.split(";")
            at = pair.find("=")
            # As pair.slice(0, pair.indexOf("=")): with no "=", indexOf is -1, and the last character is cut.
            name = _js.trim(pair[:-1] if at == -1 else pair[:at])
            value = _js.trim(pair if at == -1 else pair[at + 1 :])
            clears = any(re.match(f"^[{_S}]*max-age=0[{_S}]*\\Z", a, re.I) for a in attributes)
            if not value or clears:
                jar.pop(name, None)
            else:
                jar[name] = value
        sent: dict[str, Any] = {}
        for name in HEADERS:
            if name == "set-cookie":
                cookies = answer.headers.get_set_cookie()
                if cookies:
                    sent[name] = [cookie_shape(c) for c in cookies]
                continue
            value = answer.headers.get(name)
            if value:
                sent[name] = value.split(";")[0].strip() if name == "content-type" else normalize(value)
        out: dict[str, Any] = {"status": answer.status}
        if sent:
            out["headers"] = sent
        if has_parsed:
            out["body"] = normalize(parsed)
        if not has_parsed and media in ("text/plain", "text/csv"):
            out["text"] = normalize(text)
        if media == "application/zip":
            out["files"] = [{"name": f["name"], "text": normalize(f["text"])} for f in unzip(data)]
        if "look" in step:
            out["found"] = [s in text for s in step["look"]]
        if outbound:
            out["fetched"] = outbound
        return out

    def _fill_totp(self, text: str, kept: dict) -> str:
        """{{totp:name}} as the six-digit code for the captured secret at the step's clock, then {{name}}."""
        out = text
        for m in re.finditer(r"\{\{totp:(\w+)\}\}", text):
            from runlight.accounts.auth import totp

            out = out.replace(m.group(0), totp(kept.get(m.group(1), ""), self.now // 30_000), 1)
        return re.sub(r"\{\{(\w+)\}\}", lambda m: kept.get(m.group(1), ""), out)

    def _fill_deep(self, value: Any, kept: dict) -> Any:
        if isinstance(value, str):
            return self._fill_totp(value, kept)
        if isinstance(value, list):
            return [self._fill_deep(v, kept) for v in value]
        if isinstance(value, dict):
            return {k: self._fill_deep(v, kept) for k, v in value.items()}
        return value


def capture(spec: str, answer: Response, text: str, parsed: Any, sent_out: list) -> str:
    """A value kept from an answer: a dotted path into its JSON body, header:<name>, text, or fetched, any of them
    followed by ~<regex> to keep the regex's first group instead. Read before normalizing."""
    cut = spec.find("~")
    source = spec if cut == -1 else spec[:cut]
    pattern = None if cut == -1 else spec[cut + 1 :]
    if source == "text":
        value = text
    elif source == "fetched":
        value = "\n".join(f["text"] for f in sent_out)
    elif source.startswith("header:"):
        header = source[len("header:") :].lower()
        value = "\n".join(answer.headers.get_set_cookie()) if header == "set-cookie" else (answer.headers.get(header) or "")
    else:
        value = js_string(dig(parsed, source))
    if pattern is None:
        return value
    m = re.search(pattern, value)
    return (m.group(1) or "") if m else ""
