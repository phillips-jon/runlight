"""SHA-256, HMAC, the day's visitor hash, and random ids, all as hex. Text is hashed as its UTF-8 bytes, as
TextEncoder writes it (a lone surrogate as U+FFFD)."""

from __future__ import annotations

import hashlib
import hmac as _hmac
import secrets

from . import _js


def sha256(text: str) -> str:
    return hashlib.sha256(_js.encode(text)).hexdigest()


def hmac(key: str, text: str) -> str:
    """HMAC-SHA-256 of text under key, as hex."""
    return _hmac.new(_js.encode(key), _js.encode(text), hashlib.sha256).hexdigest()


def visitor_hash(salt: str, site: str, ip: str, ua: str) -> str:
    """The day's visitor hash: SHA-256 of salt, site, IP, and user agent, cut to
    64 bits. The salt changes every day and old salts are deleted, so the hash
    cannot be recomputed and does not follow anyone across days."""
    return sha256(f"{salt}\n{site}\n{ip}\n{ua}")[:16]


def random_id(bytes: int = 12) -> str:
    return secrets.token_hex(bytes)


def random_salt() -> str:
    return random_id(32)
