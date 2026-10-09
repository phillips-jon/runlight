"""The plain Python AES-GCM against bytes Node's Web Crypto made (tests/fixtures/aesgcm.json, from
scripts/python-fixtures-crypto.mts), which open with the GCM specification's own test cases."""

from __future__ import annotations

import pytest
from support import fixtures

from runlight import _aesgcm

CASES = fixtures.own("aesgcm")["cases"]


def test_the_gcm_specifications_aes_256_vectors():
    # Test cases 13 and 14 of McGrew and Viega's GCM specification.
    assert CASES[0]["sealed"] == "530f8afbc74536b9a963b4f1c4cb738b"
    assert CASES[1]["sealed"] == "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919"


@pytest.mark.parametrize("backend", ["plain", "default"])
def test_seals_and_opens_as_node_does(backend, monkeypatch):
    if backend == "plain":
        monkeypatch.setattr(_aesgcm, "_AESGCM", None)
    for case in CASES:
        key, iv, plain = bytes.fromhex(case["key"]), bytes.fromhex(case["iv"]), bytes.fromhex(case["plain"])
        aad = bytes.fromhex(case.get("aad", ""))
        sealed = bytes.fromhex(case["sealed"])
        assert _aesgcm.encrypt(key, iv, plain, aad) == sealed, case
        assert _aesgcm.decrypt(key, iv, sealed, aad) == plain
        broken = bytearray(sealed)
        broken[len(broken) // 2] ^= 1
        with pytest.raises(_aesgcm.InvalidTag):
            _aesgcm.decrypt(key, iv, bytes(broken), aad)


def test_refuses_what_web_crypto_refuses():
    for case in fixtures.own("aesgcm")["refused"]:
        assert case["ok"] is False
        with pytest.raises(ValueError):
            _aesgcm.encrypt(bytes(32), bytes.fromhex(case["iv"]), b"abcd")
    with pytest.raises(_aesgcm.InvalidTag):
        _aesgcm.decrypt(bytes(32), bytes(12), bytes(15))
    with pytest.raises(ValueError):
        _aesgcm.encrypt(bytes(31), bytes(12), b"")
