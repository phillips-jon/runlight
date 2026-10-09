"""The MMDB reader against the small databases in tests/fixtures/geo.json, with what mmdb-lib reads from them and
what the server's lookupFrom makes of it. The parts of GeoTest that read databases."""

from __future__ import annotations

import base64
import gzip
import os
import tempfile
from typing import Any

import pytest
from support import fixtures
from support.fake_fetcher import FakeFetcher

from runlight import _js
from runlight.mmdb import Mmdb
from runlight.http import Response
from runlight.server.dbip import DbIp, city_name, file_lookup, lookup_from, month


def test_mmdb() -> None:
    for db in fixtures.load("geo")["databases"]:
        reader = Mmdb(base64.b64decode(db["base64"]))
        assert reader.metadata["ip_version"] == db["ipVersion"]
        assert reader.metadata["record_size"] == db["recordSize"]
        assert reader.metadata["build_epoch"] == 1759708800
        assert reader.metadata["description"] == {"en": "A test database"}
        lookup = lookup_from(reader)
        for case in db["records"]:
            label = f"{db['ipVersion']}/{db['recordSize']} {case['ip']}"
            assert reader.get(case["ip"]) == case["record"], label
            assert _js.dumps(reader.get(case["ip"])) == _js.dumps(case["record"]), label
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


def test_db_ip_records_become_a_country_code_a_readable_region_and_a_plain_city() -> None:
    records = {
        "24.114.0.1": {"country": {"iso_code": "CA"}, "subdivisions": [{"names": {"en": "Ontario"}}], "city": {"names": {"en": "Toronto (Old Toronto)"}}},
        "8.8.8.8": {"country": {"iso_code": "US"}, "subdivisions": [{"iso_code": "CA", "names": {"en": "California"}}], "city": {"names": {"en": "Mountain View"}}},
        "10.0.0.1": None,
    }

    class Records:
        def get(self, ip: str) -> Any:
            return records.get(ip)

    class Broken:
        def get(self, ip: str) -> Any:
            raise ValueError("bad address")

    lookup = lookup_from(Records())
    assert lookup("24.114.0.1") == {"country": "CA", "region": "Ontario", "city": "Toronto"}
    assert lookup("8.8.8.8") == {"country": "US", "region": "CA", "city": "Mountain View"}, "a code wins when the database has one"
    assert lookup("10.0.0.1") is None
    assert lookup_from(Broken())("nonsense") is None


def test_db_ip_opens_what_is_on_disk_downloads_this_months_release_or_last_months_and_keeps_only_the_newest(tmp_path: Any) -> None:
    data = base64.b64decode(fixtures.load("geo")["databases"][0]["base64"])

    def answer(url: str, init: dict[str, Any]) -> Response:
        return Response("", 404) if "2026-10" in url else Response(gzip.compress(data), 200)

    fetcher = FakeFetcher(answer)
    said: list[str] = []
    dbip = DbIp(str(tmp_path / "geo"), "city", said.append, fetcher)
    assert dbip.lookup("8.8.8.8") is None, "nothing to read before the first download"
    now = 1_791_288_000_000
    assert month(now) == "2026-10"
    (tmp_path / "geo" / "dbip-city-lite-2026-08.mmdb").write_bytes(data)
    dbip.refresh(now)
    assert [r["url"] for r in fetcher.requests] == [
        "https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz",
        "https://download.db-ip.com/free/dbip-city-lite-2026-09.mmdb.gz",
    ]
    assert said == ["Runlight: location data from DB-IP (2026-09) is ready."]
    assert sorted(os.listdir(tmp_path / "geo")) == ["dbip-city-lite-2026-09.mmdb"], "older releases go"
    assert dbip.lookup("8.8.8.8") == {"country": "US", "region": "CA", "city": "Mountain View"}

    # Last month's file is open, so a later refresh in the same month only looks for this month's again.
    dbip.refresh(now + 60_000)
    assert len(fetcher.requests) == 3

    # A new process opens the newest file on disk before it fetches anything.
    other = DbIp(str(tmp_path / "geo"), "city", said.append, FakeFetcher(lambda url, init: Response("", 404)))
    other.refresh(now)
    assert other.lookup("8.8.8.8") == {"country": "US", "region": "CA", "city": "Mountain View"}

    # A download that is no database is never kept.
    broken = DbIp(str(tmp_path / "geo"), "country", said.append, FakeFetcher(lambda url, init: Response(gzip.compress(b"not a database"), 200)))
    broken.refresh(now)
    assert said[-1].startswith("Runlight: could not download location data from https://download.db-ip.com/free/dbip-country-lite-2026-09.mmdb.gz")
    assert sorted(os.listdir(tmp_path / "geo")) == ["dbip-city-lite-2026-09.mmdb"]
    assert broken.lookup("8.8.8.8") is None


def test_a_file_the_owner_gives_is_looked_up(tmp_path: Any) -> None:
    file = tmp_path / "own.mmdb"
    file.write_bytes(base64.b64decode(fixtures.load("geo")["databases"][0]["base64"]))
    assert file_lookup(str(file))("8.8.8.8") == {"country": "US", "region": "CA", "city": "Mountain View"}
    assert city_name("Toronto (Old Toronto)") == "Toronto"
    assert city_name("Boxford ( West Berkshire )") == "Boxford"
