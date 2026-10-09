defmodule Runlight.AccountsTest do
  @moduledoc "Accounts as packages/sdk/test/accounts.test.ts checks them: owners, roles, invites, sessions, two-factor, and the throttle."
  use ExUnit.Case, async: true

  alias Runlight.AccountError
  alias Runlight.Accounts
  alias Runlight.Accounts.Throttle
  alias Runlight.Crypto
  alias Runlight.Test.Stores

  setup do
    {store, cleanup} = Stores.store(:sqlite)
    on_exit(cleanup)
    rl = Runlight.new(store: store, now: fn -> 1_791_288_000_000 end)
    Runlight.init(rl)
    {:ok, rl: rl, acc: Accounts.new(rl, String.duplicate("s", 64))}
  end

  test "the first account is the owner, later ones admins, and the owner is protected", %{acc: acc} do
    owner = Accounts.set_password(acc, " Owner@Example.com ", "a long password", 1)
    assert owner["role"] == "owner" and owner["email"] == "owner@example.com"
    admin = Accounts.set_password(acc, "admin@example.com", "a long password", 2)
    assert admin["role"] == "admin"
    assert Accounts.sign_in(acc, "OWNER@example.com", "a long password")["id"] == owner["id"]
    assert Accounts.sign_in(acc, "owner@example.com", "wrong password!") == nil
    assert Accounts.sign_in(acc, "nobody@example.com", "a long password") == nil

    assert_raise AccountError, ~r/at least 10/, fn -> Accounts.set_password(acc, "x@example.com", "short", 3) end
    assert_raise AccountError, fn -> Accounts.set_role(acc, owner["id"], "viewer") end
    assert_raise AccountError, fn -> Accounts.remove(acc, owner["id"]) end
    assert Accounts.set_role(acc, admin["id"], "viewer")["role"] == "viewer"
    assert_raise AccountError, ~r/admin first/, fn -> Accounts.hand_over(acc, owner["id"], admin["id"]) end
    Accounts.set_role(acc, admin["id"], "admin")
    Accounts.hand_over(acc, owner["id"], admin["id"])
    assert Accounts.by_id(acc, admin["id"])["role"] == "owner"
    assert Accounts.by_id(acc, owner["id"])["role"] == "admin"
  end

  test "invites work once and replace earlier ones", %{acc: acc} do
    Accounts.set_password(acc, "owner@example.com", "a long password", 1)
    %{code: first} = Accounts.invite(acc, "new@example.com", "member", "owner@example.com", 10)
    %{code: second} = Accounts.invite(acc, "new@example.com", "viewer", "owner@example.com", 11)
    assert Accounts.invite_by_code(acc, first, 12) == nil
    assert Accounts.invite_by_code(acc, second, 12)["role"] == "viewer"
    user = Accounts.accept_invite(acc, second, "another long one", 13)
    assert user["role"] == "viewer"
    assert_raise AccountError, ~r/expired/, fn -> Accounts.accept_invite(acc, second, "another long one", 14) end

    assert_raise AccountError, ~r/already has an account/, fn ->
      Accounts.invite(acc, "new@example.com", "admin", "o", 15)
    end
  end

  test "sessions follow the password and two-factor", %{acc: acc} do
    user = Accounts.set_password(acc, "owner@example.com", "a long password", 1)
    now = 1_791_288_000_000
    session = Accounts.session_for(acc, user, now)
    assert Accounts.from_session(acc, session, now)["id"] == user["id"]
    assert Accounts.from_session(acc, session, now + Accounts.session_ms()) == nil
    assert Accounts.from_session(acc, session <> "x", now) == nil

    secret = Accounts.start_two_factor(acc, user["id"])
    codes = Accounts.confirm_two_factor(acc, user["id"], Crypto.totp(secret, div(now, 30_000)), now)
    assert length(codes) == 10
    # Turning it on ends the session made before.
    assert Accounts.from_session(acc, session, now) == nil
    # A code works once, and a recovery code is crossed off.
    code = Crypto.totp(secret, div(now, 30_000) + 1)
    assert Accounts.check_second_factor(acc, user["id"], code, now)
    refute Accounts.check_second_factor(acc, user["id"], code, now)
    assert Accounts.check_second_factor(acc, user["id"], String.upcase(hd(codes)), now)
    refute Accounts.check_second_factor(acc, user["id"], hd(codes), now)
    assert Accounts.by_id(acc, user["id"])["recoveryLeft"] == 9

    pending = Accounts.pending_for(acc, user, now)
    assert %{real: true} = Accounts.from_pending(acc, pending, now)
    assert %{real: false} = Accounts.from_pending(acc, Accounts.decoy_for(acc, user, now), now)
    link = Accounts.link_for(acc, Accounts.by_id(acc, user["id"]), now)
    assert Accounts.from_link(acc, link, now)
    assert Accounts.from_link(acc, link, now) == nil
  end

  test "the throttle counts, forgives, and clears", %{rl: rl} do
    t = Throttle.new(rl.table, :test, 3)
    assert Throttle.take(t, "k", 0) and Throttle.take(t, "k", 0) and Throttle.take(t, "k", 0)
    refute Throttle.take(t, "k", 0)
    Throttle.forgive(t, "k")
    assert Throttle.take(t, "k", 0)
    assert Throttle.take(t, "k", 15 * 60_000)
    Throttle.clear(t, "k")
    refute Throttle.blocked?(t, "k", 15 * 60_000)
  end
end
