"""The tracker's rate limit: per address, per minute, never holding an address."""

from __future__ import annotations

from runlight.limit import RateLimit


def test_each_address_gets_its_own_count_per_minute() -> None:
    clock = [60_000 * 1000]
    limit = RateLimit(2, lambda: clock[0])
    assert [limit.allow("1.2.3.4") for _ in range(3)] == [True, True, False]
    assert limit.allow("5.6.7.8")
    clock[0] += 59_999
    assert not limit.allow("1.2.3.4")
    clock[0] += 1
    assert limit.allow("1.2.3.4")


def test_no_address_is_not_limited() -> None:
    limit = RateLimit(1, lambda: 0)
    assert all(limit.allow("") for _ in range(5))


def test_the_counts_never_hold_an_address() -> None:
    limit = RateLimit(5, lambda: 0)
    limit.allow("203.0.113.9")
    assert "203.0.113.9" not in repr(limit.__dict__)
    assert all(len(key) == 16 for key in limit._counts)
