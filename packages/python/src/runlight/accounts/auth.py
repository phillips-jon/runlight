"""Accounts: who may sign in, their password hashes, two-factor, invites, and the signed cookie that keeps them
signed in. The standalone server always has them, and an app turns them on with routes({"accounts": True}).

A user is a dict with the TypeScript User's keys: id, email, hash, role ("owner", "admin", "member", or
"viewer"), createdAt, twoFactor (whether sign-in also asks for a code), and recoveryLeft (recovery codes not yet
used). An invite has id, email, role, invitedBy, createdAt, and expiresAt.
"""

from __future__ import annotations

import re
import struct
from collections.abc import Callable
from typing import TYPE_CHECKING, Any, TypeVar

from .. import _js
from .crypto import (
    base64url,
    check_password,
    hash_password,
    hex,
    hmac,
    random_bytes,
    same_text,
    seal_text,
    sha256,
    unseal_text,
)

if TYPE_CHECKING:
    from ..store import SqlStore

__all__ = [
    "INVITE_MS",
    "MIN_PASSWORD",
    "SESSION_COOKIE",
    "SESSION_MS",
    "AccountError",
    "Accounts",
    "Throttle",
    "base32",
    "check_password",
    "hash_password",
    "otpauth_uri",
    "totp",
]

T = TypeVar("T")


class AccountError(_js.RangeError):
    """A problem with an account change, to show the person making it. A RangeError in TypeScript, with a `code`
    and `params` the dashboard words in its own language."""

    def __init__(self, message: str, code: str, params: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = {} if params is None else params


SESSION_COOKIE = "runlight_session"
# Thirty days, renewed on every sign-in.
SESSION_MS = 30 * 86_400_000
MIN_PASSWORD = 10
# The most sign-in keys the throttle remembers at once.
MAX_THROTTLED = 10_000

# The owner can do everything, and nobody else can remove them or change their role; they can hand ownership to
# an admin. An admin can do everything the owner can apart from that. A member changes sites, goals, links, and
# the rest, but not people, the mail service, the assistant's settings, or deleting a site. A viewer reads every
# site's stats and changes nothing.
ROLES = ("owner", "admin", "member", "viewer")


def role_from(value: Any) -> str:
    """A stored role read back; anything unknown reads as a viewer, the least it could be."""
    return value if isinstance(value, str) and value in ROLES else "viewer"


# Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.
STEP_MS = 30_000
BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"


def base32(data: bytes) -> str:
    bits = 0
    value = 0
    out = []
    for byte in data:
        # Only the low bits are ever read, so the rest are dropped before they grow.
        value = ((value << 8) | byte) & 0xFFFF
        bits += 8
        while bits >= 5:
            out.append(BASE32[(value >> (bits - 5)) & 31])
            bits -= 5
    if bits > 0:
        out.append(BASE32[(value << (5 - bits)) & 31])
    return "".join(out)


def unbase32(text: str) -> bytes:
    """Bytes from base32, skipping anything that is not a base32 letter, as authenticator apps' secrets come."""
    bits = 0
    value = 0
    out = bytearray()
    for c in re.sub(r"=+\Z", "", text).upper():
        i = BASE32.find(c)
        if i < 0:
            continue
        value = ((value << 5) | i) & 0xFFFF
        bits += 5
        if bits >= 8:
            out.append((value >> (bits - 8)) & 255)
            bits -= 8
    return bytes(out)


def totp(secret: str, step: int) -> str:
    """The six-digit code for a secret at a time step. Raises ValueError for a secret with no base32 letters, as
    Web Crypto refuses an empty key."""
    mac = hmac("SHA-1", unbase32(secret), struct.pack(">Q", step))
    at = mac[-1] & 15
    n = ((mac[at] & 127) << 24) | (mac[at + 1] << 16) | (mac[at + 2] << 8) | mac[at + 3]
    return str(n % 1_000_000).rjust(6, "0")


def otpauth_uri(secret: str, email: str, host: str) -> str:
    """The address an authenticator app reads from the QR code."""
    label = _js.encode_uri_component(f"Runlight ({host}):{email}")
    issuer = _js.encode_uri_component(f"Runlight ({host})")
    return f"otpauth://totp/{label}?secret={secret}&issuer={issuer}&algorithm=SHA1&digits=6&period=30"


def recovery_codes() -> list[str]:
    """Ten one-use recovery codes, like "k7dq-2mfa"."""
    codes = []
    for _ in range(10):
        raw = base32(random_bytes(5)).lower()
        codes.append(f"{raw[0:4]}-{raw[4:8]}")
    return codes


def recovery_hash(code: str) -> str:
    """What a recovery code is kept as: SHA-256 of its letters and digits in lower case, so dashes and case do not
    matter."""
    return hex(sha256(re.sub(r"[^a-z0-9]", "", code, flags=re.I | re.ASCII).lower()))


def match_step(secret: str, code: str, now: int, after: int) -> int | None:
    """The time step a code matches, one step either side for clocks that drift, newer than `after`; else None."""
    current = int(now // STEP_MS)
    for step in (current, current - 1, current + 1):
        if step > after and totp(secret, step) == code:
            return step
    return None


def signature(secret: str, body: str, hash: str) -> str:  # noqa: A002
    """The signature on a session, sign-in, or device value: HMAC-SHA-256 of "body.hash" under the install's
    secret."""
    return base64url(hmac("SHA-256", secret, f"{body}.{hash}"))


# What passes for an email address, with JavaScript's \s.
_NOT_EMAIL = f"[^{_js.WHITESPACE}@<>\"]+"
EMAIL = re.compile(f"{_NOT_EMAIL}@{_NOT_EMAIL}\\.{_NOT_EMAIL}\\Z")

# How long an invite link works.
INVITE_MS = 7 * 86_400_000

_INVITE_CODE = re.compile(r"[A-Za-z0-9_-]{20,64}\Z")
_SIX_DIGITS = re.compile(r"[0-9]{6}\Z")


def _code_hash(code: str) -> str:
    return hex(sha256(code))


def _recovery_list(value: Any) -> list[str]:
    return _js.loads(_js.string(value)) if _js.truthy(value) else []


class Accounts:
    # A password checked against nothing, so a wrong email takes as long as a wrong password. Made when first
    # needed.
    _decoy: str | None = None

    def __init__(self, store: SqlStore, secret: str) -> None:
        self.store = store
        self.secret = secret
        self._ready = False

    def _turn(self, fn: Callable[[], T]) -> T:
        """Changes to who has an account take turns, across threads and, on Postgres and MySQL, across processes,
        through the database's lock, so two owners demoting each other at once cannot leave none, and a
        double-clicked invite makes one."""
        return self.store.db.exclusive(lambda _db: fn())

    def _init(self) -> None:
        if self._ready:
            return
        from ..store import MYSQL_COLLATION

        # Several processes starting at once create the tables one at a time.
        def create(_db: Any) -> None:
            db = self.store.db
            # MySQL keys TEXT only by a prefix, so there the keyed columns are VARCHAR, in the binary collation the
            # store's tables use.
            my = db.dialect() == "mysql"

            def text(n: int) -> str:
                return f"VARCHAR({n})" if my else "TEXT"

            table = f" DEFAULT CHARSET=utf8mb4 COLLATE={MYSQL_COLLATION}" if my else ""
            db.run(
                f"CREATE TABLE IF NOT EXISTS rl_users (id {text(100)} PRIMARY KEY, email {text(320)} NOT NULL UNIQUE, "
                f"hash TEXT NOT NULL, created_at BIGINT NOT NULL){table}"
            )
            # Roles came later; a table from before them gains the column, and its accounts stay owners.
            columns = (
                db.all("PRAGMA table_info(rl_users)")
                if db.dialect() == "sqlite"
                else db.all(
                    "SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' "
                    f"AND table_schema = {'DATABASE()' if my else 'current_schema()'}"
                )
            )
            names = [_js.string(c.get("name", c.get("NAME", ""))) for c in columns]
            if "role" not in names:
                db.run(f"ALTER TABLE rl_users ADD COLUMN role {text(20)} NOT NULL DEFAULT 'owner'")
            # Two-factor came later still: the secret (sealed), one being set up, recovery code hashes, and the last
            # code's step.
            for name, kind in (("totp_secret", "TEXT"), ("totp_pending", "TEXT"), ("totp_recovery", "TEXT"), ("totp_step", "BIGINT")):
                if name not in names:
                    db.run(f"ALTER TABLE rl_users ADD COLUMN {name} {kind}")
            db.run(
                f"CREATE TABLE IF NOT EXISTS rl_invites (id {text(100)} PRIMARY KEY, email {text(320)} NOT NULL UNIQUE, "
                f"role {text(20)} NOT NULL, code_hash {text(128)} NOT NULL UNIQUE, invited_by {text(100)} NOT NULL, "
                f"created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL){table}"
            )
            # A server has one owner. One from before, with several, keeps the first and the rest become admins,
            # who can still do everything but remove the owner. Invites to join as an owner become invites as an
            # admin.
            owners = db.all("SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id")
            for extra in owners[1:]:
                db.run("UPDATE rl_users SET role = 'admin' WHERE id = ?", [_js.string(extra["id"])])
            db.run("UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'")

        self.store.db.exclusive(create)
        self._ready = True

    def _row(self, r: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": _js.string(r["id"]),
            "email": _js.string(r["email"]),
            "hash": _js.string(r["hash"]),
            "role": role_from(r.get("role")),
            "createdAt": _js.number(r["created_at"]),
            "twoFactor": _js.truthy(r.get("totp_secret")),
            "recoveryLeft": len(_recovery_list(r.get("totp_recovery"))),
        }

    def _seal(self, text: str) -> str:
        """Seals a two-factor secret with the install's secret, so the database alone cannot make codes."""
        return seal_text(text, self.secret)

    def _unseal(self, sealed: str) -> str | None:
        return unseal_text(sealed, self.secret)

    def _first(self, sql: str, params: list[Any]) -> dict[str, Any] | None:
        rows = self.store.db.all(sql, params)
        return rows[0] if rows else None

    def start_two_factor(self, id: str) -> str:  # noqa: A002
        """Starts turning on two-factor: a new secret, kept aside until a code from it is confirmed."""
        self._init()
        secret = base32(random_bytes(20))
        self.store.db.run("UPDATE rl_users SET totp_pending = ? WHERE id = ?", [self._seal(secret), id])
        return secret

    def confirm_two_factor(self, id: str, code: str, now: int) -> list[str] | None:  # noqa: A002
        """Turns two-factor on once a code from the new secret checks out, and returns ten recovery codes, shown
        once."""
        self._init()
        row = self._first("SELECT totp_pending FROM rl_users WHERE id = ?", [id])
        secret = self._unseal(_js.string(row["totp_pending"])) if row is not None and _js.truthy(row.get("totp_pending")) else None
        step = match_step(secret, code, now, -1) if secret else None
        if step is None:
            return None
        recovery = recovery_codes()
        # The code that turned it on is not marked used, so signing in again at once with it works.
        self.store.db.run(
            "UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?",
            [self._seal(secret), _js.dumps([recovery_hash(c) for c in recovery]), id],
        )
        return recovery

    def new_recovery_codes(self, id: str) -> list[str]:  # noqa: A002
        """New recovery codes in place of the old ones."""
        self._init()
        recovery = recovery_codes()
        self.store.db.run("UPDATE rl_users SET totp_recovery = ? WHERE id = ?", [_js.dumps([recovery_hash(c) for c in recovery]), id])
        return recovery

    def cancel_two_factor_setup(self, id: str) -> None:  # noqa: A002
        """Drops a set-up left half done, after too many wrong codes, so it must start again with the password."""
        self._init()
        self.store.db.run("UPDATE rl_users SET totp_pending = NULL WHERE id = ?", [id])

    def disable_two_factor(self, id: str) -> None:  # noqa: A002
        self._init()
        self.store.db.run(
            "UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?", [id]
        )

    def check_second_factor(self, id: str, code: str, now: int) -> bool:  # noqa: A002
        """Checks a six-digit code, or a recovery code, for an account with two-factor on.
        A code works once: one already used, or older, is refused, and a recovery code is crossed off.
        One check at a time, so two sign-ins at once cannot both use the same code: TypeScript queues them per
        account in its process, and this takes the database's lock, which holds across threads and processes."""
        self._init()
        return self._turn(lambda: self._check_second_factor_now(id, code, now))

    def _check_second_factor_now(self, id: str, code: str, now: int) -> bool:  # noqa: A002
        row = self._first("SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?", [id])
        if row is None or not _js.truthy(row.get("totp_secret")):
            return False
        given = _js.trim(code)
        digits = _js.SPACE.sub("", given)
        if _SIX_DIGITS.match(digits):
            secret = self._unseal(_js.string(row["totp_secret"]))
            after = -1 if row.get("totp_step") is None else int(_js.number(row["totp_step"]))
            step = match_step(secret, digits, now, after) if secret else None
            if step is None:
                return False
            self.store.db.run("UPDATE rl_users SET totp_step = ? WHERE id = ?", [step, id])
            return True
        hashes = _recovery_list(row.get("totp_recovery"))
        wanted = recovery_hash(given)
        if wanted not in hashes:
            return False
        hashes.remove(wanted)
        self.store.db.run("UPDATE rl_users SET totp_recovery = ? WHERE id = ?", [_js.dumps(hashes), id])
        return True

    def pending_for(self, user: dict[str, Any], now: int) -> str:
        """A short-lived ticket naming an account whose password checked out and
        which still owes a code. Signed like a session, so it cannot be made up."""
        return self._ticket("pending", user, now + 5 * 60_000)

    def decoy_for(self, user: dict[str, Any], now: int) -> str:
        """A ticket that looks and acts like pending_for's, except that no code ever
        passes with it. A wrong password gets one once an account with
        two-factor has had too many, so the answer never tells a right password."""
        return self._ticket("decoy", user, now + 5 * 60_000)

    def from_pending(self, value: str, now: int) -> dict[str, Any] | None:
        """The account a code-step ticket names, and whether a right code may sign in with it: {user, real}."""
        user = self._from_ticket("pending", value, now)
        if user is not None:
            return {"user": user, "real": True}
        decoy = self._from_ticket("decoy", value, now)
        return {"user": decoy, "real": False} if decoy is not None else None

    def link_for(self, user: dict[str, Any], now: int) -> str:
        """A ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it."""
        return self._ticket("link", user, now + 15 * 60_000)

    def from_link(self, value: str, now: int) -> dict[str, Any] | None:
        """The account a sign-in link is for. A link works once: using it withdraws it, and every link sent
        before it. Uses take turns, so a link opened twice at once lets one in."""
        user = self._from_ticket("link", value, now)
        if user is None:
            return None
        expires = _js.number(value.split(".")[1])

        def use() -> dict[str, Any] | None:
            key = f"login-link-used:{user['id']}"
            used = self.store.setting(key)
            if expires <= _js.number(0 if used is None else used):
                return None
            self.store.set_setting(key, _js.string(expires))
            return user

        return self._turn(use)

    def _ticket(self, kind: str, user: dict[str, Any], expires: int) -> str:
        body = f"{user['id']}.{_js.string(expires)}"
        return f"{body}.{self._sign(f'{kind}.{body}', user['hash'])}"

    def _from_ticket(self, kind: str, value: str, now: int) -> dict[str, Any] | None:
        parts = value.split(".")
        id_ = parts[0]
        expires = parts[1] if len(parts) > 1 else ""
        signed = parts[2] if len(parts) > 2 else ""
        if not id_ or not expires or not signed or not (_js.number(expires) > now):
            return None
        user = self.by_id(id_)
        if user is None:
            return None
        return user if same_text(self._sign(f"{kind}.{id_}.{expires}", user["hash"]), signed) else None

    def count(self) -> int:
        self._init()
        row = self._first("SELECT COUNT(*) AS n FROM rl_users", [])
        return int(_js.number(row["n"] if row is not None else 0))

    def by_email(self, email: str) -> dict[str, Any] | None:
        self._init()
        row = self._first("SELECT * FROM rl_users WHERE email = ?", [_js.lower(_js.trim(email))])
        return self._row(row) if row is not None else None

    def by_id(self, id: str) -> dict[str, Any] | None:  # noqa: A002
        self._init()
        row = self._first("SELECT * FROM rl_users WHERE id = ?", [id])
        return self._row(row) if row is not None else None

    def list(self) -> list[dict[str, Any]]:
        self._init()
        return [self._row(r) for r in self.store.db.all("SELECT * FROM rl_users ORDER BY created_at, id")]

    def _find(self, id: str) -> dict[str, Any] | None:  # noqa: A002
        return next((u for u in self.list() if u["id"] == id), None)

    def set_role(self, id: str, role: str) -> dict[str, Any]:  # noqa: A002
        """Changes a role. The owner's never changes here, and nobody becomes the owner here: see hand_over()."""
        # The tables first: making them takes the same lock as a turn.
        self._init()

        def change() -> dict[str, Any]:
            user = self._find(id)
            if user is None:
                raise AccountError("Unknown account", "unknown_account")
            if user["role"] == "owner":
                raise AccountError("Only the owner can change their own role, by handing ownership to an admin", "owner_protected")
            if role == "owner":
                raise AccountError("Ownership is handed over by the owner", "owner_hand_over")
            self.store.db.run("UPDATE rl_users SET role = ? WHERE id = ?", [role, id])
            return {**user, "role": role}

        return self._turn(change)

    def hand_over(self, from_: str, to: str) -> None:
        """Makes an admin the owner, and the owner an admin."""
        self._init()

        def change() -> None:
            owner = self._find(from_)
            nxt = self._find(to)
            if owner is None or owner["role"] != "owner":
                raise AccountError("Only the owner can hand over ownership", "owner_hand_over")
            if nxt is None:
                raise AccountError("Unknown account", "unknown_account")
            if nxt["role"] != "admin":
                raise AccountError("Make them an admin first", "owner_needs_admin")
            self.store.db.run("UPDATE rl_users SET role = 'owner' WHERE id = ?", [to])
            self.store.db.run("UPDATE rl_users SET role = 'admin' WHERE id = ?", [from_])

        self._turn(change)

    def remove(self, id: str) -> None:  # noqa: A002
        """Removes an account. The owner cannot be removed."""
        # The tables first: making them takes the same lock as a turn.
        self._init()

        def change() -> None:
            user = self._find(id)
            if user is None:
                raise AccountError("Unknown account", "unknown_account")
            if user["role"] == "owner":
                raise AccountError("The owner cannot be removed", "owner_protected")
            self.store.db.run("DELETE FROM rl_users WHERE id = ?", [id])
            self.store.set_setting(f"login-link-used:{id}", None)

        self._turn(change)

    def set_password(self, email: str, password: str, now: int, role: str | None = None) -> dict[str, Any]:
        """Makes an account, or sets a new password on an existing one. A new account is the owner when it is the
        first, and otherwise an admin unless a role is given, since a server has one owner."""
        self._init()
        address = _js.lower(_js.trim(email))
        if not EMAIL.match(address):
            raise AccountError("Enter an email address", "email_invalid")
        # The length in UTF-16 units, as TypeScript counts it.
        if _js.length(password) < MIN_PASSWORD:
            raise AccountError(f"Use a password of at least {MIN_PASSWORD} characters", "password_short", {"min": str(MIN_PASSWORD)})
        hashed = hash_password(password)
        existing = self.by_email(address)
        if existing is not None:
            self.store.db.run("UPDATE rl_users SET hash = ? WHERE id = ?", [hashed, existing["id"]])
            return {**existing, "hash": hashed}
        first = self.count() == 0
        given = role if role is not None else ("owner" if first else "admin")
        user = {
            "id": hex(random_bytes(12)),
            "email": address,
            "hash": hashed,
            "role": "admin" if given == "owner" and not first else given,
            "createdAt": now,
            "twoFactor": False,
            "recoveryLeft": 0,
        }
        self.store.db.run(
            "INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)",
            [user["id"], user["email"], user["hash"], user["role"], user["createdAt"]],
        )
        return user

    def _invite_row(self, r: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": _js.string(r["id"]),
            "email": _js.string(r["email"]),
            "role": role_from(r.get("role")),
            "invitedBy": _js.string(r["invited_by"]),
            "createdAt": _js.number(r["created_at"]),
            "expiresAt": _js.number(r["expires_at"]),
        }

    def invites(self, now: int) -> list[dict[str, Any]]:
        """Invites that still work, newest first. Expired ones are cleared on the way."""
        self._init()
        self.store.db.run("DELETE FROM rl_invites WHERE expires_at <= ?", [now])
        return [self._invite_row(r) for r in self.store.db.all("SELECT * FROM rl_invites ORDER BY created_at DESC, id")]

    def invite(self, email: str, role: str, invited_by: str, now: int) -> dict[str, Any]:
        """Invites someone to join with a role, and returns {invite, code}, the code for their link.
        Asking again replaces the earlier invite, so only the newest link works."""
        self._init()
        return self._turn(lambda: self._invite_now(email, role, invited_by, now))

    def _invite_now(self, email: str, role: str, invited_by: str, now: int) -> dict[str, Any]:
        address = _js.lower(_js.trim(email))
        if not EMAIL.match(address):
            raise AccountError("Enter an email address", "email_invalid")
        if self.by_email(address) is not None:
            raise AccountError(f"{address} already has an account", "account_exists", {"email": address})
        code = base64url(random_bytes(24))
        invite = {"id": hex(random_bytes(12)), "email": address, "role": role, "invitedBy": invited_by, "createdAt": now, "expiresAt": now + INVITE_MS}
        self.store.db.run("DELETE FROM rl_invites WHERE email = ?", [address])
        self.store.db.run(
            "INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [invite["id"], invite["email"], invite["role"], _code_hash(code), invite["invitedBy"], invite["createdAt"], invite["expiresAt"]],
        )
        return {"invite": invite, "code": code}

    def invite_by_code(self, code: str, now: int) -> dict[str, Any] | None:
        """The invite a link's code belongs to, while it still works."""
        self._init()
        if not _INVITE_CODE.match(code):
            return None
        row = self._first("SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?", [_code_hash(code), now])
        return self._invite_row(row) if row is not None else None

    def cancel_invite(self, id: str) -> bool:  # noqa: A002
        self._init()
        before = len(self.store.db.all("SELECT id FROM rl_invites WHERE id = ?", [id]))
        self.store.db.run("DELETE FROM rl_invites WHERE id = ?", [id])
        return before > 0

    def accept_invite(self, code: str, password: str, now: int) -> dict[str, Any]:
        """Turns an invite into an account with the password its person chose. The link then stops working."""
        invite = self.invite_by_code(code, now)
        if invite is None:
            raise AccountError("This invite has expired or was already used. Ask for a new one.", "invite_gone")
        if self.by_email(invite["email"]) is not None:
            raise AccountError(f"{invite['email']} already has an account", "account_exists", {"email": invite["email"]})
        user = self.set_password(invite["email"], password, now, invite["role"])
        self.store.db.run("DELETE FROM rl_invites WHERE id = ?", [invite["id"]])
        return user

    def sign_in(self, email: str, password: str) -> dict[str, Any] | None:
        """The account for an email and password, or None. Takes the same time either way."""
        user = self.by_email(email)
        if user is None:
            if Accounts._decoy is None:
                Accounts._decoy = hash_password(hex(random_bytes(16)))
            check_password(password, Accounts._decoy)
            return None
        return user if check_password(password, user["hash"]) else None

    def session_for(self, user: dict[str, Any], now: int) -> str:
        """A cookie value naming the user and when it expires, signed with the
        server's secret and the user's password hash, so changing a password
        signs out every other browser."""
        expires = now + SESSION_MS
        body = f"{user['id']}.{_js.string(expires)}"
        return f"{body}.{self._sign(body, self._session_key(user))}"

    def from_session(self, value: str, now: int) -> dict[str, Any] | None:
        """The signed-in user for a cookie value, or None."""
        parts = value.split(".")
        id_ = parts[0]
        expires = parts[1] if len(parts) > 1 else ""
        signed = parts[2] if len(parts) > 2 else ""
        if not id_ or not expires or not signed or not (_js.number(expires) > now):
            return None
        user = self.by_id(id_)
        if user is None:
            return None
        return user if same_text(self._sign(f"{id_}.{expires}", self._session_key(user)), signed) else None

    def _session_key(self, user: dict[str, Any]) -> str:
        """What a session is signed with: the password hash, and whether two-factor is on, so changing either ends
        other sessions."""
        return f"{user['hash']}{'.2fa' if user['twoFactor'] else ''}"

    def device_for(self, user: dict[str, Any]) -> str:
        """A long-lived mark for a browser that signed in to an account. With it, failed tries by others
        against that account cannot lock this browser out; the per-address limit still applies.
        A new password withdraws it."""
        return f"{user['id']}." + self._sign(f"device.{user['id']}", user["hash"])

    def trusts_device(self, value: str, user: dict[str, Any]) -> bool:
        parts = value.split(".")
        id_ = parts[0]
        signed = parts[1] if len(parts) > 1 else ""
        if id_ != user["id"] or not signed:
            return False
        return same_text(self._sign(f"device.{user['id']}", user["hash"]), signed)

    def _sign(self, body: str, hash: str) -> str:  # noqa: A002
        return signature(self.secret, body, hash)


class Throttle:
    """Counts failed sign-ins under a key and refuses more than a few in a while.
    Keys are hashed with a key made on first use, so the counts never hold an
    address or an email as it was given.

    TypeScript keeps the counts in its process. A Python app often runs several
    worker processes, so here they live in the database's settings, as the PHP
    port keeps them: "throttle:<name>:<id>" holding {count, until}, and the
    hashing key as "throttle-key". Every process of an install then shares the
    same counts, and the two ports read each other's."""

    _KEY = "throttle-key"

    def __init__(self, store: SqlStore, name: str, limit: int = 10, window_ms: int = 15 * 60_000) -> None:
        self.store = store
        self.name = name
        self.limit = limit
        self.window_ms = window_ms

    def _salt(self) -> str:
        saved = self.store.setting(self._KEY)
        if saved:
            return saved
        from ..hash import random_id

        made = random_id(16)
        self.store.set_setting(self._KEY, made)
        return made

    def _id(self, key: str) -> str:
        return base64url(hmac("SHA-256", self._salt(), key))[:22]

    def _prefix(self) -> str:
        return f"throttle:{self.name}:"

    def _entry(self, id_: str) -> dict[str, int] | None:
        saved = self.store.setting(self._prefix() + id_)
        ok, entry = _js.try_loads(saved) if saved is not None else (False, None)
        if not ok or not isinstance(entry, dict):
            return None
        return {"count": int(_js.number(entry.get("count", 0))), "until": int(_js.number(entry.get("until", 0)))}

    def _save(self, id_: str, entry: dict[str, int]) -> None:
        self.store.set_setting(self._prefix() + id_, _js.dumps(entry))

    def blocked(self, key: str, now: int) -> bool:
        return self._is_blocked(self._id(key), now)

    def _is_blocked(self, id_: str, now: int) -> bool:
        entry = self._entry(id_)
        if entry is None or entry["until"] <= now:
            return False
        return entry["count"] >= self.limit

    def take(self, key: str, now: int) -> bool:
        """Counts a try before the slow check it guards, so a burst that arrives
        while earlier tries are still being checked cannot get past the limit.
        False, counting nothing, when the key is already at its limit. A try
        that turns out right is taken back with forgive()."""
        id_ = self._id(key)
        if self._is_blocked(id_, now):
            return False
        self._count(id_, now)
        return True

    def forgive(self, key: str) -> None:
        """Takes back one counted try, for one that turned out right."""
        id_ = self._id(key)
        entry = self._entry(id_)
        if entry is not None and entry["count"] > 0:
            entry["count"] -= 1
            self._save(id_, entry)

    def fail(self, key: str, now: int) -> None:
        self._count(self._id(key), now)

    def _count(self, id_: str, now: int) -> None:
        entry = self._entry(id_)
        if entry is None or entry["until"] <= now:
            self._save(id_, {"count": 1, "until": now + self.window_ms})
            self._prune(now)
            return
        entry["count"] += 1
        self._save(id_, entry)

    def _prune(self, now: int) -> None:
        """Expired entries go first, then the oldest that are not blocked, and blocked ones last, so the counts
        have a hard ceiling and a flood of made-up names cannot wipe out a real block. Run when a new entry is
        made, since only then can there be more."""
        entries = []
        for setting in self.store.settings_starting_with(self._prefix()):
            ok, entry = _js.try_loads(setting["value"])
            until = int(_js.number(entry.get("until", 0))) if ok and isinstance(entry, dict) else 0
            if until <= now:
                self.store.set_setting(setting["key"], None)
                continue
            count = int(_js.number(entry.get("count", 0))) if isinstance(entry, dict) else 0
            entries.append({"key": setting["key"], "until": until, "blocked": count >= self.limit})
        size = len(entries)
        if size <= MAX_THROTTLED:
            return
        # Oldest first: each entry's window started window_ms before its end.
        entries.sort(key=lambda e: e["until"])
        for blocked in (False, True):
            for entry in entries:
                if size <= MAX_THROTTLED:
                    return
                if entry["blocked"] is blocked:
                    self.store.set_setting(entry["key"], None)
                    size -= 1

    def clear(self, key: str) -> None:
        self.store.set_setting(self._prefix() + self._id(key), None)
