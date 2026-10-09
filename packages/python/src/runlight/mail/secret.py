"""Keys kept in the database (the mail service's, the AI Assistant's, and the tokens for connected
installs) are encrypted with AES-GCM, under a key derived from a secret only the server has:
`RUNLIGHT_SECRET`, or else the dashboard token. A copied database alone does not give them away.
The label says "mail" because mail came first; changing it would make every saved key unreadable.

The sealed form is Web Crypto's: base64 of the 12 byte IV, and base64 of the ciphertext followed
by its 16 byte tag, so every implementation opens what another sealed.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import secrets

from .. import _aesgcm, _js


def _key_for(secret: str) -> bytes:
    return hashlib.sha256(_js.encode(f"runlight-mail:{secret}")).digest()


def _from_base64(text: str) -> bytes:
    """atob(): white space skipped, padding optional, and anything else that is not base64 refused."""
    from ..accounts.crypto import from_base64url

    if "-" in text or "_" in text:
        raise ValueError("The string to be decoded is not correctly encoded.")
    return from_base64url(text)


def seal(value: str, secret: str | None) -> str:
    """`v1:<iv>:<ciphertext>`, or `plain:<json>` when the server has no secret to encrypt with."""
    if not secret:
        return f"plain:{value}"
    iv = secrets.token_bytes(12)
    data = _aesgcm.encrypt(_key_for(secret), iv, _js.encode(value))
    return f"v1:{base64.b64encode(iv).decode('ascii')}:{base64.b64encode(data).decode('ascii')}"


def unseal(sealed: str, secret: str | None) -> str | None:
    """The sealed value, or None when it cannot be opened (a different secret, or damaged)."""
    if sealed.startswith("plain:"):
        return sealed[6:]
    parts = sealed.split(":")
    version = parts[0]
    iv = parts[1] if len(parts) > 1 else ""
    data = parts[2] if len(parts) > 2 else ""
    if version != "v1" or not iv or not data or not secret:
        return None
    try:
        nonce = _from_base64(iv)
        # Web Crypto refuses an AES-GCM IV under 12 bytes, so such a value opens nowhere.
        if len(nonce) < 12:
            return None
        plain = _aesgcm.decrypt(_key_for(secret), nonce, _from_base64(data))
    except (ValueError, binascii.Error):
        return None
    return _js.utf8(plain)
