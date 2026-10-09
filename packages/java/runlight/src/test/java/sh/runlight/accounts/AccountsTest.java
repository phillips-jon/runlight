package sh.runlight.accounts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.CodedError;
import sh.runlight.Json;
import sh.runlight.store.Databases;
import sh.runlight.store.SqlStore;

/** Accounts and the throttle on their own, on every database at hand. */
class AccountsTest {
  private static final long NOW = 1_791_288_000_000L;
  private static final String SECRET = "k".repeat(64);

  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void tearDown() {
    Databases.cleanup();
  }

  private static SqlStore store(String kind) {
    SqlStore store = Databases.fresh(kind);
    store.migrate();
    return store;
  }

  private static String codeOf(Runnable fn) {
    try {
      fn.run();
      return "";
    } catch (AccountError error) {
      return error.code();
    }
  }

  private static List<Object> column(List<Map<String, Object>> rows, String key) {
    List<Object> out = new ArrayList<>();
    for (Map<String, Object> row : rows) {
      out.add(row.get(key));
    }
    return out;
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void theFirstAccountOwnsAndTheRestAreAdminsUnlessAsked(String kind) {
    Accounts accounts = new Accounts(store(kind), SECRET);
    assertEquals(0, accounts.count());
    Map<String, Object> owner = accounts.setPassword(" Jon@Example.com ", "a long password", NOW);
    assertEquals(
        List.of("id", "email", "hash", "role", "createdAt", "twoFactor", "recoveryLeft"),
        new ArrayList<>(owner.keySet()));
    assertEquals("jon@example.com", owner.get("email"));
    assertEquals("owner", owner.get("role"));
    assertTrue(((String) owner.get("id")).matches("[a-f0-9]{24}"));
    Map<String, Object> admin =
        accounts.setPassword("ada@example.com", "another long one", NOW + 1, "owner");
    assertEquals("admin", admin.get("role"), "a server has one owner");
    assertEquals(List.of("jon@example.com", "ada@example.com"), column(accounts.list(), "email"));
    assertEquals(Json.stringify(owner), Json.stringify(accounts.byId((String) owner.get("id"))));
    assertEquals(owner.get("id"), accounts.signIn("JON@example.com", "a long password").get("id"));
    assertNull(accounts.signIn("jon@example.com", "a wrong password"));
    assertNull(accounts.signIn("nobody@example.com", "a long password"));

    assertEquals(
        "email_invalid",
        codeOf(() -> accounts.setPassword("not an email", "a long password", NOW)));
    AccountError error =
        assertThrows(AccountError.class, () -> accounts.setPassword("x@example.com", "short", NOW));
    assertEquals("password_short", error.code());
    assertEquals(Map.of("min", "10"), error.params());
    assertEquals("Use a password of at least 10 characters", error.getMessage());
    assertInstanceOf(CodedError.class, error, "a RangeError in TypeScript, with a code");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void rolesHandingOverAndRemoving(String kind) {
    Accounts accounts = new Accounts(store(kind), SECRET);
    String owner =
        (String) accounts.setPassword("jon@example.com", "a long password", NOW).get("id");
    Map<String, Object> admin = accounts.setPassword("ada@example.com", "a long password", NOW + 1);
    String adminId = (String) admin.get("id");
    assertEquals("owner_protected", codeOf(() -> accounts.setRole(owner, "admin")));
    assertEquals("owner_hand_over", codeOf(() -> accounts.setRole(adminId, "owner")));
    assertEquals("unknown_account", codeOf(() -> accounts.setRole("a".repeat(24), "viewer")));
    Map<String, Object> member = accounts.setRole(adminId, "member");
    assertEquals(
        new ArrayList<>(admin.keySet()),
        new ArrayList<>(member.keySet()),
        "the role changes in place");
    assertEquals("member", member.get("role"));
    assertEquals("owner_needs_admin", codeOf(() -> accounts.handOver(owner, adminId)));
    assertEquals("owner_hand_over", codeOf(() -> accounts.handOver(adminId, owner)));
    accounts.setRole(adminId, "admin");
    accounts.handOver(owner, adminId);
    assertEquals("admin", accounts.byId(owner).get("role"));
    assertEquals("owner", accounts.byId(adminId).get("role"));
    assertEquals("owner_protected", codeOf(() -> accounts.remove(adminId)));
    accounts.remove(owner);
    assertNull(accounts.byId(owner));
    assertEquals("unknown_account", codeOf(() -> accounts.remove(owner)));
  }

  @SuppressWarnings("unchecked")
  private static Map<String, Object> inviteOf(Map<String, Object> made) {
    return (Map<String, Object>) made.get("invite");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void invitesWorkOnceAndTheNewestLinkWins(String kind) {
    Accounts accounts = new Accounts(store(kind), SECRET);
    accounts.setPassword("jon@example.com", "a long password", NOW);
    Map<String, Object> made = accounts.invite(" Mo@Example.com", "member", "jon@example.com", NOW);
    Map<String, Object> first = inviteOf(made);
    String old = (String) made.get("code");
    assertEquals(
        List.of("id", "email", "role", "invitedBy", "createdAt", "expiresAt"),
        new ArrayList<>(first.keySet()));
    assertEquals("mo@example.com", first.get("email"));
    assertEquals(NOW + Accounts.INVITE_MS, first.get("expiresAt"));
    assertTrue(old.matches("[A-Za-z0-9_-]{32}"), old);
    Map<String, Object> again =
        accounts.invite("mo@example.com", "viewer", "jon@example.com", NOW + 5);
    Map<String, Object> second = inviteOf(again);
    String code = (String) again.get("code");
    assertNull(accounts.inviteByCode(old, NOW + 10), "asking again replaces the earlier invite");
    assertEquals(second, accounts.inviteByCode(code, NOW + 10));
    assertEquals(List.of(second), accounts.invites(NOW + 10));
    assertNull(accounts.inviteByCode("short", NOW));
    assertNull(accounts.inviteByCode(code, NOW + 5 + Accounts.INVITE_MS), "an invite runs out");
    AccountError error =
        assertThrows(
            AccountError.class,
            () -> accounts.invite("jon@example.com", "admin", "jon@example.com", NOW),
            "someone with an account is not invited");
    assertEquals("account_exists", error.code());
    assertEquals(Map.of("email", "jon@example.com"), error.params());
    Map<String, Object> user = accounts.acceptInvite(code, "another long one", NOW + 20);
    assertEquals("viewer", user.get("role"));
    assertEquals(List.of(), accounts.invites(NOW + 20));
    assertEquals(
        "invite_gone",
        codeOf(() -> accounts.acceptInvite(code, "another long one", NOW + 30)),
        "an invite works once");
    Map<String, Object> third =
        inviteOf(accounts.invite("zed@example.com", "admin", "jon@example.com", NOW));
    assertTrue(accounts.cancelInvite((String) third.get("id")));
    assertFalse(accounts.cancelInvite((String) third.get("id")));
    accounts.invite("old@example.com", "admin", "jon@example.com", NOW);
    assertEquals(
        List.of(),
        accounts.invites(NOW + Accounts.INVITE_MS),
        "expired invites are cleared on the way");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void sessionsTicketsAndDevicesAreSignedAndEndWithTheirPassword(String kind) {
    Accounts accounts = new Accounts(store(kind), SECRET);
    Map<String, Object> user = accounts.setPassword("jon@example.com", "a long password", NOW);
    String session = accounts.sessionFor(user, NOW);
    String[] parts = session.split("\\.");
    String id = parts[0];
    String expires = parts[1];
    String signature = parts[2];
    assertEquals(user.get("id"), id);
    assertEquals(Long.toString(NOW + Accounts.SESSION_MS), expires);
    assertEquals(
        Crypto.signature(SECRET, id + "." + expires, (String) user.get("hash")),
        signature,
        "signed as TypeScript signs it");
    assertEquals(user, accounts.fromSession(session, NOW + 1));
    assertNull(accounts.fromSession(session, NOW + Accounts.SESSION_MS), "a session runs out");
    assertNull(accounts.fromSession(id + "." + expires + ".x", NOW));
    assertNull(accounts.fromSession("", NOW));
    assertNull(accounts.fromSession(id + ".later." + signature, NOW));

    String pending = accounts.pendingFor(user, NOW);
    assertEquals(Json.object("user", user, "real", true), accounts.fromPending(pending, NOW));
    assertEquals(
        Json.object("user", user, "real", false),
        accounts.fromPending(accounts.decoyFor(user, NOW), NOW));
    assertNull(accounts.fromPending(session, NOW), "a session is not a code-step ticket");
    assertNull(accounts.fromPending(pending, NOW + 5 * 60_000));

    String device = accounts.deviceFor(user);
    assertTrue(accounts.trustsDevice(device, user));
    assertFalse(accounts.trustsDevice("", user));

    String link = accounts.linkFor(user, NOW);
    String earlier = accounts.linkFor(user, NOW - 1000);
    assertEquals(user, accounts.fromLink(link, NOW + 1));
    assertNull(accounts.fromLink(link, NOW + 2), "a link works once");
    assertNull(accounts.fromLink(earlier, NOW + 2), "and withdraws every link sent before it");

    Map<String, Object> changed =
        accounts.setPassword("jon@example.com", "a new long password", NOW);
    assertNull(
        accounts.fromSession(session, NOW + 1), "a new password signs out every other browser");
    assertFalse(accounts.trustsDevice(device, changed));
    assertNotNull(accounts.fromSession(accounts.sessionFor(changed, NOW), NOW + 1));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void twoFactorCodesWorkOnceAndRecoveryCodesAreCrossedOff(String kind) {
    Accounts accounts = new Accounts(store(kind), SECRET);
    Map<String, Object> user = accounts.setPassword("jon@example.com", "a long password", NOW);
    String id = (String) user.get("id");
    String secret = accounts.startTwoFactor(id);
    assertTrue(secret.matches("[A-Z2-7]{32}"), secret);
    long step = NOW / 30_000;
    String wrong = Crypto.totp(secret, step).equals("000000") ? "111111" : "000000";
    assertNull(accounts.confirmTwoFactor(id, wrong, NOW));
    List<String> recovery = accounts.confirmTwoFactor(id, Crypto.totp(secret, step), NOW);
    assertEquals(10, recovery.size());
    assertTrue(recovery.get(0).matches("[a-z2-7]{4}-[a-z2-7]{4}"));
    Map<String, Object> on = accounts.byId(id);
    assertEquals(true, on.get("twoFactor"));
    assertEquals(10L, on.get("recoveryLeft"));
    assertNull(
        accounts.fromSession(accounts.sessionFor(user, NOW), NOW),
        "turning two-factor on ends other sessions");

    // The code that turned it on still signs in, once.
    assertTrue(accounts.checkSecondFactor(id, " " + Crypto.totp(secret, step) + " ", NOW));
    assertFalse(
        accounts.checkSecondFactor(id, Crypto.totp(secret, step), NOW), "a code works once");
    assertFalse(
        accounts.checkSecondFactor(id, Crypto.totp(secret, step - 1), NOW),
        "and an older one never");
    assertTrue(
        accounts.checkSecondFactor(id, Crypto.totp(secret, step + 1), NOW),
        "one step ahead, for a clock that drifts");
    assertTrue(accounts.checkSecondFactor(id, recovery.get(3).replace("-", "").toUpperCase(), NOW));
    assertFalse(
        accounts.checkSecondFactor(id, recovery.get(3), NOW), "a recovery code is crossed off");
    assertEquals(9L, accounts.byId(id).get("recoveryLeft"));
    List<String> fresh = accounts.newRecoveryCodes(id);
    assertFalse(accounts.checkSecondFactor(id, recovery.get(0), NOW));
    assertTrue(accounts.checkSecondFactor(id, fresh.get(0), NOW));
    accounts.disableTwoFactor(id);
    assertEquals(false, accounts.byId(id).get("twoFactor"));
    assertFalse(accounts.checkSecondFactor(id, fresh.get(1), NOW));

    accounts.startTwoFactor(id);
    accounts.cancelTwoFactorSetup(id);
    assertNull(
        accounts.confirmTwoFactor(id, Crypto.totp(secret, step), NOW),
        "a cancelled set-up confirms nothing");
  }

  @Test
  void anOldTableGainsRolesAndKeepsOneOwner() {
    SqlStore store = store("sqlite");
    store
        .db()
        .run(
            "CREATE TABLE rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)");
    store
        .db()
        .run(
            "INSERT INTO rl_users VALUES ('b', 'b@example.com', 'x', 2), ('a', 'a@example.com', 'x', 1)");
    Accounts accounts = new Accounts(store, SECRET);
    List<List<Object>> roles = new ArrayList<>();
    for (Map<String, Object> u : accounts.list()) {
      roles.add(List.of(u.get("id"), u.get("role")));
    }
    assertEquals(List.of(List.of("a", "owner"), List.of("b", "admin")), roles);
  }

  @Test
  void theThrottleCountsBeforeTheCheckAndForgivesARightTry() {
    SqlStore store = store("sqlite");
    Throttle throttle = new Throttle(store, "test", 3, 1000);
    for (int i = 0; i < 3; i++) {
      assertTrue(throttle.take("jon@example.com", NOW));
    }
    assertTrue(throttle.blocked("jon@example.com", NOW));
    assertFalse(throttle.take("jon@example.com", NOW), "at its limit, nothing more is counted");
    assertFalse(throttle.blocked("ada@example.com", NOW));
    throttle.forgive("jon@example.com");
    assertFalse(throttle.blocked("jon@example.com", NOW));
    throttle.fail("jon@example.com", NOW);
    assertTrue(throttle.blocked("jon@example.com", NOW));
    assertFalse(throttle.blocked("jon@example.com", NOW + 1000), "a window ends");
    throttle.clear("jon@example.com");
    assertFalse(throttle.blocked("jon@example.com", NOW));
    for (Map<String, Object> setting : store.settingsStartingWith("throttle:")) {
      assertFalse(
          ((String) setting.get("key")).contains("jon"), "keys are hashed, never kept as given");
    }
    assertFalse(
        new Throttle(store, "other", 3, 1000).blocked("jon@example.com", NOW),
        "each throttle counts on its own");
    // Another request, with a throttle of its own, sees the same counts.
    throttle.fail("ada@example.com", NOW);
    throttle.fail("ada@example.com", NOW);
    throttle.fail("ada@example.com", NOW);
    assertTrue(new Throttle(store, "test", 3, 1000).blocked("ada@example.com", NOW));
    // A new entry clears expired ones.
    throttle.fail("zed@example.com", NOW + 2000);
    assertEquals(1, store.settingsStartingWith("throttle:test:").size());
  }
}
