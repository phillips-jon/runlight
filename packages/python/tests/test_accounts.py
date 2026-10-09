"""Accounts and the throttle on their own, on every database at hand (PHP tests/Accounts/AccountsTest.php)."""

from __future__ import annotations

import re

import pytest
from support.databases import kinds

from runlight import _js
from runlight.accounts.auth import INVITE_MS, SESSION_MS, AccountError, Accounts, Throttle, signature, totp
from runlight.store import SqlStore, Stores

NOW = 1_791_288_000_000
SECRET = "k" * 64


def fresh(databases, kind: str) -> SqlStore:
    store = Stores.from_db(databases.db(kind))
    store.migrate()
    return store


def code_of(fn) -> str:
    try:
        fn()
        return ""
    except AccountError as error:
        return error.code


@pytest.mark.parametrize("kind", kinds())
def test_the_first_account_owns_and_the_rest_are_admins_unless_asked(databases, kind):
    accounts = Accounts(fresh(databases, kind), SECRET)
    assert accounts.count() == 0
    owner = accounts.set_password(" Jon@Example.com ", "a long password", NOW)
    assert list(owner) == ["id", "email", "hash", "role", "createdAt", "twoFactor", "recoveryLeft"]
    assert owner["email"] == "jon@example.com"
    assert owner["role"] == "owner"
    assert re.fullmatch(r"[a-f0-9]{24}", owner["id"])
    admin = accounts.set_password("ada@example.com", "another long one", NOW + 1, "owner")
    assert admin["role"] == "admin", "a server has one owner"
    assert [u["email"] for u in accounts.list()] == ["jon@example.com", "ada@example.com"]
    assert accounts.by_id(owner["id"]) == owner
    assert accounts.sign_in("JON@example.com", "a long password")["id"] == owner["id"]
    assert accounts.sign_in("jon@example.com", "a wrong password") is None
    assert accounts.sign_in("nobody@example.com", "a long password") is None

    assert code_of(lambda: accounts.set_password("not an email", "a long password", NOW)) == "email_invalid"
    with pytest.raises(AccountError) as caught:
        accounts.set_password("x@example.com", "short", NOW)
    assert caught.value.code == "password_short"
    assert caught.value.params == {"min": "10"}
    assert str(caught.value) == "Use a password of at least 10 characters"
    assert isinstance(caught.value, _js.RangeError), "a RangeError in TypeScript"
    # The length counts UTF-16 units, as TypeScript's does: five emoji are ten.
    assert accounts.set_password("emoji@example.com", "\U0001f600" * 5, NOW)["role"] == "admin"


@pytest.mark.parametrize("kind", kinds())
def test_roles_handing_over_and_removing(databases, kind):
    accounts = Accounts(fresh(databases, kind), SECRET)
    owner = accounts.set_password("jon@example.com", "a long password", NOW)
    admin = accounts.set_password("ada@example.com", "a long password", NOW + 1)
    assert code_of(lambda: accounts.set_role(owner["id"], "admin")) == "owner_protected"
    assert code_of(lambda: accounts.set_role(admin["id"], "owner")) == "owner_hand_over"
    assert code_of(lambda: accounts.set_role("a" * 24, "viewer")) == "unknown_account"
    member = accounts.set_role(admin["id"], "member")
    assert list(member) == list(admin), "the role changes in place"
    assert member["role"] == "member"
    assert code_of(lambda: accounts.hand_over(owner["id"], admin["id"])) == "owner_needs_admin"
    assert code_of(lambda: accounts.hand_over(admin["id"], owner["id"])) == "owner_hand_over"
    accounts.set_role(admin["id"], "admin")
    accounts.hand_over(owner["id"], admin["id"])
    assert accounts.by_id(owner["id"])["role"] == "admin"
    assert accounts.by_id(admin["id"])["role"] == "owner"
    assert code_of(lambda: accounts.remove(admin["id"])) == "owner_protected"
    accounts.remove(owner["id"])
    assert accounts.by_id(owner["id"]) is None
    assert code_of(lambda: accounts.remove(owner["id"])) == "unknown_account"


@pytest.mark.parametrize("kind", kinds())
def test_invites_work_once_and_the_newest_link_wins(databases, kind):
    accounts = Accounts(fresh(databases, kind), SECRET)
    accounts.set_password("jon@example.com", "a long password", NOW)
    made = accounts.invite(" Mo@Example.com", "member", "jon@example.com", NOW)
    first, old = made["invite"], made["code"]
    assert list(first) == ["id", "email", "role", "invitedBy", "createdAt", "expiresAt"]
    assert first["email"] == "mo@example.com"
    assert first["expiresAt"] == NOW + INVITE_MS
    assert re.fullmatch(r"[A-Za-z0-9_-]{32}", old)
    made = accounts.invite("mo@example.com", "viewer", "jon@example.com", NOW + 5)
    second, code = made["invite"], made["code"]
    assert accounts.invite_by_code(old, NOW + 10) is None, "asking again replaces the earlier invite"
    assert accounts.invite_by_code(code, NOW + 10) == second
    assert accounts.invites(NOW + 10) == [second]
    assert accounts.invite_by_code("short", NOW) is None
    assert accounts.invite_by_code(code, NOW + 5 + INVITE_MS) is None, "an invite runs out"
    with pytest.raises(AccountError) as caught:
        accounts.invite("jon@example.com", "admin", "jon@example.com", NOW)
    assert caught.value.code == "account_exists"
    assert caught.value.params == {"email": "jon@example.com"}
    user = accounts.accept_invite(code, "another long one", NOW + 20)
    assert user["role"] == "viewer"
    assert accounts.invites(NOW + 20) == []
    assert code_of(lambda: accounts.accept_invite(code, "another long one", NOW + 30)) == "invite_gone", "an invite works once"
    third = accounts.invite("zed@example.com", "admin", "jon@example.com", NOW)["invite"]
    assert accounts.cancel_invite(third["id"]) is True
    assert accounts.cancel_invite(third["id"]) is False
    accounts.invite("old@example.com", "admin", "jon@example.com", NOW)
    assert accounts.invites(NOW + INVITE_MS) == [], "expired invites are cleared on the way"


@pytest.mark.parametrize("kind", kinds())
def test_sessions_tickets_and_devices_are_signed_and_end_with_their_password(databases, kind):
    accounts = Accounts(fresh(databases, kind), SECRET)
    user = accounts.set_password("jon@example.com", "a long password", NOW)
    session = accounts.session_for(user, NOW)
    id_, expires, signed = session.split(".")
    assert id_ == user["id"]
    assert expires == str(NOW + SESSION_MS)
    assert signed == signature(SECRET, f"{id_}.{expires}", user["hash"]), "signed as TypeScript signs it"
    assert accounts.from_session(session, NOW + 1) == user
    assert accounts.from_session(session, NOW + SESSION_MS) is None, "a session runs out"
    assert accounts.from_session(f"{id_}.{expires}.x", NOW) is None
    assert accounts.from_session("", NOW) is None
    assert accounts.from_session(f"{id_}.later.{signed}", NOW) is None

    pending = accounts.pending_for(user, NOW)
    assert accounts.from_pending(pending, NOW) == {"user": user, "real": True}
    assert accounts.from_pending(accounts.decoy_for(user, NOW), NOW) == {"user": user, "real": False}
    assert accounts.from_pending(session, NOW) is None, "a session is not a code-step ticket"
    assert accounts.from_pending(pending, NOW + 5 * 60_000) is None

    device = accounts.device_for(user)
    assert accounts.trusts_device(device, user) is True
    assert accounts.trusts_device("", user) is False

    link = accounts.link_for(user, NOW)
    earlier = accounts.link_for(user, NOW - 1000)
    assert accounts.from_link(link, NOW + 1) == user
    assert accounts.from_link(link, NOW + 2) is None, "a link works once"
    assert accounts.from_link(earlier, NOW + 2) is None, "and withdraws every link sent before it"

    changed = accounts.set_password("jon@example.com", "a new long password", NOW)
    assert accounts.from_session(session, NOW + 1) is None, "a new password signs out every other browser"
    assert accounts.trusts_device(device, changed) is False
    assert accounts.from_session(accounts.session_for(changed, NOW), NOW + 1) is not None


@pytest.mark.parametrize("kind", kinds())
def test_two_factor_codes_work_once_and_recovery_codes_are_crossed_off(databases, kind):
    accounts = Accounts(fresh(databases, kind), SECRET)
    user = accounts.set_password("jon@example.com", "a long password", NOW)
    secret = accounts.start_two_factor(user["id"])
    assert re.fullmatch(r"[A-Z2-7]{32}", secret)
    step = NOW // 30_000
    wrong = "111111" if totp(secret, step) == "000000" else "000000"
    assert accounts.confirm_two_factor(user["id"], wrong, NOW) is None
    recovery = accounts.confirm_two_factor(user["id"], totp(secret, step), NOW)
    assert len(recovery) == 10
    assert re.fullmatch(r"[a-z2-7]{4}-[a-z2-7]{4}", recovery[0])
    on = accounts.by_id(user["id"])
    assert on["twoFactor"] is True
    assert on["recoveryLeft"] == 10
    assert accounts.from_session(accounts.session_for(user, NOW), NOW) is None, "turning two-factor on ends other sessions"

    # The code that turned it on still signs in, once.
    assert accounts.check_second_factor(user["id"], f" {totp(secret, step)} ", NOW) is True
    assert accounts.check_second_factor(user["id"], totp(secret, step), NOW) is False, "a code works once"
    assert accounts.check_second_factor(user["id"], totp(secret, step - 1), NOW) is False, "and an older one never"
    assert accounts.check_second_factor(user["id"], totp(secret, step + 1), NOW) is True, "one step ahead, for a clock that drifts"
    assert accounts.check_second_factor(user["id"], recovery[3].replace("-", "").upper(), NOW) is True
    assert accounts.check_second_factor(user["id"], recovery[3], NOW) is False, "a recovery code is crossed off"
    assert accounts.by_id(user["id"])["recoveryLeft"] == 9
    fresh_codes = accounts.new_recovery_codes(user["id"])
    assert accounts.check_second_factor(user["id"], recovery[0], NOW) is False
    assert accounts.check_second_factor(user["id"], fresh_codes[0], NOW) is True
    accounts.disable_two_factor(user["id"])
    assert accounts.by_id(user["id"])["twoFactor"] is False
    assert accounts.check_second_factor(user["id"], fresh_codes[1], NOW) is False

    accounts.start_two_factor(user["id"])
    accounts.cancel_two_factor_setup(user["id"])
    assert accounts.confirm_two_factor(user["id"], totp(secret, step), NOW) is None, "a cancelled set-up confirms nothing"


def test_an_old_table_gains_roles_and_keeps_one_owner(databases):
    store = fresh(databases, "sqlite")
    store.db.run("CREATE TABLE rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)")
    store.db.run("INSERT INTO rl_users VALUES ('b', 'b@example.com', 'x', 2), ('a', 'a@example.com', 'x', 1)")
    accounts = Accounts(store, SECRET)
    assert [[u["id"], u["role"]] for u in accounts.list()] == [["a", "owner"], ["b", "admin"]]


def test_the_throttle_counts_before_the_check_and_forgives_a_right_try(databases):
    store = fresh(databases, "sqlite")
    throttle = Throttle(store, "test", 3, 1000)
    for _ in range(3):
        assert throttle.take("jon@example.com", NOW) is True
    assert throttle.blocked("jon@example.com", NOW) is True
    assert throttle.take("jon@example.com", NOW) is False, "at its limit, nothing more is counted"
    assert throttle.blocked("ada@example.com", NOW) is False
    throttle.forgive("jon@example.com")
    assert throttle.blocked("jon@example.com", NOW) is False
    throttle.fail("jon@example.com", NOW)
    assert throttle.blocked("jon@example.com", NOW) is True
    assert throttle.blocked("jon@example.com", NOW + 1000) is False, "a window ends"
    throttle.clear("jon@example.com")
    assert throttle.blocked("jon@example.com", NOW) is False
    for setting in store.settings_starting_with("throttle:"):
        assert "jon" not in setting["key"], "keys are hashed, never kept as given"
    assert Throttle(store, "other", 3, 1000).blocked("jon@example.com", NOW) is False, "each throttle counts on its own"
    # Another worker, with a throttle of its own, sees the same counts.
    for _ in range(3):
        throttle.fail("ada@example.com", NOW)
    assert Throttle(store, "test", 3, 1000).blocked("ada@example.com", NOW) is True
    # A new entry clears expired ones.
    throttle.fail("zed@example.com", NOW + 2000)
    assert len(store.settings_starting_with("throttle:test:")) == 1
