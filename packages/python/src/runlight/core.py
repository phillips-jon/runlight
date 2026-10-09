"""Runlight in an app: the sites it counts, the tracker endpoint's work, short links, email reports, and the
scheduled upkeep. A port of the TypeScript SDK's runlight.ts.

Options, with the TS names (as a dict, or as keyword arguments in snake_case, `rate_limit=60`):

- store: a SqlStore (required), such as Stores.sqlite("./data/runlight.db").
- site: {"id"?, "name"?, "hostnames"?, "timezone"?}, the site this install counts. Ignored when `sites` is
  given. `id` is a stable id, stored with every row, default "default". `hostnames` are the hostnames that
  belong to the site, without www; with one site, empty means any hostname, and with several, each site needs
  at least one. `timezone` is an IANA timezone for reports, such as "Europe/London", default "UTC".
- sites: several sites in one install, told apart by hostname.
- managedSites: sites are added, changed, and deleted in the dashboard and kept in the database, as the
  standalone server does. `site` and `sites` are ignored.
- geo: a callable(ip) giving {"country", "region", "city"} or None, a location for an IP when the platform
  sends no location headers.
- trustProxy: True (default), False, or one of "x-forwarded-for", "x-real-ip", "cf-connecting-ip". Read the
  client IP from forwarding headers: the last X-Forwarded-For entry, which the nearest proxy wrote, then
  X-Real-IP, then CF-Connecting-IP. Name one of them to read only that header. False reads only the
  connection's address, for an app nothing sits in front of.
- linkPath: where short links on the app's own domain live, as `{linkPath}/{slug}`. Default "/go".
- mail: the mail service for email reports, in code (a transports config plus `from` and `fromName`). When
  set, the dashboard shows it and cannot change it. Otherwise it is set up in Settings.
- secret: encrypts the keys kept in the database: the mail service's, the AI Assistant's, and the tokens for
  connected installs. Default the RUNLIGHT_SECRET environment variable, then RUNLIGHT_TOKEN.
- rateLimit: tracker requests allowed per visitor address per minute. Default 120, which a real visitor never
  reaches; False turns the limit off.
- now: a callable giving the clock in epoch milliseconds. For tests.
- fetcher: the Fetcher every outgoing request goes through. Default UrllibFetcher.

TS runs some work after answering or on timers. Here the retention a settings change asks for runs in idle(),
which an adapter calls once the answer is sent, and everything else in check().
"""

from __future__ import annotations

import datetime
import math
import re
import sys
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

from . import _js
from .env import env_value
from .http import BodyTooLong, Fetcher, Request, Response, Url, UrllibFetcher

# A path on every link domain that answers when the domain reaches this Runlight.
LINK_DOMAIN_CHECK = "/.well-known/runlight-link-domain"

# The choices for how long a site keeps its visits.
RETENTION_MONTHS = [6, 12, 24, 36, 60]

# Thirty minutes without a request ends a session.
SESSION_IDLE_MS = 30 * 60 * 1000

# What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets.
EMAIL = re.compile(f'[^{_js.WHITESPACE}@<>"]+@[^{_js.WHITESPACE}@<>"]+\\.[^{_js.WHITESPACE}@<>"]+\\Z')

# Raised whenever what a rolled-up day holds changes. 2: the heatmap counts visits only. 3: a page counts the
# views that can report time.
ROLLUP_VERSION = 3
# Days of rollups built per site in one scheduled check, and how long after a day ends it is built.
ROLLUP_BATCH = 10
# The most a connected install's list of sites may weigh; a real one is a few kilobytes.
REMOTE_MAX_BYTES = 2 * 1024 * 1024
# On a database that caps statements per request (Cloudflare D1), fewer days a check, about 30 statements.
METERED_ROLLUP_BATCH = 4
ROLLUP_DELAY_MS = 2 * 3_600_000

_SITE_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}\Z", re.I)
_DOMAIN = re.compile(r"(?=.{1,253}\Z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\Z")
_BUSY = re.compile(
    r"timeout exceeded when trying to connect|connection timeout|no MySQL connection was free|SQLITE_BUSY|"
    r"database is locked",
    re.I,
)


class SettingsError(_js.RangeError):
    """A setting refused, such as a site's domain or the assistant's service, as a code the dashboard says in its
    own words."""

    def __init__(self, message: str, code: str, params: Mapping[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = dict(params or {})


def _camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def options_from(options: Mapping[str, Any] | None, kwargs: Mapping[str, Any]) -> dict[str, Any]:
    """Options as a dict with the TS names: a dict given as it is, and keyword arguments in snake_case renamed."""
    out = dict(options or {})
    for key, value in kwargs.items():
        out[_camel(key)] = value
    return out


def _wall_clock() -> int:
    return time.time_ns() // 1_000_000


def _utc_day(ts: int) -> str:
    return _js_iso(ts)[:10]


def _js_iso(ts: int) -> str:
    at = datetime.datetime(1970, 1, 1, tzinfo=datetime.UTC) + datetime.timedelta(milliseconds=ts)
    return at.strftime("%Y-%m-%dT%H:%M:%S.") + f"{at.microsecond // 1000:03d}Z"


def _site_row(options: Mapping[str, Any], index: int) -> dict[str, Any]:
    from .sources import strip_www
    from .time import is_timezone

    timezone = options.get("timezone", "UTC")
    if timezone is None:
        timezone = "UTC"
    if not is_timezone(timezone):
        raise ValueError(f'Runlight: unknown timezone "{timezone}"')
    site_id = options.get("id")
    if site_id is None:
        site_id = "default" if index == 0 else ""
    if not site_id or not _SITE_ID.match(site_id):
        raise ValueError(f'Runlight: site id "{site_id}" must be letters, digits, dots, dashes, or underscores')
    hostnames = list(options.get("hostnames") or [])
    name = options.get("name")
    if name is None:
        name = hostnames[0] if hostnames else "My site"
    return {
        "id": site_id,
        "name": name,
        "hostnames": [strip_www(str(h)) for h in hostnames],
        "timezone": timezone,
    }


def _by_name(sites: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Sites in name order, as TS sorts them with localeCompare."""
    return sorted(sites, key=lambda site: _js.locale_key(site["name"]))


def _busy(error: BaseException) -> bool:
    """True for a database that could not take a statement just now and may a moment later."""
    return bool(_BUSY.search(str(error)))


class Runlight:
    """Runlight in an app. See the module's docstring for the options."""

    def __init__(self, options: Mapping[str, Any] | None = None, **kwargs: Any) -> None:
        from .limit import RateLimit
        from .links import Links
        from .store import SqlStore

        opts = options_from(options, kwargs)
        store = opts.get("store")
        if not isinstance(store, SqlStore):
            raise ValueError('Runlight: pass a store, such as Stores.sqlite("./data/runlight.db")')
        self.store: Any = store
        # Whether sites are managed in the dashboard.
        self.managed_sites: bool = bool(opts.get("managedSites", False))
        if self.managed_sites:
            configured: list[Mapping[str, Any]] = []
        elif opts.get("sites"):
            configured = list(opts["sites"])
        else:
            configured = [opts.get("site") or {}]
        # The sites as configured in code, or as kept in the database when they are managed.
        self._configured: list[dict[str, Any]] = [_site_row(site, i) for i, site in enumerate(configured)]
        if len(self._configured) > 1 and any(not site["hostnames"] for site in self._configured):
            raise ValueError("Runlight: with several sites, give each one its hostnames")
        if len({site["id"] for site in self._configured}) != len(self._configured):
            raise ValueError("Runlight: two sites share an id")
        # Sites counted by another Runlight install, read through its API with the token it gave, read or manage.
        self._remotes: dict[str, dict[str, Any]] = {}
        self._remote_seen: dict[str, dict[str, Any]] = {}
        self._overrides: dict[str, dict[str, Any]] = {}
        self._geo = opts.get("geo")
        trust = opts.get("trustProxy", True)
        self._trust_proxy: bool | str = True if trust is None else trust
        per_minute = opts.get("rateLimit", 120)
        if per_minute is None:
            per_minute = 120
        # False, 0, or anything that is not a positive number means no limit, never a limit of nothing.
        number = math.nan if per_minute is False else _js.number(per_minute)
        self._limit = RateLimit(int(math.floor(number)) if math.isfinite(number) else sys.maxsize, self.now) if number > 0 else None
        self._clock: Callable[[], int] = opts.get("now") or _wall_clock
        # Every outgoing request goes through it.
        self.fetcher: Fetcher = opts.get("fetcher") or UrllibFetcher()
        # Short links: create, change, delete, and import.
        self.links = Links(self)
        # Where links on the app's own domain are served, such as "/go".
        link_path = opts.get("linkPath")
        self.link_path = "/" + re.sub(r"^/+|/+$", "", str("/go" if link_path is None else link_path))
        self._mail_in_code: dict[str, Any] | None = opts.get("mail")
        # Encrypts the keys kept in the database; None leaves them readable, and the dashboard says so.
        secret = opts.get("secret")
        self.secret: str | None = str(secret) if secret is not None else (env_value("RUNLIGHT_SECRET") or env_value("RUNLIGHT_TOKEN"))
        # Where routes() serves the dashboard and API, which a link domain leaves alone, as a list without repeats.
        # Middleware often runs apart from the routes, where none were made, so the default "/runlight" stands in.
        self.route_bases: list[str] = []
        self._ready = False
        self._ready_lock = threading.RLock()
        self._check_lock = threading.Lock()
        self._checking: threading.Event | None = None
        self._check_thread: int | None = None
        self._check_result: dict[str, Any] | None = None
        # When planner statistics were last gathered.
        self._optimized_at = 0
        self._link_domain_cache: dict[str, Any] | None = None
        # Each timezone's salts for its current day, so a lookup is a map read until midnight there.
        self._salts: dict[str, dict[str, Any]] = {}
        # Retention work asked for and not yet done: a site's id, or None for every site.
        self._pruning: list[str | None] = []
        self._pruning_lock = threading.Lock()
        # Work queued per key, such as one visitor's session.
        self._turns: dict[str, list[Any]] = {}
        self._turns_lock = threading.Lock()

    def now(self) -> int:
        """The clock, in epoch milliseconds."""
        return int(self._clock())

    # Mail

    def mail_settings(self) -> dict[str, Any] | None:
        """The mail service: from code, or as saved in the dashboard. None when there is none."""
        from .mail.secret import unseal

        if self._mail_in_code is not None:
            return {**self._mail_in_code, "source": "code"}
        self.init()
        sealed = self.store.setting("mail")
        if not sealed:
            return None
        opened = unseal(sealed, self.secret)
        if not opened:
            return None
        return {**_js.loads(opened), "source": "dashboard"}

    def save_mail_settings(self, input: Mapping[str, Any] | None) -> None:
        """Saves the mail service from the dashboard. A secret field left blank keeps the saved value, so the
        browser never needs to see it."""
        from .mail.secret import seal
        from .mail.transports import SERVICES, MailError, check_config

        if self._mail_in_code is not None:
            raise MailError("The mail service is set in code", "mail_in_code", {})
        if input is None:
            self.store.set_setting("mail", None)
            return
        before = self.mail_settings()
        service = next((s for s in SERVICES if s["id"] == input.get("service")), None)
        if service is None:
            raise MailError("Pick a mail service", "mail_service", {})
        settings: dict[str, Any] = {"service": service["id"]}
        for f in service["fields"]:
            if not f.get("secret"):
                settings[f["name"]] = _js.trim(_js.string(_or(input.get(f["name"]), "")))
        # A blank secret keeps the saved one only while the connection is the same,
        # so changing the host cannot send a saved password somewhere new.
        same = (before or {}).get("service") == service["id"] and all(
            f.get("secret") or _js.string(_or((before or {}).get(f["name"]), "")) == settings[f["name"]]
            for f in service["fields"]
        )
        for f in service["fields"]:
            if not f.get("secret"):
                continue
            given = _js.trim(_js.string(_or(input.get(f["name"]), "")))
            settings[f["name"]] = _js.string(_or((before or {}).get(f["name"]), "")) if not given and same else given
        sender = _js.trim(_js.string(_or(input.get("from"), "")))
        if not EMAIL.match(sender):
            raise MailError("Enter the address reports come from, like reports@example.com", "mail_from", {})
        from_name = _js.slice16(_js.trim(_js.string(_or(input.get("fromName"), ""))), 0, 80)
        config = {**settings, "from": sender, **({"fromName": from_name} if from_name else {})}
        check_config(config)
        self.store.set_setting("mail", seal(_js.dumps(config), self.secret))

    def send_mail(self, message: Mapping[str, Any]) -> None:
        """Sends one email through the mail service: {to, subject, html, text, headers?}."""
        from .mail.transports import MailError, send

        settings = self.mail_settings()
        if settings is None:
            raise MailError("Set up a mail service first", "mail_unset", {})
        full = {**message, "from": settings["from"]}
        if settings.get("fromName") is not None:
            full["fromName"] = settings["fromName"]
        send(settings, full, self.fetcher, self.now())

    def send_reports(self) -> dict[str, int]:
        """Sends every report that is due: last week's on Monday from 8am, last month's on the 1st, in each site's
        timezone. Safe to run often; each period goes out once. Called by check()."""
        from .reports import last_period

        self.init()
        result = {"sent": 0, "failed": 0}
        reports = self.store.reports()
        if not reports or self.mail_settings() is None:
            return result
        now = self.now()
        for r in reports:
            site = self.site(r["site"])
            if site is None:
                continue
            period = last_period(r["frequency"], now, site["timezone"])
            if now < period["dueAt"] or r["lastPeriod"] == period["key"]:
                continue
            if not self.store.claim_report(r["id"], period["key"], now):
                continue
            try:
                self.deliver_report(r, site, period)
                result["sent"] += 1
            except Exception as error:
                self.store.release_report(r["id"], period["key"], r["lastPeriod"])
                print(
                    f"Runlight: could not send the {r['frequency']} report for {site['name']} to {r['email']}: {error}",
                    file=sys.stderr,
                )
                result["failed"] += 1
        return result

    def deliver_report(self, r: Mapping[str, Any], site: Mapping[str, Any], period: Mapping[str, Any] | None = None) -> None:
        """Builds and sends one report. Also used by "Send a sample now"."""
        from .reports import build_report, last_period

        if period is None:
            period = last_period(r["frequency"], self.now(), site["timezone"])
        unsubscribe = f"{r['origin']}/unsubscribe/{r['token']}"
        report = build_report(
            self,
            site,
            r["frequency"],
            period,
            r["lang"],
            {"dashboard": f"{r['origin']}/?site={_js.encode_uri_component(site['id'])}", "unsubscribe": unsubscribe},
        )
        self.send_mail(
            {
                "to": r["email"],
                "subject": report["subject"],
                "html": report["html"],
                "text": report["text"],
                "headers": {"List-Unsubscribe": f"<{unsubscribe}>", "List-Unsubscribe-Post": "List-Unsubscribe=One-Click"},
            }
        )

    # Sites

    def init(self) -> None:
        """Creates tables and records the configured sites. Runs once."""
        if self._ready:
            return
        with self._ready_lock:
            if self._ready:
                return
            self.store.migrate()
            # A database that never had its statistics gathered gets them now, before any report is read, rather
            # than at the first scheduled check, which an app may never run.
            self.store.optimize(True)
            if self.managed_sites:
                self._configured = self.store.sites()
                self._load_remotes()
            for site in self._configured:
                self.store.upsert_site(site, self.now())
            self._overrides = self.store.site_overrides()
            # A process starting with a timezone set in code is the newest word on it: if the code changed it,
            # the days built in the old one are cleared here, once, and never by a process still running.
            for site in self.sites:
                if site["id"] in self._remotes:
                    continue
                stored = self.store.setting(f"rollup-zone:{site['id']}")
                zone = _js.loads(stored)["zone"] if stored else None
                if zone is None:
                    self.store.set_setting(f"rollup-zone:{site['id']}", _js.dumps({"zone": site["timezone"], "since": 0}))
                elif zone != site["timezone"]:
                    self._zone_changed(site["id"], site["timezone"])
            self._ready = True

    def routes(self, options: Mapping[str, Any] | None = None, **kwargs: Any) -> Any:
        """The dashboard and API (routes.py). Options with the TS RoutesOptions names, as a dict or in snake_case
        keyword arguments: basePath, token, accounts, origin, observeKey, cronSecret, signIn, signOut, authorize,
        geoCredit, ownHosts."""
        from .routes import create_routes

        return create_routes(self, options_from(options, kwargs))

    @property
    def sites(self) -> list[dict[str, Any]]:
        """The sites, with any settings changed in the dashboard applied."""
        return [{**site, **self._overrides.get(site["id"], {})} for site in self._configured]

    def _hostnames_for(self, input: Any, except_id: str | None = None) -> list[str]:
        """Checks a list of hostnames for a managed site: at least one, each a domain, none taken."""
        from .sources import strip_www

        items = list(input) if isinstance(input, list) else re.split(f"[{_js.WHITESPACE},]+", _js.string(_or(input, "")))
        hostnames: list[str] = []
        for h in items:
            host = _js.trim(_js.string(h))
            host = re.sub(r"^https?://", "", host)
            host = re.sub(r"[/:][^\n\r  ]*\Z", "", host)
            host = strip_www(host)
            if host and host not in hostnames:
                hostnames.append(host)
        if not hostnames:
            raise SettingsError("Add the site's domain, like example.com", "site_domain_needed")
        for host in hostnames:
            if not _DOMAIN.match(host) and host != "localhost":
                raise SettingsError(f'"{host}" is not a domain name', "site_domain_invalid", {"host": host})
            for site in self._configured:
                if site["id"] != except_id and host in site["hostnames"]:
                    raise SettingsError(
                        f"{host} already belongs to {site['name']}", "site_domain_taken", {"host": host, "site": site["name"]}
                    )
        return hostnames

    def _load_remotes(self) -> None:
        from .mail.secret import unseal

        self._remotes = {}
        for row in self.store.settings_starting_with("remote:"):
            opened = unseal(row["value"], self.secret)
            if opened:
                self._remotes[row["key"][len("remote:") :]] = _js.loads(opened)

    def remote(self, site_id: str) -> dict[str, Any] | None:
        """The install a site is read from, when it is counted elsewhere."""
        return self._remotes.get(site_id)

    def remote_last_seen(self, site_id: str) -> int | float | None:
        """When a connected install's site last had a visit, asked at most once a minute."""
        info = self.remote_info(site_id)
        return None if info is None else info.get("lastSeen")

    def remote_info(self, site_id: str) -> dict[str, Any] | None:
        """What a connected install says about its site: its last visit and how long it keeps visits, asked at
        most once a minute. Retention is UNDEFINED while the install cannot be reached, and `connection` says
        whether it answered ("ok"), refused this server's token ("refused"), or could not be reached
        ("unreachable")."""
        remote = self._remotes.get(site_id)
        if remote is None:
            return None
        cached = self._remote_seen.get(site_id)
        if cached is not None and self.now() - cached["at"] < 60_000:
            return {k: v for k, v in cached.items() if k != "at"}
        info: dict[str, Any] = {
            "lastSeen": cached.get("lastSeen") if cached else None,
            "retentionMonths": _js.UNDEFINED,
            "connection": "unreachable",
        }
        try:
            answer = self.fetcher.fetch(
                f"{remote['url']}/api/sites",
                {"headers": {"authorization": f"Bearer {remote['token']}"}, "timeoutMs": 8000, "maxBytes": REMOTE_MAX_BYTES},
            )
            if answer.status in (401, 403):
                info["connection"] = "refused"
            body = _json_or_none(answer)
            sites = body.get("sites") if isinstance(body, dict) else None
            for s in sites if isinstance(sites, list) else []:
                if not isinstance(s, dict):
                    # TS reads `s.id` of each and stops at a null, as a throw would.
                    if s is None:
                        break
                    continue
                if s.get("id", _js.UNDEFINED) == remote["site"]:
                    info = {"lastSeen": _or(s.get("lastSeen"), None), "retentionMonths": _or(s.get("retentionMonths"), None), "connection": "ok"}
                    break
        except Exception:
            pass
        self._remote_seen[site_id] = {"at": self.now(), **info}
        return info

    def forget_remote_info(self, site_id: str) -> None:
        """Forgets what a connected install said, after a change made through it."""
        self._remote_seen.pop(site_id, None)

    def _revoke_remote_token(self, remote: Mapping[str, Any]) -> None:
        """Asks a connected install to delete the token this server holds for it. A failure leaves it listed there."""
        try:
            self.fetcher.fetch(
                f"{remote['url']}/api/token",
                {"method": "DELETE", "headers": {"authorization": f"Bearer {remote['token']}"}, "timeoutMs": 5_000},
            )
        except Exception:
            pass

    def _add_remote_site(self, input: Mapping[str, Any]) -> dict[str, Any]:
        """Connects a site counted by another Runlight (an app's own install) so this server shows it too. Takes the
        install's address, as its dashboard is (https://example.com/runlight), and an API token made there."""
        from .mail.secret import seal
        from .time import is_timezone

        url = re.sub(r"/+\Z", "", _js.trim(_js.string(_or(input.get("url"), ""))))
        if not re.match(r"https://[^/]+|http://(localhost|127\.0\.0\.1)(:\d+)?(/|\Z)", url):
            raise SettingsError("Enter the install's address, like https://example.com/runlight", "connect_url")
        token = _js.trim(_js.string(_or(input.get("token"), "")))
        if not token:
            raise SettingsError("Enter an API token from that install", "install_token")
        try:
            answer = self.fetcher.fetch(
                f"{url}/api/sites",
                {"headers": {"authorization": f"Bearer {token}"}, "timeoutMs": 10_000, "maxBytes": REMOTE_MAX_BYTES},
            )
        except BodyTooLong:
            # An answer too long to read is no Runlight's.
            raise SettingsError(f"{url} did not answer like a Runlight install", "connect_not_runlight", {"url": url}) from None
        except Exception:
            parsed = Url.parse(url)
            raise SettingsError(f"Could not reach {url}", "unreachable", {"host": parsed.host if parsed else url}) from None
        if answer.status in (401, 403):
            raise SettingsError("That install refused the token", "install_refused")
        body = _json_or_none(answer)
        sites = body.get("sites") if isinstance(body, dict) and isinstance(body.get("sites"), list) else []
        if not answer.ok or not sites:
            raise SettingsError(f"{url} did not answer like a Runlight install", "connect_not_runlight", {"url": url})
        # What the token may do there; an install from before manage tokens has no /api/token and reads only.
        scope = "read"
        token_site = ""
        try:
            about = self.fetcher.fetch(
                f"{url}/api/token",
                {"headers": {"authorization": f"Bearer {token}"}, "timeoutMs": 10_000, "maxBytes": REMOTE_MAX_BYTES},
            )
            info = _json_or_none(about) if about.ok else None
            if isinstance(info, dict) and info.get("scope") == "manage":
                scope = "manage"
            token_site = _js.string(_or(info.get("site"), "") if isinstance(info, dict) else "")
        except Exception:
            pass
        want = token_site if token_site else input.get("site", _js.UNDEFINED)
        there = next((s for s in sites if isinstance(s, dict) and s.get("id", _js.UNDEFINED) == want), None) or sites[0]
        if not isinstance(there, dict):
            there = {}
        # An install's answer is read as given: a site without a list of hostnames has none.
        there_hostnames = [h for h in there.get("hostnames", []) if isinstance(h, str)] if isinstance(there.get("hostnames"), list) else []
        # Connecting the same site again (to allow changes, or with a new token) updates it in place.
        for existing, known in list(self._remotes.items()):
            if known["url"] == url and known["site"] == there.get("id"):
                updated = {**known, "token": token, "scope": scope, "hostnames": there_hostnames}
                if known["token"] != token:
                    self._revoke_remote_token(known)
                self.store.set_setting(f"remote:{existing}", seal(_js.dumps(updated), self.secret))
                self._remotes[existing] = updated
                self._remote_seen.pop(existing, None)
                return self.site(existing)  # type: ignore[return-value]
        parsed = Url.parse(url)
        first = there_hostnames[0] if there_hostnames else (parsed.host if parsed else "")
        host = re.sub(r"[^a-z0-9._-]", "-", first, flags=re.I).lower()
        site_id = _js.slice16(host, 0, 56)
        n = 2
        while self._has_site(site_id):
            site_id = f"{_js.slice16(host, 0, 56)}-{n}"
            n += 1
        name = _js.slice16(_js.trim(_js.string(_or(input.get("name"), ""))), 0, 80)
        if not name:
            name = _js.string(there.get("name", _js.UNDEFINED))
        # No hostnames: tracker hits never land on a site that is counted elsewhere.
        timezone = there.get("timezone")
        site = {
            "id": site_id,
            "name": name,
            "hostnames": [],
            "timezone": timezone if isinstance(timezone, str) and is_timezone(timezone) else "UTC",
        }
        remote = {"url": url, "token": token, "site": there.get("id"), "hostnames": there_hostnames, "scope": scope}
        self.store.upsert_site(site, self.now())
        self.store.set_setting(f"remote:{site_id}", seal(_js.dumps(remote), self.secret))
        self._remotes[site_id] = remote
        self._configured = _by_name([*self._configured, site])
        return site

    def _has_site(self, site_id: str) -> bool:
        return any(site["id"] == site_id for site in self._configured)

    def add_site(self, input: Mapping[str, Any]) -> dict[str, Any]:
        """Adds a site, when sites are managed in the dashboard: one counted here, or one connected from another
        install."""
        from .time import is_timezone

        self.init()
        if not self.managed_sites:
            raise SettingsError("Sites are set in code", "sites_in_code")
        remote = input.get("remote")
        if isinstance(remote, dict):
            given = {k: v for k, v in remote.items() if k != "name"}
            if "name" in input:
                given["name"] = input["name"]
            return self._add_remote_site(given)
        hostnames = self._hostnames_for(input.get("hostnames"))
        name = _js.trim(_js.string(_or(input.get("name"), ""))) or hostnames[0]
        if _js.length(name) > 80:
            raise SettingsError("A site name is 1 to 80 characters", "site_name")
        timezone = _js.string(_or(input.get("timezone"), "UTC"))
        if not is_timezone(timezone):
            raise SettingsError(f'Unknown timezone "{timezone}"', "unknown_timezone", {"timezone": timezone})
        stem = re.sub(r"[^a-z0-9._-]", "-", hostnames[0])[:56]
        site_id = stem
        n = 2
        while self._has_site(site_id):
            site_id = f"{stem}-{n}"
            n += 1
        site = {"id": site_id, "name": name, "hostnames": hostnames, "timezone": timezone}
        self.store.upsert_site(site, self.now())
        self._configured = _by_name([*self._configured, site])
        return site

    def delete_site(self, site_id: str) -> None:
        """Deletes a site and everything recorded for it, when sites are managed in the dashboard."""
        self.init()
        if not self.managed_sites:
            raise SettingsError("Sites are set in code", "sites_in_code")
        if not self._has_site(site_id):
            raise SettingsError("Unknown site", "unknown_site")
        self.store.delete_site(site_id)
        self.store.set_setting(f"retention:{site_id}", None)
        self.store.set_setting(f"observe-key:{site_id}", None)
        self.store.set_setting(f"rollup-zone:{site_id}", None)
        self.store.set_setting(f"orphans-swept:{site_id}", None)
        # A site made again with the same id starts its Umami import from the beginning.
        for row in self.store.settings_starting_with(f"import:umami-visits:{site_id}:"):
            self.store.set_setting(row["key"], None)
        # A connected install keeps its own data; only the connection goes, and its token there with it.
        remote = self._remotes.get(site_id)
        if remote is not None:
            self._revoke_remote_token(remote)
            del self._remotes[site_id]
            self.store.set_setting(f"remote:{site_id}", None)
        self._configured = [site for site in self._configured if site["id"] != site_id]
        self._overrides.pop(site_id, None)

    def update_site(self, site_id: str, patch: Mapping[str, Any]) -> dict[str, Any]:
        """Changes a site's name or timezone from the dashboard. Stored apart from the settings in code, which keep
        being written on every start. A managed site has no settings in code, so its changes, hostnames too, go to
        its row. A key left out of `patch` is left alone, as TS's undefined is."""
        from .time import is_timezone

        self.init()
        current = next((site for site in self._configured if site["id"] == site_id), None)
        if current is None:
            raise SettingsError("Unknown site", "unknown_site")
        nxt = dict(current) if self.managed_sites else dict(self._overrides.get(site_id, {}))
        if "name" in patch and patch["name"] is not _js.UNDEFINED:
            name = _js.trim(_js.string(patch["name"]))
            if not name or _js.length(name) > 80:
                raise SettingsError("A site name is 1 to 80 characters", "site_name")
            nxt["name"] = name
        if "timezone" in patch and patch["timezone"] is not _js.UNDEFINED:
            timezone = _js.string(patch["timezone"])
            if not is_timezone(timezone):
                raise SettingsError(f'Unknown timezone "{timezone}"', "unknown_timezone", {"timezone": timezone})
            nxt["timezone"] = timezone
            if timezone != (self.site(site_id) or {}).get("timezone"):
                self._zone_changed(site_id, timezone)
        if self.managed_sites:
            if "hostnames" in patch and patch["hostnames"] is not _js.UNDEFINED and site_id not in self._remotes:
                nxt["hostnames"] = self._hostnames_for(patch["hostnames"], site_id)
            self.store.upsert_site(nxt, self.now())
            self._configured = [nxt if site["id"] == site_id else site for site in self._configured]
            return self.site(site_id)  # type: ignore[return-value]
        self.store.set_site_overrides(site_id, nxt)
        self._overrides[site_id] = nxt
        return self.site(site_id)  # type: ignore[return-value]

    # Retention

    def retention(self, site: str) -> int | None:
        """How many months of visits a site keeps, or None to keep everything (the default)."""
        value = _js.number(self.store.setting(f"retention:{site}"))
        return int(value) if value in RETENTION_MONTHS else None

    def set_retention(self, site: str, months: int | float | None) -> None:
        """Sets how many months of visits a site keeps. Deleting a long history takes a while, so it runs in pieces
        in idle(), after the answer, with tracking going on between them, as TS runs it after answering."""
        if self.site(site) is None or site in self._remotes:
            raise SettingsError("Unknown site", "unknown_site")
        if months is not None and months not in RETENTION_MONTHS:
            months_list = ", ".join(str(m) for m in RETENTION_MONTHS)
            raise SettingsError(f"Keep visits for {months_list} months, or forever", "retention_bad", {"months": months_list})
        self.store.set_setting(f"retention:{site}", None if months is None else _js.number_text(months))
        with self._pruning_lock:
            self._pruning.append(site)

    def idle(self) -> None:
        """Runs the work still waiting from earlier calls (a retention change's deletions); the scheduled check and
        tests wait for it."""
        while True:
            with self._pruning_lock:
                if not self._pruning:
                    return
                only = self._pruning.pop(0)
            try:
                self._apply_retention(only)
            except Exception as error:
                print(f"Runlight: could not apply retention {error}", file=sys.stderr)

    def _zone_changed(self, site_id: str, timezone: str) -> int:
        """Days are the site's local days, so a new timezone clears the built ones. Visitor ids recorded before the
        change were made per day of the old timezone, and could count one person twice in a new day, so only days
        that start after the change are built; earlier ones are always counted visit by visit."""
        since = self.now()
        self.store.clear_rollups(site_id)
        self.store.set_setting(f"rollup-zone:{site_id}", _js.dumps({"zone": timezone, "since": since}))
        return since

    def _rollup_since(self, site: Mapping[str, Any]) -> int | float | None:
        """Since when a site's days may be built: 0 for always, or when its timezone last changed. None when this
        process holds a different timezone than the one on record, such as an older copy still running during a
        deploy, or one that has not yet seen a change made in the dashboard. It builds nothing for that site, and
        reports read the visits themselves for any day not built, so nothing is wrong meanwhile."""
        stored = self.store.setting(f"rollup-zone:{site['id']}")
        if not stored:
            self.store.set_setting(f"rollup-zone:{site['id']}", _js.dumps({"zone": site["timezone"], "since": 0}))
            return 0
        zone = _js.loads(stored)
        return zone["since"] if zone["zone"] == site["timezone"] else None

    def build_rollups(self) -> int:
        """Adds up each site's finished days, so long ranges read a row a day instead of every visit. A day is built
        two hours after it ends in the site's timezone, once late engagement has landed, and at most ROLLUP_BATCH
        days a run, so a long history fills in over a few runs. Reports read the raw visits for any day not built
        yet, so the numbers are the same either way. Only a visit still going two hours past midnight, with no 30
        minute gap, could add to a day after it is built."""
        from .time import add_days, local_date, start_of

        # Days rolled up by an earlier way of counting are cleared once, and built again below.
        if self.store.setting("rollup-version") != str(ROLLUP_VERSION):
            for site in self.sites:
                self.store.clear_rollups(site["id"])
            self.store.set_setting("rollup-version", str(ROLLUP_VERSION))
        built = 0
        now = self.now()
        metered = getattr(self.store.db, "metered", False)
        if callable(metered):
            metered = metered()
        batch = METERED_ROLLUP_BATCH if metered else ROLLUP_BATCH
        for site in self.sites:
            if site["id"] in self._remotes:
                continue
            first = self.store.first_seen(site["id"])
            if first is None:
                continue
            cutoff = self.retention_cutoff(site["id"]) or 0
            since = self._rollup_since(site)
            if since is None:
                continue
            done = set(self.store.rollup_days(site["id"]))
            today = local_date(now, site["timezone"])
            oldest = local_date(int(max(first, cutoff)), site["timezone"])
            made = 0
            # Newest first, so recent ranges speed up before a long history is done.
            day = add_days(today, -1)
            while day >= oldest and made < batch:
                if day in done:
                    day = add_days(day, -1)
                    continue
                start = start_of(day, site["timezone"])
                end = start_of(add_days(day, 1), site["timezone"])
                if start < since:
                    break
                if now < end + ROLLUP_DELAY_MS or start < cutoff:
                    day = add_days(day, -1)
                    continue
                try:
                    self.store.build_rollup_day(site["id"], day, start, end)
                    made += 1
                except Exception as error:
                    # Another process building the same day at once loses nothing: the day is there either way.
                    if day not in set(self.store.rollup_days(site["id"])):
                        print(f"Runlight: could not add up {day} for {site['id']} {error}", file=sys.stderr)
                day = add_days(day, -1)
            built += made
        return built

    # The assistant

    def assistant_settings(self) -> dict[str, Any] | None:
        """The dashboard assistant's provider, model, and key, kept sealed like the mail keys. None until an owner
        sets it up."""
        from .mail.secret import unseal

        stored = self.store.setting("assistant")
        opened = unseal(stored, self.secret) if stored else None
        return _js.loads(opened) if opened else None

    def save_assistant_settings(self, input: Mapping[str, Any] | None) -> None:
        """Saves the assistant's settings; an empty key keeps the one saved for the same provider. None removes
        them."""
        from .assistant import PROVIDERS
        from .mail.secret import seal

        if not input:
            self.store.set_setting("assistant", None)
            return
        provider = next((p for p in PROVIDERS if p["id"] == input.get("provider")), None)
        if provider is None:
            raise SettingsError("Choose a provider", "assistant_provider")
        base_url = re.sub(r"/+\Z", "", _js.trim(_js.string(_or(input.get("baseUrl"), ""))))
        if base_url:
            parsed = Url.parse(base_url)
            if parsed is None or parsed.protocol not in ("https:", "http:"):
                raise SettingsError("Enter the service's address, starting with https://", "assistant_address_bad")
        if not base_url and not provider.get("baseUrl"):
            raise SettingsError("Enter the service's address", "assistant_address")
        model = _js.slice16(_js.trim(_js.string(_or(input.get("model"), ""))), 0, 200)
        if not model and not provider.get("model"):
            raise SettingsError("Enter the model to use", "assistant_model")
        before = self.assistant_settings()
        key = _js.trim(_js.string(_or(input.get("key"), "")))
        # A saved key is kept only for the same service at the same address, so it is never sent somewhere new.
        before_base = str((before or {}).get("baseUrl") or "")
        if (
            not key
            and before is not None
            and before.get("provider") == provider["id"]
            and (before_base or provider.get("baseUrl")) == (base_url or provider.get("baseUrl"))
        ):
            key = str(before.get("key") or "")
        if not key and provider.get("key") == "yes":
            raise SettingsError(f"Enter your {provider['name']} key", "assistant_key", {"provider": provider["name"]})
        settings = {"provider": provider["id"], "model": model, "baseUrl": base_url, "key": key}
        self.store.set_setting("assistant", seal(_js.dumps(settings), self.secret))

    def retention_cutoff(self, site: str) -> int | None:
        """The oldest moment a site keeps visits from, or None when it keeps everything."""
        months = self.retention(site)
        if months is None:
            return None
        # setUTCMonth: the same day and time that many months back, a day past the month's end running on.
        now = self.now()
        ms = now % 1000
        at = datetime.datetime(1970, 1, 1, tzinfo=datetime.UTC) + datetime.timedelta(seconds=(now - ms) // 1000)
        month_index = at.year * 12 + (at.month - 1) - months
        year, month0 = divmod(month_index, 12)
        start = datetime.datetime(year, month0 + 1, 1, tzinfo=datetime.UTC)
        back = start + datetime.timedelta(days=at.day - 1, hours=at.hour, minutes=at.minute, seconds=at.second)
        return int(back.timestamp()) * 1000 + ms

    def _apply_retention(self, only: str | None = None) -> None:
        """Deletes visits older than each site's retention allows. Cheap when there is nothing to delete."""
        for site in self.sites:
            if (only and site["id"] != only) or site["id"] in self._remotes:
                continue
            cutoff = self.retention_cutoff(site["id"])
            if cutoff is None:
                continue
            self.store.drop_before(site["id"], cutoff)
            # Earlier versions let an event join its visit days late, so retention could leave such an event behind
            # once its visit was gone. They are swept once; events can no longer join a visit that late.
            if not _js.truthy(self.store.setting(f"orphans-swept:{site['id']}")):
                self.store.drop_orphans(site["id"], cutoff, self.now())
                self.store.set_setting(f"orphans-swept:{site['id']}", "1")

    def site(self, site_id: str | None) -> dict[str, Any] | None:
        sites = self.sites
        if not site_id:
            return sites[0] if sites else None
        return next((site for site in sites if site["id"] == site_id), None)

    def site_for(self, hostname: str, site_id: str | None = None) -> dict[str, Any] | None:
        """The site a page belongs to, or None if it belongs to none."""
        from .sources import strip_www

        host = strip_www(hostname)
        # A site counted by another install never takes hits here.
        if self._remotes:
            local = [site for site in self.sites if site["id"] not in self._remotes]
            if site_id:
                return None if site_id in self._remotes else _site_for_among(local, host, site_id)
            return _site_for_among(local, host)
        return _site_for_among(self.sites, host, site_id)

    def _setup_site(self, hostname: str, site_id: str | None = None) -> dict[str, Any] | None:
        """A test from a developer's own machine while a site is being set up. A site with no visits yet accepts
        hits from localhost and .local or .test names, so the install screen confirms it works; after its first
        visit they are ignored again, so local browsing never mixes with real traffic."""
        host = re.sub(r"^\[|\]\Z", "", hostname.lower())
        if not (host in ("localhost", "127.0.0.1", "::1") or re.search(r"\.(localhost|local|test)\Z", host)):
            return None
        sites = self.sites
        site = self.site(site_id) if site_id else (sites[0] if len(sites) == 1 else None)
        if site is None or site["id"] in self._remotes:
            return None
        return site if self.store.last_seen(site["id"]) is None else None

    def client_ip(self, request: Request, context: Mapping[str, Any] | None = None) -> str:
        """The visitor's address, for the daily visitor hash and the rate limit. Behind a proxy it comes from a
        header. By default that is the last X-Forwarded-For entry, which the nearest proxy wrote and a client
        cannot choose (Vercel, Netlify, Cloudflare, Caddy, and nginx all append there), then X-Real-IP and
        CF-Connecting-IP. Naming one header (after another proxy in front, such as Cloudflare before nginx) reads
        only that one. Otherwise it is the connection's address: the context's `ip`, or else the request's own
        remote_address."""
        context = context or {}
        if self._trust_proxy is not False:
            h = request.headers

            def last(name: str) -> str | None:
                value = h.get(name)
                if value is None:
                    return None
                parts = [p for p in (_js.trim(x) for x in value.split(",")) if p]
                return parts[-1] if parts else None

            if self._trust_proxy is True:
                forwarded = last("x-forwarded-for")
                if forwarded is None:
                    forwarded = h.get("x-real-ip")
                if forwarded is None:
                    forwarded = h.get("cf-connecting-ip")
            elif self._trust_proxy == "x-forwarded-for":
                forwarded = last("x-forwarded-for")
            else:
                forwarded = h.get(str(self._trust_proxy))
            if forwarded is not None and _js.trim(forwarded):
                return _js.trim(forwarded)
        ip = context.get("ip")
        return str(ip) if ip is not None else request.remote_address

    def _current_salts(self, now: int, timezone: str) -> dict[str, Any]:
        """Today's salt in a site's timezone and, if it still exists, yesterday's. Salts follow the site's own days,
        as its reports do, so a visitor is one visitor for the whole of that site's day. Old salts go on the way."""
        from .hash import random_salt
        from .time import add_days, local_date

        day = local_date(now, timezone)
        cached = self._salts.get(timezone)
        if cached is not None and cached["day"] == day:
            return cached
        today = self.store.salt(day, random_salt())
        yesterday = self.store.salt_if_exists(add_days(day, -1))
        self._drop_old_salts(now)
        salts = {"day": day, "today": today, "yesterday": yesterday}
        self._salts[timezone] = salts
        return salts

    def _drop_old_salts(self, now: int) -> None:
        """Deletes salts whose day has ended everywhere. The earliest timezone is a day behind UTC and still needs
        its yesterday, so a salt goes two UTC days after its date."""
        self.store.drop_salts_before(_utc_day(now - 2 * 86_400_000))

    def _forwarded_host(self, request: Request) -> str | None:
        """The host a proxy says the request was for, read only when proxy headers are trusted, as the client's
        address is."""
        return request.headers.get("x-forwarded-host") if self._trust_proxy is not False else None

    # Tracking

    def collect(self, request: Request, context: Mapping[str, Any] | None = None) -> None:
        """Handles one tracker request. Bad input is dropped quietly; only a database that keeps failing raises."""
        from .payload import MAX_BODY, parse_payload
        from .ua import ai_agent, is_bot

        context = context or {}
        length = _js.number(_or(request.headers.get("content-length"), 0))
        if length > MAX_BODY:
            return
        # Read no more than a tracker hit can be, whatever the length header says (or when there is none).
        data = request.body()
        if len(data) > MAX_BODY:
            return
        payload = parse_payload(_js.utf8(data))
        if payload is None:
            return
        ua = request.headers.get("user-agent") or ""
        if ai_agent(ua) is not None or is_bot(ua):
            return
        if self._limit is not None and not self._limit.allow(self.client_ip(request, context)):
            return
        # A database too busy to take the hit right now (every pooled connection held by long reports, or another
        # process writing the SQLite file) gets it a little later, at the time it arrived.
        now = self.now()
        attempt = 1
        while True:
            try:
                self._record(payload, request, context, now)
                return
            except Exception as error:
                if attempt >= 3 or not _busy(error):
                    raise
                time.sleep(0.5 * attempt)
                attempt += 1

    def _record(self, payload: Mapping[str, Any], request: Request, context: Mapping[str, Any], now: int) -> None:
        from .sources import parse_page
        from .store import EVENT_TAIL_MS

        # Managed sites load from the database in init(), so it must come first.
        self.init()
        url = payload["url"]
        site = self.site_for(url.hostname, payload.get("site")) or self._setup_site(url.hostname, payload.get("site"))
        if site is None:
            return
        if payload["kind"] == "engagement":
            self._engagement(site, payload, now)
            return
        page = parse_page(url)
        session = None
        reopen = True
        if payload["kind"] == "event" and payload.get("pageviewId"):
            pageview = self.store.pageview(site["id"], payload["pageviewId"])
            # An event joins its page's visit unless that visit began longer ago than reports look for its rows (a
            # tab left open for days); it then starts a visit of its own, as any later activity would.
            if pageview is not None and now - pageview["startedAt"] < EVENT_TAIL_MS:
                session = {"id": pageview["session"], "visitor": pageview["visitor"]}
                # A visit idle past the 30 minutes stays ended: the event counts in it without reopening it.
                reopen = now - pageview["lastAt"] <= SESSION_IDLE_MS
                if now - pageview["startedAt"] > 3_600_000:
                    self.store.touched_old_visit(site["id"], int(pageview["startedAt"]), now - ROLLUP_DELAY_MS + 3_600_000)
        if session is None:
            width = payload.get("screenWidth")
            height = payload.get("screenHeight")
            screen = f"{_js.string(width)}x{_js.string(height)}" if _js.truthy(width) and _js.truthy(height) else ""
            session = self._session_for(
                site,
                request,
                context,
                page,
                payload.get("referrer", ""),
                now,
                {"screenWidth": width, "screen": screen, "language": payload.get("language", "")},
            )
        self.store.touch_session(session["id"], now, payload["kind"], page["path"], reopen)
        self.store.insert_event(
            {
                "site": site["id"],
                "ts": now,
                "kind": payload["kind"],
                "visitor": session["visitor"],
                "session": session["id"],
                "pageview": payload.get("pageviewId", ""),
                "path": page["path"],
                "hostname": page["hostname"],
                "title": payload.get("title", "") if payload["kind"] == "pageview" else "",
                "name": payload.get("name", "") if payload["kind"] == "event" else "",
                "props": payload.get("props"),
                "engagedMs": 0,
                "scroll": None,
                "link": "",
            }
        )

    def _session_for(
        self,
        site: Mapping[str, Any],
        request: Request,
        context: Mapping[str, Any],
        page: Mapping[str, Any],
        referrer: str,
        now: int,
        client: Mapping[str, Any],
    ) -> dict[str, str]:
        """The visitor's open session on a site, or a new one attributed to this request. Shared by tracker hits
        and short link clicks."""
        from .geo import locate
        from .hash import random_id, visitor_hash
        from .sources import attribute
        from .ua import parse_client

        ua = request.headers.get("user-agent") or ""
        ip = self.client_ip(request, context)
        salts = self._current_salts(now, site["timezone"])
        today = visitor_hash(salts["today"], site["id"], ip, ua)
        candidates = [today]
        if salts.get("yesterday"):
            candidates.append(visitor_hash(salts["yesterday"], site["id"], ip, ua))

        # One visitor's requests often arrive together (a pageview and the event right after it). Taking turns per
        # visitor means only the first opens a session and the rest find it, instead of each opening its own.
        def open_or_start() -> dict[str, str]:
            found = self.store.open_session(site["id"], candidates, now - SESSION_IDLE_MS)
            if found is not None:
                return found
            session = {"id": random_id(), "visitor": today}
            attribution = attribute(page, referrer, site["hostnames"])
            parsed = parse_client(
                ua,
                {
                    "brands": request.headers.get("sec-ch-ua"),
                    "mobile": request.headers.get("sec-ch-ua-mobile"),
                    "platform": request.headers.get("sec-ch-ua-platform"),
                },
                client.get("screenWidth"),
            )
            location = locate(request.headers, ip, self._geo)
            self.store.insert_session(
                {
                    "id": session["id"],
                    "site": site["id"],
                    "visitor": session["visitor"],
                    "startedAt": now,
                    "hostname": page["hostname"],
                    **attribution,
                    "utmSource": page["utm"]["source"],
                    "utmMedium": page["utm"]["medium"],
                    "utmCampaign": page["utm"]["campaign"],
                    "utmTerm": page["utm"]["term"],
                    "utmContent": page["utm"]["content"],
                    **location,
                    **parsed,
                    "screen": client["screen"],
                    "language": client["language"],
                }
            )
            return session

        return self._one_at_a_time(f"{site['id']}:{today}", open_or_start)

    def _one_at_a_time(self, key: str, fn: Callable[[], Any]) -> Any:
        """Runs `fn` after any earlier call with the same key has finished."""
        with self._turns_lock:
            entry = self._turns.get(key)
            if entry is None:
                entry = [threading.Lock(), 0]
                self._turns[key] = entry
            entry[1] += 1
        try:
            with entry[0]:
                return fn()
        finally:
            with self._turns_lock:
                entry[1] -= 1
                if entry[1] == 0 and self._turns.get(key) is entry:
                    del self._turns[key]

    # Links

    def _link_domain_set(self) -> set[str]:
        """The link domains, read at most every 30 seconds. Every request to a standalone server asks, so this saves
        a query on each tracker hit; a change made here clears it at once, one made by another process within half
        a minute."""
        now = self.now()
        cache = self._link_domain_cache
        if cache is not None and now - cache["at"] < 30_000:
            return cache["domains"]
        self.init()
        domains = {d["domain"] for d in self.store.link_domains()}
        self._link_domain_cache = {"at": now, "domains": domains}
        return domains

    def forget_link_domains(self) -> None:
        """Clears the cached link domains after one is added or removed."""
        self._link_domain_cache = None

    def link_handler(self) -> Callable[..., Response]:
        """Handles `{linkPath}/{slug}` on the app's own domain: a callable(request, context=None) giving a
        Response."""

        def handle(request: Request, context: Mapping[str, Any] | None = None) -> Response:
            path = Url(request.url).pathname
            slug = _decode(path[len(self.link_path) + 1 :]) if path.startswith(f"{self.link_path}/") else ""
            found = self.redirect(request, slug, "", context) if slug and "/" not in slug else None
            return found if found is not None else _not_found()

        return handle

    def link_domain_response(self, request: Request, context: Mapping[str, Any] | None = None) -> Response | None:
        """For middleware: when a request arrives on a link domain added in Settings (such as t.example.com),
        answers `/{slug}` there with the redirect, and anything else with a 404. None for every other host, so the
        app carries on as normal, and for the dashboard's own paths, so its owner can always reach it to remove the
        domain."""
        from .sources import strip_www

        url = Url(request.url)
        # A forwarded host only counts behind a proxy that sets it; otherwise any client could pick one.
        given = self._forwarded_host(request)
        if given is None:
            given = request.headers.get("host")
        if given is None:
            given = url.host
        host = strip_www(_js.trim(given.split(",")[0]).split(":")[0])
        if host not in self._link_domain_set():
            return None
        # Lets the dashboard confirm that requests to this domain reach Runlight.
        if url.pathname == LINK_DOMAIN_CHECK:
            return Response(
                _js.dumps({"runlight": True, "domain": host}),
                200,
                {"content-type": "application/json", "cache-control": "no-store"},
            )
        for base in self.route_bases or ["/runlight"]:
            if base != "/" and (url.pathname == base or url.pathname.startswith(f"{base}/")):
                return None
        slug = _decode(url.pathname[1:])
        found = self.redirect(request, slug, host, context) if slug and "/" not in slug else None
        return found if found is not None else _not_found()

    def redirect(
        self, request: Request, slug: str, domain: str, context: Mapping[str, Any] | None = None
    ) -> Response | None:
        """Answers a request for a short link: a redirect to its destination, with the click recorded like a visit
        (source, place, device, and any campaign tags on the short URL) but kept out of visitor and pageview
        counts. Bots are redirected and not counted. `domain` is the link domain the request came in on, or "" for
        the app's own link path, which answers for every link. None when no link fits."""
        from .sources import parse_page, strip_www
        from .ua import ai_agent, is_bot

        context = context or {}
        self.init()
        url = Url(request.url)
        given = self._forwarded_host(request)
        if given is None:
            given = request.headers.get("host")
        if given is None:
            given = url.host
        host = strip_www(given.split(":")[0])
        link = self.store.link_by_slug(slug)
        # The app's own link path answers for every link, so a link whose domain was removed keeps working; a link
        # domain answers only for its own links.
        if link is None or (domain != "" and link["domain"] != domain):
            return None
        sites = self.sites
        site = self.site(link["site"]) or (sites[0] if sites else None)
        ua = request.headers.get("user-agent") or ""
        if site is not None and ai_agent(ua) is None and not is_bot(ua) and request.method == "GET":
            try:
                now = self.now()
                first = (request.headers.get("accept-language") or "").split(",")[0].split(";")[0]
                language = _js.slice16(_js.trim(first), 0, 35)
                session = self._session_for(
                    site, request, context, parse_page(url), request.headers.get("referer") or "", now, {"screen": "", "language": language}
                )
                self.store.touch_session(session["id"], now, "click", url.pathname)
                self.store.insert_event(
                    {
                        "site": site["id"],
                        "ts": now,
                        "kind": "click",
                        "visitor": session["visitor"],
                        "session": session["id"],
                        "pageview": "",
                        "path": _js.slice16(url.pathname, 0, 1000),
                        "hostname": host,
                        "title": "",
                        "name": link["slug"],
                        "props": None,
                        "engagedMs": 0,
                        "scroll": None,
                        "link": link["id"],
                    }
                )
            except Exception as error:
                # A failed count must never break the redirect.
                print(f"Runlight: could not record a link click {error}", file=sys.stderr)
        return Response(
            "",
            302,
            {"location": link["url"], "cache-control": "no-store", "referrer-policy": "no-referrer-when-downgrade"},
        )

    def _engagement(self, site: Mapping[str, Any], payload: Mapping[str, Any], now: int) -> None:
        from .store import EVENT_TAIL_MS

        if payload["engagedMs"] <= 0:
            return
        pageview = self.store.pageview(site["id"], payload["pageviewId"])
        # Reports look for a visit's rows only so long after it began, so later time on it is let go.
        if pageview is None or now - pageview["startedAt"] >= EVENT_TAIL_MS:
            return
        self.store.add_engagement(pageview["session"], payload["engagedMs"])
        # Only a visit that began more than an hour ago can belong to a day that is already added up.
        if now - pageview["startedAt"] > 3_600_000:
            self.store.touched_old_visit(site["id"], int(pageview["startedAt"]), now - ROLLUP_DELAY_MS + 3_600_000)
        self.store.insert_event(
            {
                "site": site["id"],
                "ts": now,
                "kind": "engagement",
                "visitor": pageview["visitor"],
                "session": pageview["session"],
                "pageview": payload["pageviewId"],
                "path": pageview["path"],
                "hostname": pageview["hostname"],
                "title": "",
                "name": "",
                "props": None,
                "engagedMs": payload["engagedMs"],
                "scroll": payload.get("scroll"),
                "link": "",
            }
        )

    def observe(self, request: Request, at: int | float | None = None) -> bool:
        """Records a request from a known AI agent. Call it from middleware for every page request; it ignores
        everything else and never raises. Agents do not run JavaScript, so the tracker cannot see them."""
        from .sources import strip_www
        from .ua import ai_agent

        try:
            if request.method != "GET":
                return False
            agent = ai_agent(request.headers.get("user-agent") or "")
            if agent is None:
                return False
            url = Url(request.url)
            # Pages, not their assets.
            m = re.search(r"\.([a-z0-9]+)\Z", url.pathname, re.I)
            if m and m.group(1).lower() not in ("html", "htm", "md", "txt", "php"):
                return False
            host = self._forwarded_host(request)
            if host is None:
                host = request.headers.get("host")
            if host is None:
                host = url.hostname
            self.init()
            site = self.site_for(host.split(":")[0])
            if site is None:
                return False
            # A log reader sends when the page was served. Older than a week is dropped, so a first run over an old
            # log does not land as one spike on today; a time ahead of now counts as now.
            now = self.now()
            finite = at is not None and _js.is_finite(at)
            if finite and at < now - 7 * 86_400_000:  # type: ignore[operator]
                return False
            ts = int(math.floor(at)) if finite and at <= now else now  # type: ignore[operator, arg-type]
            self.store.insert_event(
                {
                    "site": site["id"],
                    "ts": ts,
                    "kind": "fetch",
                    "visitor": "",
                    "session": "",
                    "pageview": "",
                    "path": _js.slice16(url.pathname, 0, 1000),
                    "hostname": strip_www(url.hostname),
                    "title": "",
                    "name": agent["name"],
                    "props": {"company": agent["company"], "kind": agent["kind"]},
                    "engagedMs": 0,
                    "scroll": None,
                    "link": "",
                }
            )
            return True
        except Exception as error:
            # Analytics must never break the page it watches, but a failure should still be seen.
            print(f"Runlight: could not record an AI agent fetch {error}", file=sys.stderr)
            return False

    # The scheduled check

    def check(self) -> dict[str, Any]:
        """Scheduled upkeep, safe to run every minute. It rotates salts, sends the email reports that are due,
        deletes visits past each site's retention, and builds daily rollups. It also rereads sites, their dashboard
        settings, and connected installs, so a change made by another process sharing the database shows up here
        too. A check asked for while one is running in another thread shares its result; one asked for from inside
        it does nothing more."""
        with self._check_lock:
            running = self._checking
            mine = running is None
            if running is None:
                running = threading.Event()
                self._checking = running
                self._check_thread = threading.get_ident()
            elif self._check_thread == threading.get_ident():
                return {"ok": True, "reports": {"sent": 0, "failed": 0}}
        if not mine:
            running.wait()
            if self._check_result is None:
                raise RuntimeError("Runlight: the scheduled check failed")
            return self._check_result
        try:
            result = self._run_check()
            self._check_result = result
            return result
        except BaseException:
            self._check_result = None
            raise
        finally:
            with self._check_lock:
                self._checking = None
                self._check_thread = None
            running.set()

    def _run_check(self) -> dict[str, Any]:
        self.init()
        # Requests take a current schema version on trust; the scheduled check goes over every table and index.
        self.store.migrate(True)
        if self.managed_sites:
            self._configured = self.store.sites()
            self._load_remotes()
        # A name or timezone changed in the dashboard by another process reaches this one too.
        self._overrides = self.store.site_overrides()
        self._salts = {}
        for timezone in dict.fromkeys(site["timezone"] for site in self.sites):
            self._current_salts(self.now(), timezone)
        self._drop_old_salts(self.now())
        # Every site's retention covers any one site's that is still waiting.
        with self._pruning_lock:
            self._pruning = []
        try:
            self._apply_retention()
        except Exception as error:
            print(f"Runlight: could not apply retention {error}", file=sys.stderr)
        if self.now() - self._optimized_at >= 86_400_000:
            self._optimized_at = self.now()
            self.store.optimize()
        self.build_rollups()
        return {"ok": True, "reports": self.send_reports()}


def _site_for_among(sites: list[dict[str, Any]], host: str, site_id: str | None = None) -> dict[str, Any] | None:
    if site_id:
        site = next((s for s in sites if s["id"] == site_id), None)
        return site if site is not None and (not site["hostnames"] or host in site["hostnames"]) else None
    if len(sites) == 1:
        only = sites[0]
        return only if not only["hostnames"] or host in only["hostnames"] else None
    return next((site for site in sites if host in site["hostnames"]), None)


def _or(value: Any, fallback: Any) -> Any:
    """`value ?? fallback`."""
    return fallback if value is None or value is _js.UNDEFINED else value


def _not_found() -> Response:
    return Response("Not found", 404, {"content-type": "text/plain; charset=utf-8"})


class UriError(ValueError):
    """decodeURIComponent threw: URI malformed."""


def _decode(text: str) -> str:
    """decodeURIComponent, raising where it throws a URIError."""
    decoded = _js.decode_uri_component(text)
    if decoded is None:
        raise UriError("URI malformed")
    return decoded


def _json_or_none(answer: Response) -> Any:
    """A capped JSON body, or None where TS's readJsonCapped(...).catch(() => null) gives null."""
    from .body import read_json_capped

    try:
        return read_json_capped(answer, REMOTE_MAX_BYTES)
    except Exception:
        return None
