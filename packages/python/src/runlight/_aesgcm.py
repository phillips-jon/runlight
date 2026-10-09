"""AES-GCM, as Web Crypto's AES-GCM seals and opens: the ciphertext with its 16 byte tag at the end.

The standard library has no AES, so this uses the `cryptography` package's AESGCM when it is installed, and
otherwise a plain Python AES and GHASH. Runlight seals short things (two-factor secrets, a mail service's keys,
an assistant's key), so the plain one is quick enough, and both give the same bytes.
"""

from __future__ import annotations

try:  # pragma: no cover - depends on what is installed
    from cryptography.exceptions import InvalidTag as _InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM as _AESGCM
except ImportError:  # pragma: no cover
    _AESGCM = None
    _InvalidTag = None


class InvalidTag(ValueError):
    """The ciphertext, IV, or key is not the one sealed: Web Crypto rejects with an OperationError then."""


def encrypt(key: bytes, iv: bytes, data: bytes, aad: bytes = b"") -> bytes:
    """The ciphertext followed by its 16 byte tag."""
    _check(key, iv)
    if _AESGCM is not None:
        return _AESGCM(key).encrypt(iv, data, aad or None)
    return _Gcm(key).seal(iv, data, aad)


def decrypt(key: bytes, iv: bytes, data: bytes, aad: bytes = b"") -> bytes:
    """The plaintext. Raises InvalidTag when the tag does not check out."""
    _check(key, iv)
    if len(data) < 16:
        raise InvalidTag("The data is shorter than its tag")
    if _AESGCM is not None:
        try:
            return _AESGCM(key).decrypt(iv, data, aad or None)
        except _InvalidTag:  # type: ignore[misc]
            raise InvalidTag("The tag does not match") from None
    return _Gcm(key).open(iv, data, aad)


def _check(key: bytes, iv: bytes) -> None:
    if len(key) not in (16, 24, 32):
        raise ValueError("An AES key is 16, 24, or 32 bytes")
    # Node's Web Crypto refuses an IV under 12 bytes.
    if len(iv) < 12:
        raise ValueError("An AES-GCM IV is at least 12 bytes")


# AES (FIPS 197), with the round function in four tables of 32-bit words.

_SBOX: list[int] = []
_T0: list[int] = []
_T1: list[int] = []
_T2: list[int] = []
_T3: list[int] = []


def _tables() -> None:
    def xtime(a: int) -> int:
        a <<= 1
        return a ^ 0x11B if a & 0x100 else a

    # Powers and logs of 3 in GF(2^8), for the inverses.
    exp = [0] * 256
    log = [0] * 256
    x = 1
    for i in range(255):
        exp[i] = x
        log[x] = i
        x ^= xtime(x)
    for a in range(256):
        inv = 0 if a == 0 else exp[(255 - log[a]) % 255]
        s = inv
        for shift in range(1, 5):
            s ^= ((inv << shift) | (inv >> (8 - shift))) & 0xFF
        _SBOX.append(s ^ 0x63)
    for s in _SBOX:
        s2 = xtime(s)
        s3 = s2 ^ s
        word = (s2 << 24) | (s << 16) | (s << 8) | s3
        _T0.append(word)
        _T1.append(((word >> 8) | (word << 24)) & 0xFFFFFFFF)
        _T2.append(((word >> 16) | (word << 16)) & 0xFFFFFFFF)
        _T3.append(((word >> 24) | (word << 8)) & 0xFFFFFFFF)


_tables()


def _expand(key: bytes) -> list[int]:
    nk = len(key) // 4
    rounds = nk + 6
    words = [int.from_bytes(key[i * 4 : i * 4 + 4], "big") for i in range(nk)]
    rcon = 1
    sbox = _SBOX
    for i in range(nk, 4 * (rounds + 1)):
        t = words[i - 1]
        if i % nk == 0:
            t = ((t << 8) | (t >> 24)) & 0xFFFFFFFF
            t = (sbox[t >> 24] << 24) | (sbox[(t >> 16) & 255] << 16) | (sbox[(t >> 8) & 255] << 8) | sbox[t & 255]
            t ^= rcon << 24
            rcon <<= 1
            if rcon & 0x100:
                rcon ^= 0x11B
        elif nk > 6 and i % nk == 4:
            t = (sbox[t >> 24] << 24) | (sbox[(t >> 16) & 255] << 16) | (sbox[(t >> 8) & 255] << 8) | sbox[t & 255]
        words.append(words[i - nk] ^ t)
    return words


def _encrypt_block(w: list[int], block: int) -> int:
    """One 128-bit block, as an integer, through AES with the expanded key `w`."""
    t0, t1, t2, t3, sbox = _T0, _T1, _T2, _T3, _SBOX
    a = (block >> 96) ^ w[0]
    b = ((block >> 64) & 0xFFFFFFFF) ^ w[1]
    c = ((block >> 32) & 0xFFFFFFFF) ^ w[2]
    d = (block & 0xFFFFFFFF) ^ w[3]
    rounds = len(w) // 4 - 1
    k = 4
    for _ in range(rounds - 1):
        a, b, c, d = (
            t0[a >> 24] ^ t1[(b >> 16) & 255] ^ t2[(c >> 8) & 255] ^ t3[d & 255] ^ w[k],
            t0[b >> 24] ^ t1[(c >> 16) & 255] ^ t2[(d >> 8) & 255] ^ t3[a & 255] ^ w[k + 1],
            t0[c >> 24] ^ t1[(d >> 16) & 255] ^ t2[(a >> 8) & 255] ^ t3[b & 255] ^ w[k + 2],
            t0[d >> 24] ^ t1[(a >> 16) & 255] ^ t2[(b >> 8) & 255] ^ t3[c & 255] ^ w[k + 3],
        )
        k += 4

    def last(p: int, q: int, r: int, s: int, key: int) -> int:
        return ((sbox[p >> 24] << 24) | (sbox[(q >> 16) & 255] << 16) | (sbox[(r >> 8) & 255] << 8) | sbox[s & 255]) ^ key

    return (last(a, b, c, d, w[k]) << 96) | (last(b, c, d, a, w[k + 1]) << 64) | (last(c, d, a, b, w[k + 2]) << 32) | last(d, a, b, c, w[k + 3])


# GCM (NIST SP 800-38D).

_R = 0xE1 << 120
_MASK = (1 << 128) - 1


class _Gcm:
    def __init__(self, key: bytes) -> None:
        self.w = _expand(key)
        h = _encrypt_block(self.w, 0)
        # H times x^i for i in 0..127, so a product is the XOR of the rows its bits pick.
        rows = []
        v = h
        for _ in range(128):
            rows.append(v)
            v = (v >> 1) ^ _R if v & 1 else v >> 1
        self.rows = rows

    def _mul(self, x: int) -> int:
        out = 0
        rows = self.rows
        for i in range(128):
            if x >> (127 - i) & 1:
                out ^= rows[i]
        return out

    def _ghash(self, aad: bytes, data: bytes) -> int:
        y = 0
        for part in (aad, data):
            for at in range(0, len(part), 16):
                y = self._mul(y ^ int.from_bytes(part[at : at + 16].ljust(16, b"\0"), "big"))
        return self._mul(y ^ ((len(aad) * 8) << 64) ^ (len(data) * 8))

    def _j0(self, iv: bytes) -> int:
        if len(iv) == 12:
            return (int.from_bytes(iv, "big") << 32) | 1
        return self._ghash(b"", iv)

    def _ctr(self, j0: int, data: bytes) -> bytes:
        out = bytearray()
        counter = j0
        for at in range(0, len(data), 16):
            counter = (counter & ~0xFFFFFFFF) | ((counter + 1) & 0xFFFFFFFF)
            stream = _encrypt_block(self.w, counter).to_bytes(16, "big")
            chunk = data[at : at + 16]
            out += (int.from_bytes(chunk, "big") ^ int.from_bytes(stream[: len(chunk)], "big")).to_bytes(len(chunk), "big")
        return bytes(out)

    def _tag(self, j0: int, aad: bytes, ciphertext: bytes) -> bytes:
        return ((_encrypt_block(self.w, j0) ^ self._ghash(aad, ciphertext)) & _MASK).to_bytes(16, "big")

    def seal(self, iv: bytes, data: bytes, aad: bytes) -> bytes:
        j0 = self._j0(iv)
        ciphertext = self._ctr(j0, data)
        return ciphertext + self._tag(j0, aad, ciphertext)

    def open(self, iv: bytes, data: bytes, aad: bytes) -> bytes:
        ciphertext, tag = data[:-16], data[-16:]
        j0 = self._j0(iv)
        expected = self._tag(j0, aad, ciphertext)
        diff = 0
        for x, y in zip(expected, tag):
            diff |= x ^ y
        if diff:
            raise InvalidTag("The tag does not match")
        return self._ctr(j0, ciphertext)
