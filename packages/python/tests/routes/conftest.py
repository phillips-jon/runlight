from __future__ import annotations

import pytest

from support.routes import clear_env


@pytest.fixture(autouse=True)
def _no_env():
    """Nothing in the environment counts: each test names its token, cron secret, and observe key."""
    with clear_env():
        yield
