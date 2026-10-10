"""`runlight`: the standalone server and its commands, the Python counterpart of `npx runlight.sh` (packages/server's
cli.ts). Settings come from the environment:

    PORT              where to listen (3000)
    HOST              which address to listen on (0.0.0.0)
    DATA_DIR          where the SQLite file and the secret live (./runlight-data)
    DATABASE_URL      a postgres://, mysql://, or mariadb:// URL, to use that database instead of SQLite
    RUNLIGHT_SECRET   signs sessions and encrypts saved keys (made and kept in DATA_DIR if unset)
    RUNLIGHT_TOKEN    also accepted as a bearer token on the API
    RUNLIGHT_URL      the dashboard's public address, which can never become a link domain
    TRUST_PROXY       "false" when no proxy sits in front, so forwarded addresses are ignored
    RUNLIGHT_GEO      city (the default), country, off, or the path to an MMDB file
    CRON_SECRET       lets a scheduler run the check over HTTP, at POST /api/check
    RUNLIGHT_OBSERVE_KEY  one key for every site's AI agent reports
"""

from __future__ import annotations

import io
import os
import re
import secrets
import signal
import socket
import socketserver
import sys
import threading
import time
from collections.abc import Sequence
from pathlib import Path
from typing import IO, Any
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server

from ..env import env_value

HELP = """Runlight {version}, privacy friendly web analytics for any number of sites.

Usage:
  runlight                      Start the server
  runlight password <email>     Make an account, or give one a new password
  runlight check                Run the scheduled check once, and fetch this month's location data
  runlight migrate              Create or update Runlight's tables
  runlight agents --log <file>  Count AI agents from a web server's access log
  runlight --version            Print the version

Settings are environment variables. PORT (3000) and HOST (0.0.0.0) set where it
listens. DATA_DIR (./runlight-data) holds the SQLite file and the secret, and
DATABASE_URL switches to Postgres, MySQL, or MariaDB. RUNLIGHT_SECRET signs
sessions and encrypts saved keys, RUNLIGHT_TOKEN also works as a bearer token
on the API, and TRUST_PROXY=false ignores forwarded addresses when nothing sits
in front.
RUNLIGHT_URL is the dashboard's public address, such as
https://stats.example.com, which short links can never take over.
RUNLIGHT_GEO picks where locations come from when no platform header gives
them. It is city by default, which downloads DB-IP's free city database into
DATA_DIR and refreshes it each month. Set it to country for a smaller file, to
off, or to the path of your own MMDB file.

Docs: https://runlight.sh/docs/python/
"""

AGENTS_HELP = """Count AI agents on a site that has only the script tag, from its web server's log.

Usage:
  runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_...

  --log <file>    The access log, in nginx or Apache's combined format, or Caddy's JSON
  --to <url>      Your Runlight, as its dashboard address (or RUNLIGHT_URL)
  --key <key>     The site's key from Settings, Install, Key for CMS plugins (or RUNLIGHT_OBSERVE_KEY)
  --site <url>    The site's address, such as https://example.com, when the log has no host in it
  --follow        Keep running and send fetches as they happen
  --state <file>  Remember where it stopped, so the next run, or a restarted --follow, starts there.
                  Only one run at a time can use it.

Docs: https://runlight.sh/docs/python/#ai-agents-from-a-log
"""


def _version() -> str:
    from ..version import VERSION

    return VERSION


class Settings:
    """The server's settings, from the environment."""

    def __init__(self) -> None:
        self.data_dir = Path(env_value("DATA_DIR") or "./runlight-data").resolve()
        self._store: Any = None

    def store(self) -> Any:
        from ..store import Stores

        if self._store is None:
            url = env_value("DATABASE_URL")
            if url and re.match(r"(postgres(ql)?|mysql|mariadb)://", url, re.I):
                self._store = Stores.url(url)
            else:
                self.data_dir.mkdir(parents=True, exist_ok=True)
                self._store = Stores.sqlite(str(self.data_dir / "runlight.db"))
        return self._store

    def where(self) -> str:
        database = env_value("DATABASE_URL") or ""
        if re.match(r"postgres(ql)?://", database):
            return "Postgres"
        if database.startswith("mysql://"):
            return "MySQL"
        if database.startswith("mariadb://"):
            return "MariaDB"
        return str(self.data_dir / "runlight.db")

    def secret(self) -> str:
        """RUNLIGHT_SECRET, or one made on first run and kept beside the data, readable only by this user."""
        given = env_value("RUNLIGHT_SECRET")
        if given:
            return given
        self.data_dir.mkdir(parents=True, exist_ok=True)
        file = self.data_dir / "secret"
        if file.exists():
            saved = file.read_text().strip()
            if saved:
                return saved
        made = secrets.token_hex(32)
        try:
            # Made once: whoever writes the file first wins, and everyone else reads theirs.
            fd = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            time.sleep(0.05)
            return file.read_text().strip()
        with os.fdopen(fd, "w") as handle:
            handle.write(f"{made}\n")
        return made

    def url(self) -> str | None:
        url = env_value("RUNLIGHT_URL")
        if url and not re.fullmatch(r"https?://[^/?#]+/?", url):
            raise ValueError("Set RUNLIGHT_URL to the dashboard's address only, such as https://stats.example.com")
        return url

    def trust_proxy(self) -> bool | str | None:
        """"false" with nothing in front, or the one header your proxy sets, such as cf-connecting-ip. Unset stays
        None, so the library's default applies and it can warn when nothing sits in front."""
        value = (env_value("TRUST_PROXY") or "").lower()
        if not value:
            return None
        if value == "false":
            return False
        return value if value in ("x-forwarded-for", "x-real-ip", "cf-connecting-ip") else True

    def geo(self) -> tuple[Any, Any]:
        """The DB-IP download (or None) and the lookup to use (or None)."""
        from .dbip import DbIp, file_lookup

        setting = env_value("RUNLIGHT_GEO") or "city"
        if setting in ("city", "country"):
            dbip = DbIp(str(self.data_dir / "geo"), setting)
            return dbip, dbip.lookup
        if setting == "off":
            return None, None
        return None, file_lookup(str(Path(setting).resolve()))

    def server(self, **more: Any) -> Any:
        from .standalone import create_server

        dbip, lookup = self.geo()
        options: dict[str, Any] = {
            "store": self.store(),
            "secret": self.secret(),
            "token": env_value("RUNLIGHT_TOKEN"),
            "url": self.url(),
            "trustProxy": self.trust_proxy(),
            "geoCredit": dbip is not None,
            "cronSecret": env_value("CRON_SECRET"),
            "observeKey": env_value("RUNLIGHT_OBSERVE_KEY"),
            **more,
        }
        if lookup is not None:
            options["geo"] = lookup
        server = create_server(options)
        server.dbip = dbip
        return server


def _agents(args: Sequence[str], out: IO[str], err: IO[str]) -> int:
    def flag(name: str) -> str | None:
        if f"--{name}" in args:
            at = list(args).index(f"--{name}")
            return args[at + 1] if at + 1 < len(args) else None
        return None

    if "--help" in args or "-h" in args:
        out.write(AGENTS_HELP)
        return 0
    log = flag("log")
    to = flag("to") or env_value("RUNLIGHT_URL")
    key = flag("key") or env_value("RUNLIGHT_OBSERVE_KEY")
    if not log or not to or not key:
        err.write(AGENTS_HELP)
        return 1
    from .agents import run_agents

    options: dict[str, Any] = {"log": str(Path(log).resolve()), "to": to, "key": key, "follow": "--follow" in args}
    site = flag("site")
    state = flag("state")
    if site:
        options["site"] = site
    if state:
        options["state"] = str(Path(state).resolve())
    result = run_agents(options)
    return result if isinstance(result, int) else 0


def _password(settings: Settings, email: str | None, out: IO[str]) -> int:
    from ..accounts.crypto import base64url, random_bytes

    if not email:
        raise ValueError("Name the account: runlight password you@example.com")
    server = settings.server()
    server.runlight.init()
    password = base64url(random_bytes(12))
    existed = server.accounts.by_email(email) is not None
    user = server.accounts.set_password(email, password, time.time_ns() // 1_000_000)
    # Someone at the server is who they say, so a lost authenticator is no longer in the way.
    reset = bool(user.get("twoFactor"))
    if reset:
        server.accounts.disable_two_factor(user["id"])
    made = "New password" if existed else f"Account made, as {'the owner' if user.get('role') == 'owner' else 'an admin'},"
    out.write(f"{made} for {email.strip().lower()}: {password}\n")
    if reset:
        out.write("Two-factor sign-in is now off for this account; turn it on again under Account.\n")
    out.write("Sign in, and change it by running this again whenever you like.\n")
    settings.store().close()
    return 0


class _ThreadingServer(socketserver.ThreadingMixIn, WSGIServer):
    daemon_threads = True


class _Deadline(io.RawIOBase):
    """The connection's reads, each given only the time left before the deadline, so a request that trickles in
    a byte at a time is cut off as surely as one that stops."""

    def __init__(self, connection: socket.socket, idle: float, deadline: float) -> None:
        self._connection = connection
        self._idle = idle
        self._deadline = deadline

    def readable(self) -> bool:
        return True

    def readinto(self, buffer: Any) -> int:
        left = self._deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("The request took too long to arrive")
        self._connection.settimeout(min(left, self._idle))
        return self._connection.recv_into(buffer)


class _QuietHandler(WSGIRequestHandler):
    # A connection that sends nothing for this long is closed, so idle ones do not hold a thread for good.
    timeout = 30
    # And the whole request, body and all, has this long to arrive.
    request_seconds = 60.0

    def setup(self) -> None:
        super().setup()
        self.rfile = io.BufferedReader(_Deadline(self.connection, float(self.timeout), time.monotonic() + self.request_seconds))

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        pass


def _start(settings: Settings, out: IO[str]) -> int:
    from .standalone import wsgi_app

    server = settings.server()
    server.runlight.init()
    port = int(env_value("PORT") or 3000)
    host = env_value("HOST") or "0.0.0.0"
    httpd = make_server(host, port, wsgi_app(server), server_class=_ThreadingServer, handler_class=_QuietHandler)
    shown = "localhost" if host in ("0.0.0.0", "::") else host
    out.write(f"Runlight {_version()} is listening on http://{shown}:{port}\n")
    out.write(f"Data: {settings.where()}\n")
    if server.accounts.count() == 0:
        out.write(f"\nNo account yet. Open this link to create the first one:\n  http://{shown}:{port}/setup?code={server.setup_code}\n\n")
    out.flush()

    stop = threading.Event()

    # The scheduled check (salts, email reports, retention, and rollups) and this month's location data: now, then
    # every five minutes.
    def tick() -> None:
        while not stop.is_set():
            try:
                server.check()
            except Exception as error:
                print(f"Runlight: the scheduled check failed {error!r}", file=sys.stderr)
            if server.dbip is not None:
                try:
                    server.dbip.refresh(time.time_ns() // 1_000_000)
                except Exception as error:
                    print(f"Runlight: could not refresh location data {error!r}", file=sys.stderr)
            stop.wait(5 * 60)

    threading.Thread(target=tick, daemon=True).start()

    def finish(*_: Any) -> None:
        stop.set()
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, finish)
    signal.signal(signal.SIGINT, finish)
    httpd.serve_forever()
    settings.store().close()
    return 0


def run(args: Sequence[str], out: IO[str] | None = None, err: IO[str] | None = None) -> int:
    """Runs one command and returns the exit code."""
    out = out or sys.stdout
    err = err or sys.stderr
    command = args[0] if args else None
    rest = list(args[1:])
    try:
        if command in ("--help", "-h", "help"):
            out.write(HELP.format(version=_version()))
            return 0
        if command in ("--version", "-v"):
            out.write(f"{_version()}\n")
            return 0
        if command == "agents":
            return _agents(rest, out, err)
        settings = Settings()
        if command == "password":
            return _password(settings, rest[0] if rest else None, out)
        if command == "migrate":
            settings.store().migrate(True)
            out.write(f"Runlight's tables are ready in {settings.where()}.\n")
            return 0
        if command in ("check", "cron"):
            server = settings.server()
            result = server.check()
            if server.dbip is not None:
                server.dbip.refresh(time.time_ns() // 1_000_000)
            failed = result.get("reports", {}).get("failed", 0)
            if failed:
                err.write(f"Runlight: {failed} report{'s' if failed != 1 else ''} could not be sent.\n")
            return 0
        if command and command != "start":
            raise ValueError(f'Unknown command "{command}". Run runlight --help.')
        return _start(settings, out)
    except Exception as error:
        err.write(f"Runlight: {error}\n")
        return 1


def main() -> None:
    sys.exit(run(sys.argv[1:]))


if __name__ == "__main__":  # pragma: no cover
    main()

