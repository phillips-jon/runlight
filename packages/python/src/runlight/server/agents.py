"""runlight agents: counts AI agents on a site that has only the script tag, by
reading its web server's access log. Agents do not run JavaScript, so the
tracker never sees them; the server that answered them did.

It reads nginx and Apache's combined format and Caddy's JSON lines, keeps
successful GETs from known AI agents, and sends them in batches to a
Runlight's /api/observe with the site's observe key. Nothing else in the log
leaves the machine. With follow it keeps reading as the log grows and
carries on after the log is rotated. Without it, it reads what is new and
stops, for cron. In both modes the state file remembers how far it read, so the
next run, or a restarted follow, carries on from there.

The port of the Node server's agents.ts. A fetch is a dict of url, userAgent, and at (epoch milliseconds).
"""

from __future__ import annotations

import atexit
import hashlib
import math
import os
import re
import time
from collections.abc import Callable
from typing import Any, BinaryIO

from .. import _js
from ..http import Fetcher, Url, UrllibFetcher
from ..importers.http import parse_date
from ..ua import ai_agent

_MONTHS = {"Jan": 0, "Feb": 1, "Mar": 2, "Apr": 3, "May": 4, "Jun": 5, "Jul": 6, "Aug": 7, "Sep": 8, "Oct": 9, "Nov": 10, "Dec": 11}

# JavaScript's \S, which also leaves out Unicode spaces, and its ".", which leaves out line terminators.
_S = f"[^{_js.WHITESPACE}]"
_ANY = "[^\\n\\r\\u2028\\u2029]"

# host? ip - user [time] "METHOD /path HTTP/x" status bytes "referrer" "user agent"
_COMBINED = re.compile(
    f'^(?:({_S}+) )?{_S}+ {_S}+ {_S}+ \\[([^\\]]+)\\] "({_S}+) ({_S}+)[^"]*" ([0-9]{{3}}) {_S}+ "(?:[^"\\\\]|\\\\{_ANY})*" "((?:[^"\\\\]|\\\\{_ANY})*)"'
)
# A request line and status, in a line that might be a combined log line without its host.
_REQUEST = re.compile(f'"{_S}+ /{_S}* [^"]*" [0-9]{{3}}')
_LOG_TIME = re.compile(r"(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})\Z", re.ASCII)

# The most fetches /api/observe takes at once.
BATCH = 500

# The most of a log read at once, so a log of any size fits in memory a piece at a time.
CHUNK = 32 * 1024 * 1024

# How many bytes at the start of a log identify it.
HEAD = 256


class SendError(RuntimeError):
    """A failure to reach Runlight or have it take a batch, told apart from a failure to read the log."""


def _page_url(target: str, base: str) -> str | None:
    """A request target as a page on the site. Absolute targets ("GET http://other/x", a proxy
    request) name somewhere else and are skipped. The target is set as the path and query of the
    site's own address, never parsed as a URL, so "//x" and "/\\x" stay paths on the site."""
    if not target.startswith("/"):
        return None
    url = Url.parse(base)
    if url is None:
        return None
    query = target.find("?")
    url.set_pathname("/" + (target if query < 0 else target[:query]).lstrip("/"))
    url.set_search("" if query < 0 else target[query:])
    url.set_hash("")
    return url.href


def _days_from_civil(y: int, m: int, d: int) -> int:
    y -= 1 if m <= 2 else 0
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _log_time(value: str) -> int | float:
    """"07/Oct/2026:13:55:36 -0400" as epoch milliseconds, or NaN."""
    m = _LOG_TIME.match(value)
    if not m or m.group(2) not in _MONTHS:
        return math.nan
    # Date.UTC reads years 0 to 99 as 1900 to 1999, and lets days and hours run on past their end.
    year = int(m.group(3))
    year += 1900 if year <= 99 else 0
    days = _days_from_civil(year, _MONTHS[m.group(2)] + 1, 1) + int(m.group(1)) - 1
    local = (((days * 24 + int(m.group(4))) * 60 + int(m.group(5))) * 60 + int(m.group(6))) * 1000
    offset = (int(m.group(8)) * 60 + int(m.group(9))) * 60_000 * (-1 if m.group(7) == "-" else 1)
    return local - offset


def _at(value: Any, key: str | int) -> Any:
    """value?.[key], for a value that may be null or undefined."""
    if value is None or value is _js.UNDEFINED:
        return _js.UNDEFINED
    if isinstance(value, str) and isinstance(key, int):
        # A string's characters are its indexes.
        return _js.slice16(value, key, key + 1) if 0 <= key < _js.length(value) else _js.UNDEFINED
    return _js.get(value, key)


def _either(value: Any, otherwise: Any) -> Any:
    """value ?? otherwise"""
    return otherwise if value is None or value is _js.UNDEFINED else value


def parse_line(line: str, site: str | None = None) -> dict[str, Any] | None:
    """One log line as a page fetch {method, url, status, userAgent, at}, or None. `site` is the address pages
    live at (https://example.com), for formats that do not record the host."""
    text = _js.trim(line)
    if not text:
        return None
    if text.startswith("{"):
        # Caddy: {"ts": 1696..., "request": {"method", "host", "uri", "headers": {"User-Agent": [...]}}, "status": 200}
        try:
            entry = _js.loads(text)
            request = _at(entry, "request")
            uri = _at(request, "uri")
            method = _at(request, "method")
            if not _js.truthy(uri) or not _js.truthy(method):
                return None
            host_name = _at(request, "host")
            if _js.truthy(host_name):
                scheme = "https" if _js.truthy(_at(request, "tls")) else "http" if site is not None and site.startswith("http://") else "https"
                host = f"{scheme}://{_js.string(host_name)}"
            else:
                host = site
            if not host:
                return None
            headers = _at(request, "headers")
            ua = _either(_at(_at(headers, "User-Agent"), 0), _either(_at(_at(headers, "user-agent"), 0), ""))
            ts = _at(entry, "ts")
            at = _js.whole(ts * 1000) if _js.is_number(ts) else parse_date(_js.string(_either(ts, "")))
            # A target that is not text cannot be a page, as startsWith throws on it in TypeScript.
            if not isinstance(uri, str):
                return None
            url = _page_url(uri, host)
            if url is None:
                return None
            return {"method": method, "url": url, "status": _js.number(_either(_at(entry, "status"), 0)), "userAgent": _js.string(ua), "at": at}
        except (ValueError, TypeError, RecursionError):
            return None
    m = _COMBINED.match(text)
    if not m:
        return None
    # A vhost column first ("example.com:443 1.2.3.4 - - [...]") names the host; otherwise site does.
    first = m.group(1)
    vhost = re.sub(r":[0-9]+\Z", "", first) if first and re.search(r"[a-z]", first, re.I) and not re.match(r"[0-9.:]+\Z", first) else None
    base = f"https://{vhost}" if vhost is not None else site
    if not base:
        return None
    url = _page_url(m.group(4), base)
    if url is None:
        return None
    return {"method": m.group(3), "url": url, "status": int(m.group(5)), "userAgent": m.group(6).replace('\\"', '"'), "at": _log_time(m.group(2))}


def _clock() -> int:
    return time.time_ns() // 1_000_000


def agent_fetch(line: str, site: str | None = None, now: Callable[[], int] | None = None) -> dict[str, Any] | None:
    """The lines worth sending: GETs that succeeded, from known AI agents. `now` gives epoch milliseconds, for a
    line whose time cannot be read."""
    hit = parse_line(line, site)
    if hit is None or hit["method"] != "GET" or hit["status"] < 200 or hit["status"] >= 400 or ai_agent(hit["userAgent"]) is None:
        return None
    return {"url": hit["url"], "userAgent": hit["userAgent"], "at": hit["at"] if _js.is_finite(hit["at"]) else (now or _clock)()}


def _send(options: dict[str, Any], fetcher: Fetcher, fetches: list[dict[str, Any]]) -> int | float:
    """Sends one batch of fetches to /api/observe and returns how many Runlight kept."""
    try:
        answer = fetcher.fetch(
            re.sub(r"/+\Z", "", options["to"]) + "/api/observe",
            {
                "method": "POST",
                "headers": {"authorization": f"Bearer {options['key']}", "content-type": "application/json"},
                "body": _js.dumps({"fetches": fetches}),
                "timeoutMs": 30_000,
            },
        )
    except Exception as error:
        raise SendError(str(error)) from error
    if answer.status == 401:
        raise SendError("Runlight refused the key. Use the site's key from Settings, Install, Key for CMS plugins.")
    if not answer.ok:
        raise SendError(f"Runlight answered {answer.status}: {_js.slice16(answer.text(), 0, 200)}")
    ok, body = _js.try_loads(answer.content())
    recorded = body.get("recorded") if ok and isinstance(body, dict) else None
    return recorded if _js.is_number(recorded) else 0


def _head_of(file: str | BinaryIO, length: int = HEAD) -> dict[str, Any]:
    """A fingerprint of the log's first bytes. A log rotated by copying and truncating keeps its inode,
    so a different start is how a new log shows itself. An open file (in follow mode) is read as it is,
    even once it is renamed."""
    fd = open(file, "rb") if isinstance(file, str) else file  # noqa: SIM115
    try:
        fd.seek(0)
        buffer = fd.read(min(length, os.fstat(fd.fileno()).st_size))
        return {"head": hashlib.sha256(buffer).hexdigest(), "length": len(buffer)}
    finally:
        if isinstance(file, str):
            fd.close()


def _same_log(file: str, saved: dict[str, Any], stat: os.stat_result) -> bool:
    """Whether the log at this inode still starts the way it did, so a saved place in it still holds."""
    if saved["ino"] != stat.st_ino:
        return False
    if not _js.truthy(saved.get("head")) or saved.get("length", _js.UNDEFINED) is _js.UNDEFINED:
        return True
    length = saved["length"]
    return _js.is_number(length) and stat.st_size >= length and _head_of(file, int(length))["head"] == saved["head"]


def _read_from(file: str | BinaryIO, offset: int) -> dict[str, Any]:
    """Reads whole lines from a byte offset, at most a chunk, and returns where the next read starts.
    Offsets count bytes up to each newline byte, so a malformed character cannot shift them. `ends`
    holds where the line after each one starts, so a place can be saved part way through a chunk."""
    # A path is opened for this read; an open file (in follow mode) stays open, even once it is renamed.
    size = os.stat(file).st_size if isinstance(file, str) else os.fstat(file.fileno()).st_size
    if size <= offset:
        return {"lines": [], "ends": [], "next": offset, "more": False}
    fd = open(file, "rb") if isinstance(file, str) else file  # noqa: SIM115
    try:
        fd.seek(offset)
        buffer = fd.read(min(size - offset, CHUNK))
        end = buffer.rfind(b"\n")
        # A half-written last line waits for the next read (or, in a chunk with no newline at all, is skipped).
        if end < 0:
            if len(buffer) == CHUNK:
                return {"lines": [], "ends": [], "next": offset + len(buffer), "more": True}
            return {"lines": [], "ends": [], "next": offset, "more": False}
        lines = []
        ends = []
        start = 0
        while start <= end:
            newline = buffer.index(b"\n", start)
            # Read as UTF-8 the way Node does, each malformed sequence becoming U+FFFD.
            lines.append(buffer[start:newline].decode("utf-8", "replace"))
            ends.append(offset + newline + 1)
            start = newline + 1
        return {"lines": lines, "ends": ends, "next": offset + end + 1, "more": offset + len(buffer) < size}
    finally:
        if isinstance(file, str):
            fd.close()


def _running(pid: int) -> bool:
    """Whether a process with this id is running on this machine."""
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        # EPERM: it runs, as someone else.
        return True
    except (ProcessLookupError, OverflowError, OSError):
        return False


def _contents(file: str) -> str | None:
    """The text of a file, or None when it cannot be read."""
    try:
        with open(file, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def _lock(state: str) -> Callable[[], None]:
    """Takes the lock beside a state file, so two runs never read from the same place and send the
    same lines twice. The lock holds the run's process id; a lock left by a process that is no longer
    running is taken over. Returns the release."""
    path = f"{state}.lock"
    mine = str(os.getpid())
    for _ in range(3):
        try:
            with open(path, "x", encoding="utf-8") as f:
                f.write(mine)
        except FileExistsError:
            pass
        else:
            released = [False]

            def release() -> None:
                if released[0]:
                    return
                released[0] = True
                if _contents(path) == mine:
                    try:
                        os.unlink(path)
                    except OSError:
                        pass

            # Released on exit too, as a run that stops part way would otherwise leave its lock behind.
            atexit.register(release)

            def done() -> None:
                atexit.unregister(release)
                release()

            return done
        held = _contents(path)
        if held is None:
            continue
        held = _js.trim(held)
        pid = _js.number(held)
        # A lock being written has no id in it yet, so it counts as held.
        if not held or (_js.is_integer(pid) and pid > 0 and _running(int(pid))):
            break
        # Stale. Moving it aside is atomic, so of two runs taking it over only one moves this lock; one
        # that finds a newer lock moved aside puts it back.
        aside = f"{path}.{mine}"
        try:
            os.rename(path, aside)
        except OSError:
            continue
        if _js.trim(_contents(aside) or "") != held:
            try:
                os.link(aside, path)
            except OSError:
                pass
            os.unlink(aside)
            break
        os.unlink(aside)
    holder = _js.trim(_contents(path) or "")
    raise RuntimeError(f"Another run is using {state}{f' (process {holder})' if holder else ''}. Wait for it to finish, or delete {path} if none is running.")


def _write_state(state: str, saved: dict[str, Any]) -> None:
    """Writes the state whole or not at all, so a crash part way never leaves it empty."""
    temp = f"{state}.{os.getpid()}.tmp"
    with open(temp, "w", encoding="utf-8") as f:
        f.write(_js.dumps(saved))
    os.replace(temp, state)


def run_agents(options: dict[str, Any]) -> int | float:
    """Reads the log and sends what AI agents fetched, returning how many fetches Runlight kept.

    Options, as the Node command's:
    - log: the access log's path
    - to: the Runlight to report to, as its dashboard address
    - key: the site's observe key
    - site: the site's address, for logs with no host in them
    - follow: keep reading as the log grows
    - state: where runs remember how far they read, so the next one (or a restarted follow) carries on
    - out: callable(str) for what it has to say, a line at a time; printed by default
    - stop: callable() -> bool that ends follow, which otherwise runs until the process stops
    - pollMs: how often follow looks at the log, 2 seconds by default
    - sleep: callable(ms) that waits between looks
    - fetcher: the Fetcher that reaches Runlight, UrllibFetcher by default
    - now: callable() -> int, epoch milliseconds, for lines whose time cannot be read
    """
    release = _lock(options["state"]) if options.get("state") else (lambda: None)
    try:
        return _read_log(options)
    finally:
        release()


def _read_log(options: dict[str, Any]) -> int | float:
    out: Callable[[str], None] = options.get("out") or print
    fetcher: Fetcher = options.get("fetcher") or UrllibFetcher()
    now = options.get("now") or _clock
    site: str | None = options.get("site") or None
    state: str | None = options.get("state") or None
    log = str(options["log"])
    if not os.path.exists(log):
        raise RuntimeError(f"No log at {log}")
    total: list[int | float] = [0]
    warned = [False]

    def handle(read: dict[str, Any], done: Callable[[int], None]) -> int | float:
        """Sends the agent fetches among lines read, a batch at a time, calling `done` with where the next
        unsent line starts after each batch, so a failure part way sends none of the earlier batches again."""
        lines, ends = read["lines"], read["ends"]
        # Lines with no host and no site cannot be placed on a site; say so once rather than skip them silently.
        if site is None and not warned[0]:
            for line in lines:
                if not _js.trim(line).startswith("{") and _REQUEST.search(line) and parse_line(line) is None:
                    warned[0] = True
                    out("Some lines have no host in them. Add --site https://your-site.example so they can be counted.")
                    break
        kept: int | float = 0
        batch: list[dict[str, Any]] = []
        for i, line in enumerate(lines):
            found = agent_fetch(line, site, now)
            if found is not None:
                batch.append(found)
            if len(batch) == BATCH or (i == len(lines) - 1 and batch):
                recorded = _send(options, fetcher, batch)
                kept += recorded
                total[0] += recorded
                batch = []
                done(ends[i])
        return kept

    def save(ino: int, offset: int, head: dict[str, Any]) -> None:
        """The place to save: the file being read, by its inode and its own start, and how far into it."""
        if state is not None:
            _write_state(state, {"ino": ino, "offset": offset, **head})

    def read_state() -> dict[str, Any] | None:
        """Where the last run stopped, or None with a word about it when the state file cannot be read."""
        if state is None or not os.path.exists(state):
            return None
        ok, saved = _js.try_loads((_contents(state) or "").encode("utf-8"))
        if ok and isinstance(saved, dict) and _js.is_number(saved.get("ino")) and _js.is_number(saved.get("offset")):
            return saved
        out(f"Could not read {state}, so this run starts as if it were the first.")
        return None

    if not options.get("follow"):
        # Where the last run stopped, unless the log was rotated since (a new file, a shorter one, or a new start).
        saved = read_state()
        stat = os.stat(log)
        offset = int(saved["offset"]) if saved is not None and saved["offset"] <= stat.st_size and _same_log(log, saved, stat) else 0
        count = 0
        # A batch at a time, saving the place after each, so a failure part way resends nothing already sent.
        while True:
            read = _read_from(log, offset)
            handle(read, lambda at: save(stat.st_ino, at, _head_of(log)))
            count += len(read["lines"])
            offset = read["next"]
            save(stat.st_ino, offset, _head_of(log))
            if not read["more"]:
                break
        out(f"Sent {_js.number_text(total[0])} AI agent fetches from {count} new lines.")
        return total[0]

    # Follow: start where the state says, else at the end like tail -F. A log that was rotated since the
    # state was saved is all new, so it is read from its start.
    stop: Callable[[], bool] = options.get("stop") or (lambda: False)
    sleep: Callable[[int], None] = options.get("sleep") or (lambda ms: time.sleep(ms / 1000))
    poll_ms = int(options.get("pollMs") or 2000)
    resumed = read_state()
    first = os.stat(log)
    place = {"ino": first.st_ino, "offset": first.st_size}
    if resumed is not None:
        place["offset"] = int(resumed["offset"]) if resumed["offset"] <= first.st_size and _same_log(log, resumed, first) else 0
    out(f"Following {log}. AI agent fetches go to {options['to']} as they happen.")
    # The log stays open, so when it is renamed in a rotation, what was written to it before the
    # switch is still read to the end before the new log starts. Its fingerprint is taken from the
    # open file too, so a place saved while finishing an old log names that log, never the new one.
    fd = open(log, "rb")  # noqa: SIM115
    known = _head_of(fd)
    # The same trouble every two seconds is said once, until something changes.
    trouble = ""
    try:
        while not stop():
            sleep(poll_ms)
            try:
                stat = os.stat(log) if os.path.exists(log) else None
                renamed = stat is None or stat.st_ino != place["ino"]
                # Copied and truncated in place: the same file, shorter or with a new start.
                if not renamed and (stat.st_size < place["offset"] or not _same_log(log, {"ino": place["ino"], **known}, stat)):
                    place["offset"] = 0
                read = _read_from(fd, place["offset"])

                def done(at: int) -> None:
                    place["offset"] = at
                    save(place["ino"], at, known)

                sent = handle(read, done)
                # Only past lines that were sent, so a failed send is tried again next time.
                place["offset"] = read["next"]
                save(place["ino"], place["offset"], known)
                if sent:
                    out(f"Sent {_js.number_text(sent)} AI agent fetches.")
                if renamed and stat is not None and not read["more"]:
                    # The old log is finished; the new one is read from its start.
                    following = open(log, "rb")  # noqa: SIM115
                    fd.close()
                    fd = following
                    place["ino"] = stat.st_ino
                    place["offset"] = 0
                # The start grows until it is HEAD bytes long, so the fingerprint is taken again each time.
                known = _head_of(fd)
                trouble = ""
            except Exception as error:
                said = f"Could not send, trying again shortly: {error}" if isinstance(error, SendError) else f"Could not read {log}, trying again shortly: {_reason(error)}"
                if said != trouble:
                    out(said)
                trouble = said
    finally:
        fd.close()
    return total[0]


def _reason(error: BaseException) -> str:
    """An error's words, as Node's message gives them: an OSError's reason without Python's [Errno n] prefix."""
    if isinstance(error, OSError) and error.strerror:
        return f"{error.strerror}, {error.filename}" if error.filename else error.strerror
    return str(error)
