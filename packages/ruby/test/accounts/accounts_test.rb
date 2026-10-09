# frozen_string_literal: true

require "test_helper"

# Accounts and the throttle on their own, on every database at hand.
class AccountsAccountsTest < Minitest::Test
  Accounts = Runlight::Accounts::Accounts
  AccountError = Runlight::Accounts::AccountError
  Crypto = Runlight::Accounts::Crypto
  Throttle = Runlight::Accounts::Throttle

  NOW = 1_791_288_000_000
  SECRET = "k" * 64

  def store(kind)
    store = Databases.fresh(kind)
    store.migrate
    store
  end

  def code_of
    yield
    ""
  rescue AccountError => e
    e.code
  end

  def each_kind(&block)
    Databases.kinds.each do |kind|
      block.call(kind)
    rescue Minitest::Assertion => e
      raise e.class, "#{kind}: #{e.message}"
    end
  end

  def test_the_first_account_owns_and_the_rest_are_admins_unless_asked
    each_kind do |kind|
      accounts = Accounts.new(store(kind), SECRET)
      assert_equal 0, accounts.count
      owner = accounts.set_password(" Jon@Example.com ", "a long password", NOW)
      assert_equal %w[id email hash role createdAt twoFactor recoveryLeft], owner.keys
      assert_equal "jon@example.com", owner["email"]
      assert_equal "owner", owner["role"]
      assert_match(/\A[a-f0-9]{24}\z/, owner["id"])
      admin = accounts.set_password("ada@example.com", "another long one", NOW + 1, "owner")
      assert_equal "admin", admin["role"], "a server has one owner"
      assert_equal ["jon@example.com", "ada@example.com"], accounts.list.map { |u| u["email"] }
      assert_equal owner, accounts.by_id(owner["id"])
      assert_equal owner["id"], accounts.sign_in("JON@example.com", "a long password")["id"]
      assert_nil accounts.sign_in("jon@example.com", "a wrong password")
      assert_nil accounts.sign_in("nobody@example.com", "a long password")

      assert_equal "email_invalid", code_of { accounts.set_password("not an email", "a long password", NOW) }
      error = assert_raises(AccountError) { accounts.set_password("x@example.com", "short", NOW) }
      assert_equal "password_short", error.code
      assert_equal({ "min" => "10" }, error.params)
      assert_equal "Use a password of at least 10 characters", error.message
      assert_kind_of RangeError, error, "a RangeError in TypeScript"
    end
  end

  def test_roles_handing_over_and_removing
    each_kind do |kind|
      accounts = Accounts.new(store(kind), SECRET)
      owner = accounts.set_password("jon@example.com", "a long password", NOW)
      admin = accounts.set_password("ada@example.com", "a long password", NOW + 1)
      assert_equal "owner_protected", code_of { accounts.set_role(owner["id"], "admin") }
      assert_equal "owner_hand_over", code_of { accounts.set_role(admin["id"], "owner") }
      assert_equal "unknown_account", code_of { accounts.set_role("a" * 24, "viewer") }
      member = accounts.set_role(admin["id"], "member")
      assert_equal admin.keys, member.keys, "the role changes in place"
      assert_equal "member", member["role"]
      assert_equal "owner_needs_admin", code_of { accounts.hand_over(owner["id"], admin["id"]) }
      assert_equal "owner_hand_over", code_of { accounts.hand_over(admin["id"], owner["id"]) }
      accounts.set_role(admin["id"], "admin")
      accounts.hand_over(owner["id"], admin["id"])
      assert_equal "admin", accounts.by_id(owner["id"])["role"]
      assert_equal "owner", accounts.by_id(admin["id"])["role"]
      assert_equal "owner_protected", code_of { accounts.remove(admin["id"]) }
      accounts.remove(owner["id"])
      assert_nil accounts.by_id(owner["id"])
      assert_equal "unknown_account", code_of { accounts.remove(owner["id"]) }
    end
  end

  def test_invites_work_once_and_the_newest_link_wins
    each_kind do |kind|
      accounts = Accounts.new(store(kind), SECRET)
      accounts.set_password("jon@example.com", "a long password", NOW)
      made = accounts.invite(" Mo@Example.com", "member", "jon@example.com", NOW)
      first = made["invite"]
      old = made["code"]
      assert_equal %w[id email role invitedBy createdAt expiresAt], first.keys
      assert_equal "mo@example.com", first["email"]
      assert_equal NOW + Accounts::INVITE_MS, first["expiresAt"]
      assert_match(/\A[A-Za-z0-9_-]{32}\z/, old)
      made = accounts.invite("mo@example.com", "viewer", "jon@example.com", NOW + 5)
      second = made["invite"]
      code = made["code"]
      assert_nil accounts.invite_by_code(old, NOW + 10), "asking again replaces the earlier invite"
      assert_equal second, accounts.invite_by_code(code, NOW + 10)
      assert_equal [second], accounts.invites(NOW + 10)
      assert_nil accounts.invite_by_code("short", NOW)
      assert_nil accounts.invite_by_code(code, NOW + 5 + Accounts::INVITE_MS), "an invite runs out"
      error = assert_raises(AccountError, "someone with an account is not invited") { accounts.invite("jon@example.com", "admin", "jon@example.com", NOW) }
      assert_equal "account_exists", error.code
      assert_equal({ "email" => "jon@example.com" }, error.params)
      user = accounts.accept_invite(code, "another long one", NOW + 20)
      assert_equal "viewer", user["role"]
      assert_equal [], accounts.invites(NOW + 20)
      assert_equal "invite_gone", code_of { accounts.accept_invite(code, "another long one", NOW + 30) }, "an invite works once"
      third = accounts.invite("zed@example.com", "admin", "jon@example.com", NOW)["invite"]
      assert accounts.cancel_invite(third["id"])
      refute accounts.cancel_invite(third["id"])
      accounts.invite("old@example.com", "admin", "jon@example.com", NOW)
      assert_equal [], accounts.invites(NOW + Accounts::INVITE_MS), "expired invites are cleared on the way"
    end
  end

  def test_sessions_tickets_and_devices_are_signed_and_end_with_their_password
    each_kind do |kind|
      accounts = Accounts.new(store(kind), SECRET)
      user = accounts.set_password("jon@example.com", "a long password", NOW)
      session = accounts.session_for(user, NOW)
      id, expires, signature = session.split(".")
      assert_equal user["id"], id
      assert_equal (NOW + Accounts::SESSION_MS).to_s, expires
      assert_equal Crypto.signature(SECRET, "#{id}.#{expires}", user["hash"]), signature, "signed as TypeScript signs it"
      assert_equal user, accounts.from_session(session, NOW + 1)
      assert_nil accounts.from_session(session, NOW + Accounts::SESSION_MS), "a session runs out"
      assert_nil accounts.from_session("#{id}.#{expires}.x", NOW)
      assert_nil accounts.from_session("", NOW)
      assert_nil accounts.from_session("#{id}.later.#{signature}", NOW)

      pending = accounts.pending_for(user, NOW)
      assert_equal({ "user" => user, "real" => true }, accounts.from_pending(pending, NOW))
      assert_equal({ "user" => user, "real" => false }, accounts.from_pending(accounts.decoy_for(user, NOW), NOW))
      assert_nil accounts.from_pending(session, NOW), "a session is not a code-step ticket"
      assert_nil accounts.from_pending(pending, NOW + (5 * 60_000))

      device = accounts.device_for(user)
      assert accounts.trusts_device(device, user)
      refute accounts.trusts_device("", user)

      link = accounts.link_for(user, NOW)
      earlier = accounts.link_for(user, NOW - 1000)
      assert_equal user, accounts.from_link(link, NOW + 1)
      assert_nil accounts.from_link(link, NOW + 2), "a link works once"
      assert_nil accounts.from_link(earlier, NOW + 2), "and withdraws every link sent before it"

      changed = accounts.set_password("jon@example.com", "a new long password", NOW)
      assert_nil accounts.from_session(session, NOW + 1), "a new password signs out every other browser"
      refute accounts.trusts_device(device, changed)
      refute_nil accounts.from_session(accounts.session_for(changed, NOW), NOW + 1)
    end
  end

  def test_two_factor_codes_work_once_and_recovery_codes_are_crossed_off
    each_kind do |kind|
      accounts = Accounts.new(store(kind), SECRET)
      user = accounts.set_password("jon@example.com", "a long password", NOW)
      secret = accounts.start_two_factor(user["id"])
      assert_match(/\A[A-Z2-7]{32}\z/, secret)
      step = NOW / 30_000
      wrong = Crypto.totp(secret, step) == "000000" ? "111111" : "000000"
      assert_nil accounts.confirm_two_factor(user["id"], wrong, NOW)
      recovery = accounts.confirm_two_factor(user["id"], Crypto.totp(secret, step), NOW)
      assert_equal 10, recovery.length
      assert_match(/\A[a-z2-7]{4}-[a-z2-7]{4}\z/, recovery[0])
      on = accounts.by_id(user["id"])
      assert on["twoFactor"]
      assert_equal 10, on["recoveryLeft"]
      assert_nil accounts.from_session(accounts.session_for(user, NOW), NOW), "turning two-factor on ends other sessions"

      # The code that turned it on still signs in, once.
      assert accounts.check_second_factor(user["id"], " #{Crypto.totp(secret, step)} ", NOW)
      refute accounts.check_second_factor(user["id"], Crypto.totp(secret, step), NOW), "a code works once"
      refute accounts.check_second_factor(user["id"], Crypto.totp(secret, step - 1), NOW), "and an older one never"
      assert accounts.check_second_factor(user["id"], Crypto.totp(secret, step + 1), NOW), "one step ahead, for a clock that drifts"
      assert accounts.check_second_factor(user["id"], recovery[3].delete("-").upcase, NOW)
      refute accounts.check_second_factor(user["id"], recovery[3], NOW), "a recovery code is crossed off"
      assert_equal 9, accounts.by_id(user["id"])["recoveryLeft"]
      fresh = accounts.new_recovery_codes(user["id"])
      refute accounts.check_second_factor(user["id"], recovery[0], NOW)
      assert accounts.check_second_factor(user["id"], fresh[0], NOW)
      accounts.disable_two_factor(user["id"])
      refute accounts.by_id(user["id"])["twoFactor"]
      refute accounts.check_second_factor(user["id"], fresh[1], NOW)

      accounts.start_two_factor(user["id"])
      accounts.cancel_two_factor_setup(user["id"])
      assert_nil accounts.confirm_two_factor(user["id"], Crypto.totp(secret, step), NOW), "a cancelled set-up confirms nothing"
    end
  end

  def test_an_old_table_gains_roles_and_keeps_one_owner
    store = store("sqlite")
    store.db.run("CREATE TABLE rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)")
    store.db.run("INSERT INTO rl_users VALUES ('b', 'b@example.com', 'x', 2), ('a', 'a@example.com', 'x', 1)")
    accounts = Accounts.new(store, SECRET)
    assert_equal [%w[a owner], %w[b admin]], accounts.list.map { |u| [u["id"], u["role"]] }
  end

  def test_the_throttle_counts_before_the_check_and_forgives_a_right_try
    store = store("sqlite")
    throttle = Throttle.new(store, "test", 3, 1000)
    3.times { assert throttle.take("jon@example.com", NOW) }
    assert throttle.blocked("jon@example.com", NOW)
    refute throttle.take("jon@example.com", NOW), "at its limit, nothing more is counted"
    refute throttle.blocked("ada@example.com", NOW)
    throttle.forgive("jon@example.com")
    refute throttle.blocked("jon@example.com", NOW)
    throttle.record_failure("jon@example.com", NOW)
    assert throttle.blocked("jon@example.com", NOW)
    refute throttle.blocked("jon@example.com", NOW + 1000), "a window ends"
    throttle.clear("jon@example.com")
    refute throttle.blocked("jon@example.com", NOW)
    store.settings_starting_with("throttle:").each do |row|
      refute_includes row["key"], "jon", "keys are hashed, never kept as given"
    end
    refute Throttle.new(store, "other", 3, 1000).blocked("jon@example.com", NOW), "each throttle counts on its own"
    # Another request, with a throttle of its own, sees the same counts.
    3.times { throttle.record_failure("ada@example.com", NOW) }
    assert Throttle.new(store, "test", 3, 1000).blocked("ada@example.com", NOW)
    # A new entry clears expired ones.
    throttle.record_failure("zed@example.com", NOW + 2000)
    assert_equal 1, store.settings_starting_with("throttle:test:").length
  end
end
