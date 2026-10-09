"""The port of the Node server's agents.test.ts (PHP tests/Server/AgentsTest.php): the access log reader that
counts AI agents. The command line's own case lives with the command line."""

from __future__ import annotations

import calendar
import math
import os
import subprocess
import sys
from typing import Any

import pytest
from support import fixtures
from support.fake_fetcher import FakeFetcher

from runlight import _js
from runlight.http import FetchError, Request, Response
from runlight.server.agents import agent_fetch, parse_line, run_agents

GPTBOT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"
CLAUDE = "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"


def line(path: str, ua: str, status: int = 200, method: str = "GET", time: str = "07/Oct/2026:13:55:36 -0400", vhost: str = "") -> str:
    return (f"{vhost} " if vhost else "") + f'203.0.113.9 - - [{time}] "{method} {path} HTTP/1.1" {status} 5120 "-" "{ua}"'


def utc(y: int, m: int, d: int, h: int = 0, i: int = 0, s: int = 0) -> int:
    return calendar.timegm((y, m, d, h, i, s)) * 1000


def quiet(_: str) -> None:
    pass


def runlight() -> tuple[Any, FakeFetcher]:
    """A Runlight that takes reports for example.com with the key rlo_site, and a Fetcher that reaches its routes."""
    from runlight import Runlight
    from runlight.store import Stores

    now = utc(2026, 10, 7, 18)
    rl = Runlight({"store": Stores.sqlite(":memory:"), "site": {"hostnames": ["example.com"]}, "now": lambda: now})
    rl.init()
    rl.store.set_setting("observe-key:default", "rlo_site")
    routes = rl.routes({"token": "owner"})
    fetcher = FakeFetcher(lambda url, init: routes.handle(Request(url, init.get("method", "GET"), init.get("headers") or {}, init.get("body") or "")))
    return rl, fetcher


def counter(tally: dict[str, int], answer: Any = None) -> FakeFetcher:
    """A Fetcher like a small server that keeps each batch, answering with how many it took. `answer` gives an
    answer of its own for a post, from its number and size."""

    def reply(url: str, init: dict[str, Any]) -> Response:
        tally["posts"] += 1
        n = len(_js.loads(init["body"])["fetches"])
        own = answer(tally["posts"], n) if answer else None
        if own is not None:
            return own
        tally["stored"] += n
        return Response.json({"recorded": n})

    return FakeFetcher(reply)


def files(dir: Any) -> list[str]:
    return sorted(os.listdir(dir))


def test_log_lines_nginx_and_apache_combined_a_vhost_column_and_caddys_json() -> None:
    assert parse_line(line("/blog/post?x=1", GPTBOT), "https://example.com") == {
        "method": "GET", "url": "https://example.com/blog/post?x=1", "status": 200, "userAgent": GPTBOT, "at": utc(2026, 10, 7, 17, 55, 36),
    }  # fmt: skip
    assert parse_line(line("/", GPTBOT)) is None, "with no host anywhere there is no page to name"
    assert parse_line(line("/", GPTBOT, vhost="blog.example.com:443"))["url"] == "https://blog.example.com/"
    caddy = _js.dumps({"ts": 1791399336.5, "status": 200, "request": {"method": "GET", "host": "example.com", "uri": "/docs/", "tls": {}, "headers": {"User-Agent": [CLAUDE]}}})
    assert parse_line(caddy) == {"method": "GET", "url": "https://example.com/docs/", "status": 200, "userAgent": CLAUDE, "at": 1791399336500}
    assert parse_line("not a log line") is None
    # A target is a path and query on the site, never read as an address: a backslash cannot name another host.
    assert parse_line(line("/\\evil.example/x?y=1", GPTBOT), "https://example.com")["url"] == "https://example.com//evil.example/x?y=1"
    assert parse_line(line("//evil.example/x", GPTBOT), "https://example.com")["url"] == "https://example.com/evil.example/x"

    # Only successful GETs from AI agents are worth sending.
    assert agent_fetch(line("/", GPTBOT), "https://example.com") is not None
    assert agent_fetch(line("/", CHROME), "https://example.com") is None, "people are the tracker's job"
    assert agent_fetch(line("/", GPTBOT, 404), "https://example.com") is None
    assert agent_fetch(line("/", GPTBOT, 200, "POST"), "https://example.com") is None


def test_lines_are_read_as_the_node_command_reads_them() -> None:
    fixture = fixtures.load("agents")
    for case in fixture["cases"]:
        parsed = parse_line(case["line"], case.get("site"))
        if parsed is not None and isinstance(parsed["at"], float) and math.isnan(parsed["at"]):
            parsed["at"] = "NaN"
        label = fixtures.label(case)
        assert _js.dumps(parsed) == _js.dumps(case["parsed"]), label
        assert _js.dumps(agent_fetch(case["line"], case.get("site"), lambda: fixture["now"])) == _js.dumps(case["fetched"]), label


def test_a_log_is_read_once_carries_on_where_it_stopped_and_starts_over_after_rotation(tmp_path: Any) -> None:
    rl, fetcher = runlight()
    to = "http://127.0.0.1:9/runlight"
    log = str(tmp_path / "access.log")
    state = str(tmp_path / "state.json")

    def fetches() -> list[dict[str, Any]]:
        return rl.store.db.all("SELECT path, name, ts FROM rl_events WHERE kind = 'fetch' ORDER BY ts, path")

    def run() -> Any:
        return run_agents({"log": log, "to": to, "key": "rlo_site", "site": "https://example.com", "state": state, "fetcher": fetcher, "out": quiet})

    with open(log, "w") as f:
        f.write("\n".join([line("/a", GPTBOT), line("/b", CHROME), line("/c", CLAUDE, 200, "GET", "07/Oct/2026:13:56:00 -0400"), line("/style.css", GPTBOT), ""]))
    assert run() == 2, "two pages count; the stylesheet and the person do not"
    first = fetches()
    assert [[f["path"], f["name"]] for f in first] == [["/a", "GPTBot"], ["/c", "ClaudeBot"]], "Runlight keeps pages, not their assets"
    assert int(first[0]["ts"]) == utc(2026, 10, 7, 17, 55, 36), "counted when the page was served"
    assert fetcher.requests[0]["headers"]["authorization"] == "Bearer rlo_site"
    assert fetcher.requests[0]["url"] == "http://127.0.0.1:9/runlight/api/observe"

    assert run() == 0, "nothing new, nothing sent"
    with open(log, "a") as f:
        f.write(line("/d", GPTBOT) + "\n")
    assert run() == 1

    os.rename(log, f"{log}.1")
    with open(log, "w") as f:
        f.write(line("/e", CLAUDE) + "\n")
    assert run() == 1, "a rotated log is read from the top"
    assert sorted(f["path"] for f in fetches()) == ["/a", "/c", "/d", "/e"]
    os.unlink(f"{log}.1")

    with pytest.raises(RuntimeError, match="refused the key"):
        run_agents({"log": log, "to": to, "key": "rlo_wrong", "site": "https://example.com", "fetcher": fetcher, "out": quiet})

    # Lines for another host, a // path, an absolute target, an old line, and a bad byte: none stops the rest.
    before = len(fetches())
    with open(log, "wb") as f:
        f.write(
            (
                line("/f", GPTBOT, 200, "GET", "07/Oct/2026:13:57:00 -0400", "other.example:443") + "\n"
                + line("//g", GPTBOT) + "\n"
                + line("http://evil.example/h", GPTBOT) + "\n"
                + line("/old", GPTBOT, 200, "GET", "01/Sep/2026:10:00:00 -0400") + "\n"
            ).encode()
            + b"\xff\xfe\n"
            + (line("/i", CLAUDE) + "\n").encode()
        )  # fmt: skip
    assert run() == 2, "/g and /i count; the other host, the absolute target, and the old line do not"
    paths = [f["path"] for f in fetches()]
    assert len(paths) == before + 2
    assert "/g" in paths and "/i" in paths
    assert "/f" not in paths and "/h" not in paths and "/old" not in paths
    assert run() == 0, "the offset after a bad byte lands on the next line, so nothing is sent twice"

    # Rotated by copying and truncating: the same file, a new start, already longer than the old place.
    with open(log, "w") as f:
        f.write(line("/one", GPTBOT) + "\n")
    assert run() == 1
    with open(log, "w") as f:
        f.write(line("/two", CLAUDE) + "\n" + line("/three", GPTBOT) + "\n")
    assert run() == 2, "both lines of the new log, none skipped"


def test_following_a_log_reads_what_was_written_just_before_a_rotation_then_the_new_log(tmp_path: Any) -> None:
    rl, fetcher = runlight()
    log = str(tmp_path / "access.log")
    open(log, "w").close()
    polls = [0]

    # Each look at the log waits first; the steps run in that wait, as another process writing the log would.
    def sleep(_: int) -> None:
        polls[0] += 1
        if polls[0] == 2:
            with open(log, "a") as f:
                f.write(line("/before", GPTBOT) + "\n")
            # Rotated before the reader looks again: the last line is in the renamed file only.
            with open(log, "a") as f:
                f.write(line("/last-old", CLAUDE) + "\n")
            os.rename(log, f"{log}.1")
            with open(log, "w") as f:
                f.write(line("/new", GPTBOT) + "\n")

    said: list[str] = []
    run_agents(
        {
            "log": log, "to": "http://127.0.0.1:9/runlight", "key": "rlo_site", "site": "https://example.com", "follow": True, "fetcher": fetcher,
            "sleep": sleep, "stop": lambda: polls[0] >= 6, "out": said.append,
        }
    )  # fmt: skip
    paths = [r["path"] for r in rl.store.db.all("SELECT path FROM rl_events WHERE kind = 'fetch' ORDER BY path")]
    assert paths == ["/before", "/last-old", "/new"]
    assert said[0] == f"Following {log}. AI agent fetches go to http://127.0.0.1:9/runlight as they happen."
    assert said[1:] == ["Sent 2 AI agent fetches.", "Sent 1 AI agent fetches."]


def test_a_failed_batch_sends_none_of_the_earlier_ones_again_and_a_bad_state_file_starts_over_with_a_word(tmp_path: Any) -> None:
    tally = {"stored": 0, "posts": 0}
    fail_at = [0]
    fetcher = counter(tally, lambda post, n: Response("busy", 503) if post == fail_at[0] else None)
    log = str(tmp_path / "access.log")
    state = str(tmp_path / "state.json")
    with open(log, "w") as f:
        f.write("".join(line(f"/p{i}", GPTBOT) + "\n" for i in range(1200)))
    fail_at[0] = 2
    options = {"log": log, "to": "http://127.0.0.1:9", "key": "k", "site": "https://example.com", "state": state, "fetcher": fetcher, "out": quiet}
    with pytest.raises(RuntimeError) as caught:
        run_agents(options)
    assert str(caught.value) == "Runlight answered 503: busy"
    assert tally["stored"] == 500, "the first batch went"
    run_agents(options)
    assert tally["stored"] == 1200, "each line once"

    with open(state, "w") as f:
        f.write("{ not json")
    said: list[str] = []
    tally["stored"] = 0
    run_agents({**options, "out": said.append})
    assert said[0].startswith("Could not read ") and "state.json" in said[0]
    assert said[1] == "Sent 1200 AI agent fetches from 1200 new lines."
    assert tally["stored"] == 1200, "read from the top"
    with open(state) as f:
        assert _js.loads(f.read())["offset"] == os.path.getsize(log)


def test_lines_with_no_host_and_no_site_are_mentioned_once(tmp_path: Any) -> None:
    tally = {"stored": 0, "posts": 0}
    log = str(tmp_path / "access.log")
    with open(log, "w") as f:
        f.write(line("/a", GPTBOT) + "\n" + line("/b", GPTBOT) + "\n")
    said: list[str] = []
    sent = run_agents({"log": log, "to": "http://127.0.0.1:9", "key": "k", "fetcher": counter(tally), "out": said.append})
    assert sent == 0
    assert said == ["Some lines have no host in them. Add --site https://your-site.example so they can be counted.", "Sent 0 AI agent fetches from 2 new lines."]
    assert tally["posts"] == 0


def test_one_run_at_a_time_uses_a_state_file_a_crashed_runs_lock_is_taken_over_and_the_state_is_written_whole(tmp_path: Any) -> None:
    tally = {"stored": 0, "posts": 0}
    log = str(tmp_path / "access.log")
    state = str(tmp_path / "state.json")
    second: list[str] = []

    # While the first run sends its first batch, a second one starts on the same state file.
    def during(post: int, n: int) -> None:
        if post == 1:
            try:
                run()
                second.append("ran")
            except RuntimeError as error:
                second.append(str(error))

    fetcher = counter(tally, during)

    def run() -> Any:
        return run_agents({"log": log, "to": "http://127.0.0.1:9", "key": "k", "site": "https://example.com", "state": state, "fetcher": fetcher, "out": quiet})

    with open(log, "w") as f:
        f.write("".join(line(f"/p{i}", GPTBOT) + "\n" for i in range(1500)))
    assert run() == 1500
    assert len(second) == 1
    assert second[0].startswith("Another run is using ") and "state.json (process " in second[0]
    assert second[0].endswith("state.json.lock if none is running.")
    assert tally["stored"] == 1500, "each line once"
    assert files(tmp_path) == ["access.log", "state.json"], "the lock is released and no temporary file is left"

    # A lock from a process that has ended is stale.
    child = subprocess.Popen([sys.executable, "-c", ""])
    child.wait()
    with open(f"{state}.lock", "w") as f:
        f.write(str(child.pid))
    with open(log, "a") as f:
        f.write(line("/late", GPTBOT) + "\n")
    assert run() == 1
    assert tally["stored"] == 1501
    assert files(tmp_path) == ["access.log", "state.json"]

    # A lock held by a running process is left alone.
    with open(f"{state}.lock", "w") as f:
        f.write(str(os.getpid()))
    with pytest.raises(RuntimeError, match=f"\\(process {os.getpid()}\\)"):
        run()
    with open(f"{state}.lock") as f:
        assert f.read() == str(os.getpid())
    os.unlink(f"{state}.lock")


@pytest.mark.skipif(hasattr(os, "getuid") and os.getuid() == 0, reason="root reads every file")
def test_following_a_log_that_cannot_be_read_waits_and_says_so_and_a_restart_reads_a_log_rotated_meanwhile_from_its_start(tmp_path: Any) -> None:
    tally = {"stored": 0, "posts": 0}
    fetcher = counter(tally)
    log = str(tmp_path / "access.log")
    state = str(tmp_path / "state.json")
    open(log, "w").close()
    polls = [0]

    def append(path: str) -> None:
        with open(log, "a") as f:
            f.write(line(path, GPTBOT) + "\n")

    def unlock() -> None:
        os.chmod(log, 0o644)
        append("/b")

    steps = {2: lambda: append("/a"), 4: lambda: os.chmod(log, 0), 8: unlock}

    def sleep(_: int) -> None:
        polls[0] += 1
        if polls[0] in steps:
            steps[polls[0]]()

    said: list[str] = []
    options = {"log": log, "to": "http://127.0.0.1:9", "key": "k", "site": "https://example.com", "state": state, "follow": True, "fetcher": fetcher}
    run_agents({**options, "sleep": sleep, "stop": lambda: polls[0] >= 10, "out": said.append})
    assert tally["stored"] == 2, "it carried on once the log could be read again"
    assert len([s for s in said if s.startswith("Could not read")]) == 1, "said once, not every poll"
    assert len([s for s in said if s.startswith("Could not send")]) == 0

    # Stopped, then the log was rotated: everything in the new log is unread.
    os.rename(log, f"{log}.1")
    with open(log, "w") as f:
        f.write(line("/c", GPTBOT) + "\n" + line("/d", GPTBOT) + "\n")
    polls[0] = 0

    def count(_: int) -> None:
        polls[0] += 1

    run_agents({**options, "sleep": count, "stop": lambda: polls[0] >= 3, "out": quiet})
    assert tally["stored"] == 4
    assert files(tmp_path) == ["access.log", "access.log.1", "state.json"]


def test_a_send_that_cannot_reach_runlight_is_tried_again_on_the_next_look(tmp_path: Any) -> None:
    tally = {"stored": 0, "posts": 0}

    def refuse(post: int, n: int) -> None:
        if post <= 2:
            raise FetchError("Could not connect")

    fetcher = counter(tally, refuse)
    log = str(tmp_path / "access.log")
    open(log, "w").close()
    polls = [0]

    def sleep(_: int) -> None:
        polls[0] += 1
        if polls[0] == 1:
            with open(log, "w") as f:
                f.write(line("/a", GPTBOT) + "\n")

    said: list[str] = []
    run_agents(
        {
            "log": log, "to": "http://127.0.0.1:9", "key": "k", "site": "https://example.com", "follow": True, "fetcher": fetcher,
            "sleep": sleep, "stop": lambda: polls[0] >= 4, "out": said.append,
        }
    )  # fmt: skip
    assert tally["stored"] == 1
    assert said[1:] == ["Could not send, trying again shortly: Could not connect", "Sent 1 AI agent fetches."]
