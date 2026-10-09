"""Shared by every test: the process timezone is UTC, as the fixtures were made in, and the databases the store
and conformance tests run on.

SQLite in memory always. Postgres when RUNLIGHT_TEST_PG is set: a connection URL, or anything else (such as 1)
for postgres://joncphillips@127.0.0.1:5432/runlight_test_python; each test gets a schema of its own, dropped
after. MySQL 8.4 and MariaDB 11.4 when RUNLIGHT_TEST_MYSQL is set: URLs separated by spaces or commas, or
anything else for the two local test servers. MySQL has no schemas inside a database, so each test empties the
database of Runlight's tables first; those tests never run in parallel."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

os.environ["TZ"] = "UTC"
time.tzset()

sys.path.insert(0, str(Path(__file__).parent))

import pytest  # noqa: E402

from support.databases import Databases  # noqa: E402


@pytest.fixture
def databases():
    dbs = Databases()
    yield dbs
    dbs.cleanup()
