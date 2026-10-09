"""The MMDB reader against the small databases in tests/fixtures/geo.json, with what mmdb-lib reads from them and
what the server's lookupFrom makes of it. The parts of GeoTest that read databases."""

from __future__ import annotations

import base64
import os
import tempfile
from typing import Any

import pytest
from support import fixtures

from runlight import _js
from runlight.mmdb import Mmdb


def _lookup_from():
    """geo.lookup_from, once the geo module is there."""
    try:
        from runlight.geo import lookup_from
    except ImportError:
        return None
    return lookup_from


def test_mmdb() -> None:
    lookup_from = _lookup_from()
    for db in fixtures.load("geo")["databases"]:
        reader = Mmdb(base64.b64decode(db["base64"]))
        assert reader.metadata["ip_version"] == db["ipVersion"]
        assert reader.metadata["record_size"] == db["recordSize"]
        assert reader.metadata["build_epoch"] == 1759708800
        assert reader.metadata["description"] == {"en": "A test database"}
        lookup = lookup_from(reader) if lookup_from else None
        for case in db["records"]:
            label = f"{db['ipVersion']}/{db['recordSize']} {case['ip']}"
            assert reader.get(case["ip"]) == case["record"], label
            assert _js.dumps(reader.get(case["ip"])) == _js.dumps(case["record"]), label
            if lookup:
                assert lookup(case["ip"]) == case["location"], label


def test_a_file_is_read_a_page_at_a_time_with_the_same_answers() -> None:
    for db in fixtures.load("geo")["databases"]:
        handle, file = tempfile.mkstemp(prefix="rl-mmdb")
        os.write(handle, base64.b64decode(db["base64"]))
        os.close(handle)
        reader = Mmdb.open(file)
        try:
            assert reader.metadata["ip_version"] == db["ipVersion"]
            for case in db["records"]:
                assert _js.dumps(reader.get(case["ip"])) == _js.dumps(case["record"]), f"{db['ipVersion']}/{db['recordSize']} {case['ip']}"
        finally:
            reader.close()
            os.unlink(file)
    with pytest.raises(OSError):
        Mmdb.open(os.path.join(tempfile.gettempdir(), "no-such-runlight.mmdb"))


def test_text_that_is_no_address_is_refused() -> None:
    reader = Mmdb(base64.b64decode(fixtures.load("geo")["databases"][0]["base64"]))
    with pytest.raises(ValueError):
        reader.get("nonsense")
    with pytest.raises(ValueError):
        Mmdb(b"not a database")


def test_a_real_database_when_one_is_given() -> None:
    file = os.environ.get("RUNLIGHT_TEST_MMDB", "")
    if not file:
        pytest.skip("Set RUNLIGHT_TEST_MMDB to an MMDB file to read a real database.")
    reader: Any = Mmdb.open(file)
    assert reader.get("8.8.8.8") is not None
    assert reader.get("127.0.0.1") is None
