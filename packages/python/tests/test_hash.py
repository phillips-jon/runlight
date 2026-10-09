"""Hashes as Web Crypto writes them, over UTF-8 text."""

from __future__ import annotations

import re

from runlight.hash import hmac, random_id, random_salt, sha256, visitor_hash


def test_sha256_and_hmac_are_hex_of_the_utf8_bytes() -> None:
    assert sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    assert sha256("café") == "850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e"
    assert hmac("key", "The quick brown fox jumps over the lazy dog") == (
        "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
    )
    # A lone surrogate is hashed as U+FFFD, as TextEncoder writes it.
    assert sha256("\ud800") == sha256("�")


def test_the_visitor_hash_is_64_bits_of_the_joined_fields() -> None:
    assert visitor_hash("s", "site", "1.2.3.4", "UA") == sha256("s\nsite\n1.2.3.4\nUA")[:16]
    assert len(visitor_hash("s", "site", "1.2.3.4", "UA")) == 16


def test_random_ids() -> None:
    assert re.fullmatch(r"[0-9a-f]{24}", random_id())
    assert re.fullmatch(r"[0-9a-f]{64}", random_salt())
    assert random_id() != random_id()
