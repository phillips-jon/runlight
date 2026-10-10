"""The `runlight` command: its version, help, migrate, password, check, and the errors it answers with."""

from __future__ import annotations

import io
import re
from pathlib import Path
from typing import Any

import pytest

from runlight.server import cli
from runlight.store import Stores
from runlight.version import VERSION

ENV = [
    "DATA_DIR", "DATABASE_URL", "RUNLIGHT_SECRET", "RUNLIGHT_TOKEN", "RUNLIGHT_URL", "TRUST_PROXY", "RUNLIGHT_GEO",
    "CRON_SECRET", "RUNLIGHT_OBSERVE_KEY", "PORT", "HOST",
]  # fmt: skip


@pytest.fixture
def data(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A data folder of its own, with nothing else from the environment, and no location data fetched."""
    for name in ENV:
        monkeypatch.delenv(name, raising=False)
    folder = tmp_path / "data"
    monkeypatch.setenv("DATA_DIR", str(folder))
    monkeypatch.setenv("RUNLIGHT_GEO", "off")
    return folder


def run(*args: str) -> tuple[int, str, str]:
    out = io.StringIO()
    err = io.StringIO()
    code = cli.run(list(args), out, err)
    return code, out.getvalue(), err.getvalue()


def test_version_and_help() -> None:
    assert run("--version") == (0, f"{VERSION}\n", "")
    assert run("-v")[1] == f"{VERSION}\n"
    code, out, _ = run("--help")
    assert code == 0
    assert out.startswith(f"Runlight {VERSION}, privacy friendly web analytics")
    assert "runlight password <email>" in out


def test_migrate_makes_the_folder_and_the_tables(data: Path) -> None:
    code, out, err = run("migrate")
    assert (code, err) == (0, "")
    assert out == f"Runlight's tables are ready in {data / 'runlight.db'}.\n"
    tables = Stores.sqlite(str(data / "runlight.db")).db.all("SELECT name FROM sqlite_master WHERE type = 'table'")
    assert {"rl_events", "rl_sessions", "rl_sites"} <= {t["name"] for t in tables}


def test_password_makes_the_owner_then_gives_a_new_password(data: Path) -> None:
    code, out, err = run("password", "Jon@Example.com")
    assert (code, err) == (0, "")
    made = re.fullmatch(r"Account made, as the owner, for jon@example\.com: (\S+)\nSign in, and change it by running this again whenever you like\.\n", out)
    assert made, out
    # The secret is made once and kept beside the data, readable only by this user.
    secret = data / "secret"
    assert len(secret.read_text().strip()) == 64
    assert secret.stat().st_mode & 0o777 == 0o600

    code, out, _ = run("password", "jon@example.com")
    assert code == 0
    again = re.match(r"New password for jon@example\.com: (\S+)\n", out)
    assert again and again.group(1) != made.group(1)
    assert run("password", "admin@example.com")[1].startswith("Account made, as an admin, for admin@example.com: ")

    # The password signs in.
    from runlight.server.cli import Settings

    server = Settings().server()
    assert server.accounts.sign_in("jon@example.com", again.group(1)) is not None


def test_password_needs_an_email(data: Path) -> None:
    assert run("password") == (1, "", "Runlight: Name the account: runlight password you@example.com\n")


def test_check_runs_the_scheduled_work(data: Path) -> None:
    assert run("check") == (0, "", "")
    assert run("cron")[0] == 0


def test_unknown_commands_and_bad_settings_say_so(data: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    assert run("nope") == (1, "", 'Runlight: Unknown command "nope". Run runlight --help.\n')
    monkeypatch.setenv("RUNLIGHT_URL", "https://stats.example.com/dashboard")
    code, _, err = run("check")
    assert code == 1
    assert "Set RUNLIGHT_URL to the dashboard's address only" in err


def test_the_server_starts_answers_and_stops_on_sigterm(data: Path) -> None:
    import os
    import signal
    import subprocess
    import sys
    import urllib.request

    port = 5141
    env = {**os.environ, "PORT": str(port), "HOST": "127.0.0.1"}
    src = str(Path(cli.__file__).resolve().parents[2])
    env["PYTHONPATH"] = src + os.pathsep + env.get("PYTHONPATH", "")
    process = subprocess.Popen(
        [sys.executable, "-m", "runlight.server.cli"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    try:
        assert process.stdout is not None
        first = process.stdout.readline()
        assert first == f"Runlight {VERSION} is listening on http://127.0.0.1:{port}\n"
        assert process.stdout.readline() == f"Data: {data / 'runlight.db'}\n"
        assert "No account yet. Open this link to create the first one:" in process.stdout.readline() + process.stdout.readline()
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=5) as answer:
            assert answer.read() == b"ok"
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=10) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    assert process.stderr is not None
    assert process.stderr.read() == ""


def test_agents_asks_for_what_it_needs(data: Path) -> None:
    code, out, err = run("agents")
    assert code == 1
    assert err.startswith("Count AI agents on a site that has only the script tag")
    assert run("agents", "--help")[0] == 0


def test_a_connection_that_stalls_is_closed_and_frees_its_thread() -> None:
    import select
    import socket
    import threading
    import time
    from wsgiref.simple_server import make_server

    class Handler(cli._QuietHandler):
        timeout = 0.3
        request_seconds = 0.8

    def echo(environ: Any, start_response: Any) -> list[bytes]:
        body = environ["wsgi.input"].read(int(environ.get("CONTENT_LENGTH") or 0))
        start_response("200 OK", [("content-type", "text/plain")])
        return [body]

    httpd = make_server("127.0.0.1", 0, echo, server_class=cli._ThreadingServer, handler_class=Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    port = httpd.server_address[1]
    try:
        # Sending nothing at all.
        with socket.create_connection(("127.0.0.1", port), timeout=5) as idle:
            started = time.monotonic()
            assert idle.recv(1024) == b""
            assert time.monotonic() - started < 3
        # Sending a body a byte at a time, each well inside the idle timeout.
        with socket.create_connection(("127.0.0.1", port), timeout=5) as slow:
            slow.sendall(b"POST / HTTP/1.0\r\nContent-Length: 100\r\n\r\n")
            started = time.monotonic()
            # Until the server answers: the app's read fails, so it sends an error, if anything, and hangs up.
            while not select.select([slow], [], [], 0.1)[0] and time.monotonic() - started < 5:
                slow.sendall(b"x")
            answer = slow.makefile("rb").read()
            assert answer == b"" or answer.startswith(b"HTTP/1.0 500")
            assert time.monotonic() - started < 3
        # A request that arrives in time is answered.
        with socket.create_connection(("127.0.0.1", port), timeout=5) as quick:
            quick.sendall(b"POST / HTTP/1.0\r\nContent-Length: 2\r\n\r\nhi")
            assert quick.makefile("rb").read().endswith(b"\r\n\r\nhi")
    finally:
        httpd.shutdown()
        httpd.server_close()
