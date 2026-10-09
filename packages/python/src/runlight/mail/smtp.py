"""A small SMTP client: implicit TLS (465), STARTTLS (587), or plain (local
relays), with AUTH PLAIN, over the standard library's sockets.
"""

from __future__ import annotations

import base64
import errno
import re
import socket
import ssl
import time
import uuid as _uuid
from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

from .. import _js
from .transports import MailError

# Each reply must come within this long.
REPLY_TIMEOUT_MS = 20_000

_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def _b64(text: str) -> str:
    return base64.b64encode(_js.encode(text)).decode("ascii")


def _wrap(text: str) -> str:
    """Base64 in lines of 76, each ending in CRLF, as `.replace(/.{1,76}/g, "$&\\r\\n")` writes it."""
    return "".join(f"{text[at : at + 76]}\r\n" for at in range(0, len(text), 76))


_PRINTABLE = re.compile(r"[\x20-\x7e]*\Z")


def _encode_word(text: str) -> str:
    return text if _PRINTABLE.match(text) else f"=?UTF-8?B?{_b64(text)}?="


# JavaScript's `.` leaves out line terminators.
_NAMED = re.compile("([^\n\r  ]*)<([^\n\r  ]+)>\\Z")


def _utc_string(ms: int) -> str:
    """Date's toUTCString(), with +0000 for GMT."""
    d = datetime.fromtimestamp(ms // 1000, tz=timezone.utc)
    return f"{_DAYS[d.weekday()]}, {d.day:02d} {_MONTHS[d.month - 1]} {d.year} {d.hour:02d}:{d.minute:02d}:{d.second:02d} +0000"


def mime(m: dict[str, Any], from_: str, now: int | None = None, uuid: Callable[[], str] | None = None) -> str:
    """The message as MIME: text and HTML alternatives, both base64. Public for its test. `now` is in
    milliseconds (the clock when None), and `uuid` stands in for crypto.randomUUID() in tests."""
    uuid = uuid or (lambda: str(_uuid.uuid4()))
    now = int(time.time() * 1000) if now is None else now
    boundary = f"rl-{uuid()}"
    at = m["from"].split("@")
    domain = at[1] if len(at) > 1 else "runlight.local"
    named = _NAMED.match(from_)
    from_header = f"{_encode_word(_js.trim(named.group(1)))} <{named.group(2)}>" if named else from_
    headers = [
        f"From: {from_header}",
        f"To: {m['to']}",
        f"Subject: {_encode_word(m['subject'])}",
        f"Date: {_utc_string(now)}",
        f"Message-ID: <{uuid()}@{domain}>",
        "MIME-Version: 1.0",
        *(f"{k}: {_no_breaks(v)}" for k, v in (m.get("headers") or {}).items()),
        f'Content-Type: multipart/alternative; boundary="{boundary}"',
    ]
    return "\r\n".join([
        "\r\n".join(headers),
        "",
        f"--{boundary}",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        _wrap(_b64(m["text"])),
        f"--{boundary}",
        "Content-Type: text/html; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        _wrap(_b64(m["html"])),
        f"--{boundary}--",
        "",
    ])  # fmt: skip


def _no_breaks(value: str) -> str:
    return value.replace("\r", "").replace("\n", "")


def _node_message(error: OSError, host: str, port: int) -> str:
    """What Node says for a connection that failed, so the dashboard reads the same either way."""
    if isinstance(error, socket.gaierror):
        return f"getaddrinfo ENOTFOUND {host}"
    if isinstance(error, (TimeoutError, socket.timeout)):
        return "timed out"
    name = errno.errorcode.get(error.errno or 0)
    if name:
        return f"connect {name} {host}:{port}"
    return str(error)


class _Session:
    """One SMTP connection: the socket, the replies read from it (multi-line included, one at a time), and the
    whole send's deadline, which every wait is held to."""

    def __init__(self, host: str, port: int, deadline: float, late_message: str) -> None:
        self.host = host
        self.port = port
        self.deadline = deadline
        self.late_message = late_message
        self.sock: socket.socket | None = None
        self.buffer = b""
        self.lines: list[str] = []

    def late(self) -> MailError:
        self.close()
        return MailError(self.late_message, "mail_slow", {"host": f"{self.host}:{self.port}"})

    def left(self) -> float:
        """Seconds left before the deadline."""
        return self.deadline - time.monotonic()

    def connect(self, tls: bool, timeout_ms: int) -> None:
        wait = min(timeout_ms / 1000, self.left())
        if wait <= 0:
            raise self.late()
        try:
            sock = socket.create_connection((self.host, self.port), timeout=wait)
            if tls:
                sock = ssl.create_default_context().wrap_socket(sock, server_hostname=self.host)
        except OSError as error:
            if self.left() <= 0:
                raise self.late() from None
            detail = _node_message(error, self.host, self.port)
            raise MailError(
                f"SMTP: could not connect to {self.host}:{self.port}: {detail}",
                "mail_unreachable",
                {"host": f"{self.host}:{self.port}", "detail": detail},
            ) from None
        self.sock = sock

    def write(self, line: str) -> None:
        self.write_raw(f"{line}\r\n")

    def write_raw(self, data: str) -> None:
        if self.sock is None:
            raise MailError("SMTP: the server closed the connection")
        wait = self.left()
        if wait <= 0:
            raise self.late()
        try:
            self.sock.settimeout(wait)
            self.sock.sendall(_js.encode(data))
        except OSError:
            if self.left() <= 0:
                raise self.late() from None
            self.close()
            raise MailError("SMTP: the server closed the connection") from None

    def next(self, timeout_ms: int, quiet: bool = False) -> dict[str, Any] | None:
        """The next whole reply, {code, text}. Raises when none comes within `timeout_ms` (or, with `quiet`, gives
        None then), and a mail_slow error once the deadline passes."""
        idle_until = time.monotonic() + timeout_ms / 1000
        while True:
            while (at := self.buffer.find(b"\r\n")) >= 0:
                line = _js.utf8(self.buffer[:at])
                self.buffer = self.buffer[at + 2 :]
                self.lines.append(line[4:])
                if line[3:4] != "-":
                    reply = {"code": _js.number(line[:3]), "text": " ".join(self.lines)}
                    self.lines = []
                    return reply
                # Activity resets the idle timer, as Node's socket timeout does.
                idle_until = time.monotonic() + timeout_ms / 1000
            if self.sock is None:
                raise MailError("SMTP: the server closed the connection")
            deadline_left = self.left()
            if deadline_left <= 0:
                raise self.late()
            idle_left = idle_until - time.monotonic()
            if idle_left <= 0:
                if quiet:
                    return None
                self.close()
                raise MailError("SMTP: timed out")
            try:
                self.sock.settimeout(min(deadline_left, idle_left))
                chunk = self.sock.recv(8192)
            except (TimeoutError, socket.timeout):
                # Nothing came in the time left; the checks above decide what that means.
                continue
            except OSError as error:
                self.close()
                raise MailError(f"SMTP: {error}") from None
            if not chunk:
                self.close()
                raise MailError("SMTP: the server closed the connection")
            self.buffer += chunk
            idle_until = time.monotonic() + timeout_ms / 1000

    def start_tls(self) -> None:
        """Turns on TLS after STARTTLS. Anything the server sent before it is dropped, as a new reader would."""
        self.buffer = b""
        self.lines = []
        wait = self.left()
        if wait <= 0:
            raise self.late()
        assert self.sock is not None
        try:
            self.sock.settimeout(wait)
            self.sock = ssl.create_default_context().wrap_socket(self.sock, server_hostname=self.host)
        except (OSError, ssl.SSLError) as error:
            if self.left() <= 0:
                raise self.late() from None
            reason = getattr(error, "reason", None) or str(error)
            raise MailError(f"SMTP: TLS failed: {reason}") from None

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


def smtp_send(
    config: dict[str, Any],
    m: dict[str, Any],
    from_: str,
    deadline: int = 60_000,
    now: int | None = None,
    uuid: Callable[[], str] | None = None,
) -> None:
    """Sends one message. Each reply must come within 20 s, and the whole send
    within the deadline (60 s), so a server that trickles a line now and then
    cannot hold the scheduled check that sends reports. Its deadline is a
    parameter for its test, as are the clock and UUIDs the MIME is written with."""
    host = _js.trim(config["host"])
    security = config.get("security") or "starttls"
    given = _js.number(config.get("port", _js.UNDEFINED))
    port = int(given) if _js.truthy(given) else (465 if security == "tls" else 587)
    seconds = _js.number_text(_js.js_round(deadline / 1000))
    session = _Session(host, port, time.monotonic() + deadline / 1000, f"SMTP: {host}:{port} took longer than {seconds} s")
    try:
        _converse(session, config, m, from_, security, now, uuid)
    finally:
        session.close()


def _converse(s: _Session, config: dict[str, Any], m: dict[str, Any], from_: str, security: str, now: int | None, uuid: Callable[[], str] | None) -> None:
    s.connect(security == "tls", REPLY_TIMEOUT_MS)

    def expect(codes: list[int], what: str) -> dict[str, Any]:
        reply = s.next(REPLY_TIMEOUT_MS)
        assert reply is not None
        if reply["code"] not in codes:
            raise MailError(_js.cut(f"SMTP {what}: {_js.number_text(reply['code'])} {reply['text']}", 300))
        return reply

    expect([220], "greeting")
    at = from_.split("@")
    name = re.sub(r">\Z", "", at[1]) if len(at) > 1 else ""
    name = name or "localhost"
    s.write(f"EHLO {name}")
    ehlo = expect([250], "EHLO")
    if security == "starttls":
        if not re.search("STARTTLS", ehlo["text"], re.I):
            raise MailError("SMTP: the server does not offer STARTTLS; pick tls or none", "smtp_starttls", {})
        s.write("STARTTLS")
        expect([220], "STARTTLS")
        s.start_tls()
        s.write(f"EHLO {name}")
        expect([250], "EHLO")
    if config.get("username"):
        s.write(f"AUTH PLAIN {_b64(chr(0) + config['username'] + chr(0) + (config.get('password') or ''))}")
        expect([235], "sign-in")
    s.write(f"MAIL FROM:<{m['from']}>")
    expect([250], "MAIL FROM")
    s.write(f"RCPT TO:<{m['to']}>")
    expect([250, 251], "RCPT TO")
    s.write("DATA")
    expect([354], "DATA")
    # A line starting with a dot gets a second one, so it is not read as the end.
    s.write_raw(mime(m, from_, now, uuid).replace("\r\n.", "\r\n..") + "\r\n.\r\n")
    expect([250], "message")
    s.write("QUIT")
    # Wait for the goodbye, but never fail a sent message over it.
    try:
        s.next(2000, True)
    except MailError as error:
        if error.code == "mail_slow":
            raise
