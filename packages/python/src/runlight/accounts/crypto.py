"""The cryptography accounts need. Passwords use scrypt, as the standalone server always has, through
hashlib.scrypt, which gives the same bytes as Node's; a PBKDF2 hash made on an edge runtime checks out too.

Bytes are Python bytes throughout, and text going in is encoded as TextEncoder does.
"""

from __future__ import annotations

import base64
import hashlib
import hmac as _hmac
import re
import secrets
from typing import Literal

from .. import _aesgcm, _js

SCRYPT = {"N": 16384, "r": 8, "p": 1, "maxmem": 64 * 1024 * 1024}

# As many PBKDF2 rounds as Cloudflare Workers allow, the strictest runtime Runlight runs on.
PBKDF2_ROUNDS = 100_000

# The shortest stored key accepted. Ours are 32 bytes; an empty or cut key would match too easily, or anything.
MIN_KEY_BYTES = 16


def random_bytes(length: int) -> bytes:
    return secrets.token_bytes(length)


def base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


_BASE64 = re.compile(r"[A-Za-z0-9+/]*\Z")


def from_base64url(text: str) -> bytes:
    """Bytes from base64url (or plain base64), read as atob() reads them: white space is skipped, padding is
    optional, and anything else that is not base64 raises ValueError, where atob() throws."""
    plain = re.sub(r"[\t\n\f\r ]", "", text.replace("-", "+").replace("_", "/"))
    if len(plain) % 4 == 0:
        plain = re.sub(r"={1,2}\Z", "", plain)
    if len(plain) % 4 == 1 or not _BASE64.match(plain):
        raise ValueError("The string to be decoded is not correctly encoded.")
    return base64.b64decode(plain + "=" * (-len(plain) % 4))


def hex(data: bytes) -> str:  # noqa: A001 - the TS name
    return data.hex()


def _bytes_of(value: str | bytes) -> bytes:
    return _js.encode(value) if isinstance(value, str) else bytes(value)


def sha256(value: str | bytes) -> bytes:
    return hashlib.sha256(_bytes_of(value)).digest()


def hmac(hash: Literal["SHA-1", "SHA-256"], key: str | bytes, data: str | bytes) -> bytes:  # noqa: A002
    raw = _bytes_of(key)
    if not raw:
        # Web Crypto will not import an empty HMAC key (a DataError).
        raise ValueError("An HMAC key must not be empty")
    return _hmac.new(raw, _bytes_of(data), hashlib.sha1 if hash == "SHA-1" else hashlib.sha256).digest()


def same_text(a: str, b: str) -> bool:
    """Compares two strings in time that does not depend on where they differ."""
    return _hmac.compare_digest(_js.encode(a), _js.encode(b))


def scrypt(password: str, salt: bytes, n: int, r: int, p: int, length: int) -> bytes:
    """scrypt as Node's crypto.scrypt gives it, the password as UTF-8. Raises ValueError for a cost Node refuses."""
    if length == 0:
        return b""
    return hashlib.scrypt(_js.encode(password), salt=salt, n=n, r=r, p=p, maxmem=SCRYPT["maxmem"], dklen=length)


def _run_scrypt(password: str, salt: bytes, length: int) -> bytes:
    return scrypt(password, salt, SCRYPT["N"], SCRYPT["r"], SCRYPT["p"], length)


def _pbkdf2(password: str, salt: bytes, rounds: int, length: int) -> bytes:
    return b"" if length == 0 else hashlib.pbkdf2_hmac("sha256", _js.encode(password), salt, rounds, length)


def hash_password(password: str) -> str:
    """A password hash, in the scrypt form the standalone server has always written."""
    salt = random_bytes(16)
    return f"scrypt${base64url(salt)}${base64url(_run_scrypt(password, salt, 32))}"


def check_password(password: str, stored: str) -> bool:
    """Whether a password matches a hash, scrypt or PBKDF2. A hash whose salt or key is not base64url matches
    nothing, as the TypeScript answers then."""
    parts = stored.split("$")

    def decode(text: str) -> bytes | None:
        try:
            return from_base64url(text)
        except ValueError:
            return None

    if parts[0] == "scrypt" and len(parts) == 3:
        expected = decode(parts[2])
        salt = decode(parts[1])
        if expected is None or salt is None or len(expected) < MIN_KEY_BYTES:
            return False
        return _same_bytes(_run_scrypt(password, salt, len(expected)), expected)
    if parts[0] == "pbkdf2" and len(parts) == 4:
        rounds = _js.number(parts[1])
        if not _js.is_integer(rounds) or rounds < 1 or rounds > 10_000_000:
            return False
        expected = decode(parts[3])
        salt = decode(parts[2])
        if expected is None or salt is None or len(expected) < MIN_KEY_BYTES:
            return False
        return _same_bytes(_pbkdf2(password, salt, int(rounds), len(expected)), expected)
    return False


def _same_bytes(a: bytes, b: bytes) -> bool:
    return _hmac.compare_digest(a, b)


def _seal_key(secret: str) -> bytes:
    return sha256(f"totp:{secret}")


def seal_text(text: str, secret: str, iv: bytes | None = None) -> str:
    """Seals text with AES-256-GCM under a key from the secret, as "iv.body.tag" in base64url, the form the
    standalone server has always stored two-factor secrets in. `iv` is for tests; leave it out."""
    iv = random_bytes(12) if iv is None else iv
    out = _aesgcm.encrypt(_seal_key(secret), iv, _js.encode(text))
    return f"{base64url(iv)}.{base64url(out[:-16])}.{base64url(out[-16:])}"


def unseal_text(sealed: str, secret: str) -> str | None:
    try:
        parts = sealed.split(".")
        iv = parts[0]
        body = parts[1] if len(parts) > 1 else None
        tag = parts[2] if len(parts) > 2 else None
        if not iv or body is None or not tag:
            return None
        # Web Crypto reads the tag as the last 16 bytes of body and tag together, wherever the dot fell.
        joined = from_base64url(body) + from_base64url(tag)
        return _js.utf8(_aesgcm.decrypt(_seal_key(secret), from_base64url(iv), joined))
    except ValueError:
        return None
