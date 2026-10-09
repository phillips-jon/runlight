package sh.runlight.accounts;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.db.Db;
import sh.runlight.store.SqlStore;

/**
 * Accounts: who may sign in, their password hashes, two-factor, invites, and the signed cookie that
 * keeps them signed in. The standalone server always has them, and an app turns them on with
 * routes({accounts: true}).
 *
 * <p>The owner can do everything, and nobody else can remove them or change their role; they can
 * hand ownership to an admin. An admin can do everything the owner can apart from that. A member
 * changes sites, goals, links, and the rest, but not people, the mail service, the assistant's
 * settings, or deleting a site. A viewer reads every site's stats and changes nothing.
 *
 * <p>A user is a map with the TypeScript User's keys: id, email, hash, role ("owner", "admin",
 * "member", or "viewer"), createdAt, twoFactor (whether sign-in also asks for a code), and
 * recoveryLeft (recovery codes not yet used). An invite has id, email, role, invitedBy, createdAt,
 * and expiresAt.
 */
public final class Accounts {
  public static final String SESSION_COOKIE = "runlight_session";

  /** Thirty days, renewed on every sign-in. */
  public static final long SESSION_MS = 30 * 86_400_000L;

  public static final int MIN_PASSWORD = 10;

  /** The most sign-in keys the throttle remembers at once. */
  public static final int MAX_THROTTLED = 10_000;

  /** How long an invite link works. */
  public static final long INVITE_MS = 7 * 86_400_000L;

  public static final List<String> ROLES = List.of("owner", "admin", "member", "viewer");

  /** What passes for an email address, with JavaScript's \s. */
  private static final Pattern EMAIL =
      Pattern.compile(
          "^[^" + Js.SPACE + "@<>\"]+@[^" + Js.SPACE + "@<>\"]+\\.[^" + Js.SPACE + "@<>\"]+\\z");

  private static final Pattern SPACES = Pattern.compile("[" + Js.SPACE + "]");
  private static final Pattern SIX_DIGITS = Pattern.compile("^\\d{6}\\z");
  private static final Pattern INVITE_CODE = Pattern.compile("^[A-Za-z0-9_-]{20,64}\\z");

  /**
   * A password checked against nothing, so a wrong email takes as long as a wrong password. Made
   * when first needed.
   */
  private static volatile String decoy;

  private final SqlStore store;
  private final String secret;
  private volatile boolean ready;

  public Accounts(SqlStore store, String secret) {
    this.store = store;
    this.secret = secret;
  }

  /** A stored role read back; anything unknown reads as a viewer, the least it could be. */
  public static String roleFrom(Object value) {
    return value instanceof String s && ROLES.contains(s) ? s : "viewer";
  }

  /**
   * Changes to who has an account take turns: on Postgres and MySQL across processes, through the
   * database's lock, so two owners demoting each other at once cannot leave none, and a
   * double-clicked invite makes one.
   */
  private <T> T turn(Supplier<T> fn) {
    return store.db().exclusive(db -> fn.get());
  }

  private Db db() {
    return store.db();
  }

  private void init() {
    if (ready) {
      return;
    }
    // Several processes starting at once create the tables one at a time.
    store
        .db()
        .exclusive(
            db -> {
              // MySQL keys TEXT only by a prefix, so there the keyed columns are VARCHAR, in the
              // binary collation the store's tables use.
              boolean my = db.dialect().equals("mysql");
              String table =
                  my ? " DEFAULT CHARSET=utf8mb4 COLLATE=" + SqlStore.MYSQL_COLLATION : "";
              db.run(
                  "CREATE TABLE IF NOT EXISTS rl_users (id "
                      + str(my, 100)
                      + " PRIMARY KEY, email "
                      + str(my, 320)
                      + " NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)"
                      + table);
              // Roles came later; a table from before them gains the column, and its accounts stay
              // owners.
              List<Map<String, Object>> columns =
                  db.dialect().equals("sqlite")
                      ? db.all("PRAGMA table_info(rl_users)")
                      : db.all(
                          "SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = "
                              + (my ? "DATABASE()" : "current_schema()"));
              List<String> names = new ArrayList<>();
              for (Map<String, Object> c : columns) {
                Object name = c.containsKey("name") ? c.get("name") : c.get("NAME");
                names.add(name == null ? "" : Js.string(name));
              }
              if (!names.contains("role")) {
                db.run(
                    "ALTER TABLE rl_users ADD COLUMN role "
                        + str(my, 20)
                        + " NOT NULL DEFAULT 'owner'");
              }
              // Two-factor came later still: the secret (sealed), one being set up, recovery code
              // hashes, and the last code's step.
              String[][] added = {
                {"totp_secret", "TEXT"},
                {"totp_pending", "TEXT"},
                {"totp_recovery", "TEXT"},
                {"totp_step", "BIGINT"}
              };
              for (String[] column : added) {
                if (!names.contains(column[0])) {
                  db.run("ALTER TABLE rl_users ADD COLUMN " + column[0] + " " + column[1]);
                }
              }
              db.run(
                  "CREATE TABLE IF NOT EXISTS rl_invites (id "
                      + str(my, 100)
                      + " PRIMARY KEY, email "
                      + str(my, 320)
                      + " NOT NULL UNIQUE, role "
                      + str(my, 20)
                      + " NOT NULL, code_hash "
                      + str(my, 128)
                      + " NOT NULL UNIQUE, invited_by "
                      + str(my, 100)
                      + " NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)"
                      + table);
              // A server has one owner. One from before, with several, keeps the first and the
              // rest become admins, who can still do everything but remove the owner. Invites to
              // join as an owner become invites as an admin.
              List<Map<String, Object>> owners =
                  db.all("SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id");
              for (Map<String, Object> extra :
                  owners.subList(Math.min(1, owners.size()), owners.size())) {
                db.run(
                    "UPDATE rl_users SET role = 'admin' WHERE id = ?",
                    List.of(Js.string(extra.get("id"))));
              }
              db.run("UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'");
              return null;
            });
    ready = true;
  }

  private static String str(boolean my, int n) {
    return my ? "VARCHAR(" + n + ")" : "TEXT";
  }

  private static Map<String, Object> first(List<Map<String, Object>> rows) {
    return rows.isEmpty() ? null : rows.get(0);
  }

  private static List<Object> stringList(Object stored) {
    return Js.truthy(stored) ? Js.list(Json.parse(Js.string(stored))) : new ArrayList<>();
  }

  private static Map<String, Object> row(Map<String, Object> r) {
    return Json.object(
        "id", Js.string(r.get("id")),
        "email", Js.string(r.get("email")),
        "hash", Js.string(r.get("hash")),
        "role", roleFrom(r.get("role")),
        "createdAt", Js.num(Js.toNumber(r.get("created_at"))),
        "twoFactor", Js.truthy(r.get("totp_secret")),
        "recoveryLeft", (long) stringList(r.get("totp_recovery")).size());
  }

  private static String id(Map<String, Object> user) {
    return (String) user.get("id");
  }

  /**
   * Seals a two-factor secret with the install's secret, so the database alone cannot make codes.
   */
  private String seal(String text) {
    return Crypto.sealText(text, secret);
  }

  private String unseal(String sealed) {
    return Crypto.unsealText(sealed, secret);
  }

  private static String recoveryHashes(List<String> codes) {
    List<Object> hashes = new ArrayList<>();
    for (String code : codes) {
      hashes.add(Crypto.recoveryHash(code));
    }
    return Json.stringify(hashes);
  }

  /** Starts turning on two-factor: a new secret, kept aside until a code from it is confirmed. */
  public String startTwoFactor(String id) {
    init();
    String fresh = Crypto.base32(Crypto.randomBytes(20));
    db().run("UPDATE rl_users SET totp_pending = ? WHERE id = ?", List.of(seal(fresh), id));
    return fresh;
  }

  /**
   * Turns two-factor on once a code from the new secret checks out, and returns ten recovery codes,
   * shown once; null when the code is wrong.
   */
  public List<String> confirmTwoFactor(String id, String code, long now) {
    init();
    Map<String, Object> r =
        first(db().all("SELECT totp_pending FROM rl_users WHERE id = ?", List.of(id)));
    String pending =
        r != null && Js.truthy(r.get("totp_pending"))
            ? unseal(Js.string(r.get("totp_pending")))
            : null;
    Long step =
        pending != null && !pending.isEmpty() ? Crypto.matchStep(pending, code, now, -1) : null;
    if (step == null) {
      return null;
    }
    List<String> recovery = Crypto.recoveryCodes();
    // The code that turned it on is not marked used, so signing in again at once with it works.
    db().run(
            "UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?",
            List.of(seal(pending), recoveryHashes(recovery), id));
    return recovery;
  }

  /** New recovery codes in place of the old ones. */
  public List<String> newRecoveryCodes(String id) {
    init();
    List<String> recovery = Crypto.recoveryCodes();
    db().run(
            "UPDATE rl_users SET totp_recovery = ? WHERE id = ?",
            List.of(recoveryHashes(recovery), id));
    return recovery;
  }

  /**
   * Drops a set-up left half done, after too many wrong codes, so it must start again with the
   * password.
   */
  public void cancelTwoFactorSetup(String id) {
    init();
    db().run("UPDATE rl_users SET totp_pending = NULL WHERE id = ?", List.of(id));
  }

  public void disableTwoFactor(String id) {
    init();
    db().run(
            "UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?",
            List.of(id));
  }

  /**
   * Checks a six-digit code, or a recovery code, for an account with two-factor on. A code works
   * once: one already used, or older, is refused, and a recovery code is crossed off. One check at
   * a time, so two sign-ins at once cannot both use the same code: TypeScript queues them per
   * account in its process, and this port, like the PHP one, takes the database's lock.
   */
  public boolean checkSecondFactor(String id, String code, long now) {
    init();
    return turn(() -> checkSecondFactorNow(id, code, now));
  }

  private boolean checkSecondFactorNow(String id, String code, long now) {
    Map<String, Object> r =
        first(
            db().all(
                    "SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?",
                    List.of(id)));
    if (r == null || !Js.truthy(r.get("totp_secret"))) {
      return false;
    }
    String given = Js.trim(code);
    String digits = SPACES.matcher(given).replaceAll("");
    if (SIX_DIGITS.matcher(digits).matches()) {
      String totp = unseal(Js.string(r.get("totp_secret")));
      long after = r.get("totp_step") == null ? -1 : (long) Js.toNumber(r.get("totp_step"));
      Long step =
          totp != null && !totp.isEmpty() ? Crypto.matchStep(totp, digits, now, after) : null;
      if (step == null) {
        return false;
      }
      db().run("UPDATE rl_users SET totp_step = ? WHERE id = ?", List.of(step, id));
      return true;
    }
    List<Object> hashes = stringList(r.get("totp_recovery"));
    int at = hashes.indexOf(Crypto.recoveryHash(given));
    if (at < 0) {
      return false;
    }
    hashes.remove(at);
    db().run(
            "UPDATE rl_users SET totp_recovery = ? WHERE id = ?",
            List.of(Json.stringify(hashes), id));
    return true;
  }

  /**
   * A short-lived ticket naming an account whose password checked out and which still owes a code.
   * Signed like a session, so it cannot be made up.
   */
  public String pendingFor(Map<String, Object> user, long now) {
    return ticket("pending", user, now + 5 * 60_000L);
  }

  /**
   * A ticket that looks and acts like pendingFor's, except that no code ever passes with it. A
   * wrong password gets one once an account with two-factor has had too many, so the answer never
   * tells a right password.
   */
  public String decoyFor(Map<String, Object> user, long now) {
    return ticket("decoy", user, now + 5 * 60_000L);
  }

  /**
   * The account a code-step ticket names, and whether a right code may sign in with it: {user,
   * real}, or null.
   */
  public Map<String, Object> fromPending(String value, long now) {
    Map<String, Object> user = fromTicket("pending", value, now);
    if (user != null) {
      return Json.object("user", user, "real", true);
    }
    Map<String, Object> fake = fromTicket("decoy", value, now);
    return fake != null ? Json.object("user", fake, "real", false) : null;
  }

  /**
   * A ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it.
   */
  public String linkFor(Map<String, Object> user, long now) {
    return ticket("link", user, now + 15 * 60_000L);
  }

  /**
   * The account a sign-in link is for. A link works once: using it withdraws it, and every link
   * sent before it. Uses take turns, so a link opened twice at once lets one in.
   */
  public Map<String, Object> fromLink(String value, long now) {
    Map<String, Object> user = fromTicket("link", value, now);
    if (user == null) {
      return null;
    }
    String[] parts = value.split("\\.", -1);
    double expires = Js.toNumber(parts.length > 1 ? parts[1] : "");
    return turn(
        () -> {
          String key = "login-link-used:" + id(user);
          String used = store.setting(key);
          if (expires <= Js.toNumber(used == null ? 0L : used)) {
            return null;
          }
          store.setSetting(key, Js.string(Js.num(expires)));
          return user;
        });
  }

  private String ticket(String kind, Map<String, Object> user, long expires) {
    String body = id(user) + "." + expires;
    return body + "." + sign(kind + "." + body, (String) user.get("hash"));
  }

  private Map<String, Object> fromTicket(String kind, String value, long now) {
    String[] parts = value.split("\\.", -1);
    String id = parts[0];
    String expires = parts.length > 1 ? parts[1] : "";
    String signature = parts.length > 2 ? parts[2] : "";
    if (id.isEmpty() || expires.isEmpty() || signature.isEmpty() || !(Js.toNumber(expires) > now)) {
      return null;
    }
    Map<String, Object> user = byId(id);
    if (user == null) {
      return null;
    }
    return Crypto.sameText(
            sign(kind + "." + id + "." + expires, (String) user.get("hash")), signature)
        ? user
        : null;
  }

  public long count() {
    init();
    Map<String, Object> r = first(db().all("SELECT COUNT(*) AS n FROM rl_users"));
    return r == null || r.get("n") == null ? 0 : Js.asLong(r.get("n"));
  }

  public Map<String, Object> byEmail(String email) {
    init();
    Map<String, Object> r =
        first(
            db().all("SELECT * FROM rl_users WHERE email = ?", List.of(Js.lower(Js.trim(email)))));
    return r != null ? row(r) : null;
  }

  public Map<String, Object> byId(String id) {
    init();
    Map<String, Object> r = first(db().all("SELECT * FROM rl_users WHERE id = ?", List.of(id)));
    return r != null ? row(r) : null;
  }

  public List<Map<String, Object>> list() {
    init();
    List<Map<String, Object>> out = new ArrayList<>();
    for (Map<String, Object> r : db().all("SELECT * FROM rl_users ORDER BY created_at, id")) {
      out.add(row(r));
    }
    return out;
  }

  /**
   * Changes a role. The owner's never changes here, and nobody becomes the owner here: see
   * handOver().
   */
  public Map<String, Object> setRole(String id, String role) {
    // The tables first: making them takes the same lock as a turn.
    init();
    return turn(
        () -> {
          Map<String, Object> user = find(id);
          if (user == null) {
            throw new AccountError("Unknown account", "unknown_account");
          }
          if (user.get("role").equals("owner")) {
            throw new AccountError(
                "Only the owner can change their own role, by handing ownership to an admin",
                "owner_protected");
          }
          if (role.equals("owner")) {
            throw new AccountError("Ownership is handed over by the owner", "owner_hand_over");
          }
          db().run("UPDATE rl_users SET role = ? WHERE id = ?", List.of(role, id));
          user.put("role", role);
          return user;
        });
  }

  private Map<String, Object> find(String id) {
    for (Map<String, Object> user : list()) {
      if (id(user).equals(id)) {
        return user;
      }
    }
    return null;
  }

  /** Makes an admin the owner, and the owner an admin. */
  public void handOver(String from, String to) {
    init();
    turn(
        () -> {
          Map<String, Object> owner = find(from);
          Map<String, Object> next = find(to);
          if (owner == null || !owner.get("role").equals("owner")) {
            throw new AccountError("Only the owner can hand over ownership", "owner_hand_over");
          }
          if (next == null) {
            throw new AccountError("Unknown account", "unknown_account");
          }
          if (!next.get("role").equals("admin")) {
            throw new AccountError("Make them an admin first", "owner_needs_admin");
          }
          db().run("UPDATE rl_users SET role = 'owner' WHERE id = ?", List.of(to));
          db().run("UPDATE rl_users SET role = 'admin' WHERE id = ?", List.of(from));
          return null;
        });
  }

  /** Removes an account. The owner cannot be removed. */
  public void remove(String id) {
    // The tables first: making them takes the same lock as a turn.
    init();
    turn(
        () -> {
          Map<String, Object> user = find(id);
          if (user == null) {
            throw new AccountError("Unknown account", "unknown_account");
          }
          if (user.get("role").equals("owner")) {
            throw new AccountError("The owner cannot be removed", "owner_protected");
          }
          db().run("DELETE FROM rl_users WHERE id = ?", List.of(id));
          store.setSetting("login-link-used:" + id, null);
          return null;
        });
  }

  /** As {@link #setPassword(String, String, long, String)}, the role chosen for a new account. */
  public Map<String, Object> setPassword(String email, String password, long now) {
    return setPassword(email, password, now, null);
  }

  /**
   * Makes an account, or sets a new password on an existing one. A new account is the owner when it
   * is the first, and otherwise an admin unless a role is given, since a server has one owner.
   */
  public Map<String, Object> setPassword(String email, String password, long now, String role) {
    init();
    String address = Js.lower(Js.trim(email));
    if (!EMAIL.matcher(address).find()) {
      throw new AccountError("Enter an email address", "email_invalid");
    }
    if (password.length() < MIN_PASSWORD) {
      throw new AccountError(
          "Use a password of at least " + MIN_PASSWORD + " characters",
          "password_short",
          Json.object("min", Integer.toString(MIN_PASSWORD)));
    }
    String hash = Crypto.hashPassword(password);
    Map<String, Object> existing = byEmail(address);
    if (existing != null) {
      db().run("UPDATE rl_users SET hash = ? WHERE id = ?", List.of(hash, id(existing)));
      existing.put("hash", hash);
      return existing;
    }
    boolean firstOne = count() == 0;
    String given = role != null ? role : firstOne ? "owner" : "admin";
    Map<String, Object> user =
        Json.object(
            "id",
            Crypto.hex(Crypto.randomBytes(12)),
            "email",
            address,
            "hash",
            hash,
            "role",
            given.equals("owner") && !firstOne ? "admin" : given,
            "createdAt",
            now,
            "twoFactor",
            false,
            "recoveryLeft",
            0L);
    db().run(
            "INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)",
            List.of(user.get("id"), user.get("email"), user.get("hash"), user.get("role"), now));
    return user;
  }

  private static Map<String, Object> inviteRow(Map<String, Object> r) {
    return Json.object(
        "id", Js.string(r.get("id")),
        "email", Js.string(r.get("email")),
        "role", roleFrom(r.get("role")),
        "invitedBy", Js.string(r.get("invited_by")),
        "createdAt", Js.num(Js.toNumber(r.get("created_at"))),
        "expiresAt", Js.num(Js.toNumber(r.get("expires_at"))));
  }

  /** Invites that still work, newest first. Expired ones are cleared on the way. */
  public List<Map<String, Object>> invites(long now) {
    init();
    db().run("DELETE FROM rl_invites WHERE expires_at <= ?", List.of(now));
    List<Map<String, Object>> out = new ArrayList<>();
    for (Map<String, Object> r :
        db().all("SELECT * FROM rl_invites ORDER BY created_at DESC, id")) {
      out.add(inviteRow(r));
    }
    return out;
  }

  /**
   * Invites someone to join with a role, and returns the code for their link as {invite, code}.
   * Asking again replaces the earlier invite, so only the newest link works.
   */
  public Map<String, Object> invite(String email, String role, String invitedBy, long now) {
    init();
    return turn(() -> inviteNow(email, role, invitedBy, now));
  }

  private Map<String, Object> inviteNow(String email, String role, String invitedBy, long now) {
    String address = Js.lower(Js.trim(email));
    if (!EMAIL.matcher(address).find()) {
      throw new AccountError("Enter an email address", "email_invalid");
    }
    if (byEmail(address) != null) {
      throw new AccountError(
          address + " already has an account", "account_exists", Json.object("email", address));
    }
    String code = Crypto.base64url(Crypto.randomBytes(24));
    Map<String, Object> invite =
        Json.object(
            "id", Crypto.hex(Crypto.randomBytes(12)),
            "email", address,
            "role", role,
            "invitedBy", invitedBy,
            "createdAt", now,
            "expiresAt", now + INVITE_MS);
    db().run("DELETE FROM rl_invites WHERE email = ?", List.of(address));
    db().run(
            "INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            List.of(
                invite.get("id"), address, role, codeHash(code), invitedBy, now, now + INVITE_MS));
    return Json.object("invite", invite, "code", code);
  }

  private static String codeHash(String code) {
    return Crypto.hex(Crypto.sha256(code));
  }

  /** The invite a link's code belongs to, while it still works. */
  public Map<String, Object> inviteByCode(String code, long now) {
    init();
    if (!INVITE_CODE.matcher(code).matches()) {
      return null;
    }
    Map<String, Object> r =
        first(
            db().all(
                    "SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?",
                    List.of(codeHash(code), now)));
    return r != null ? inviteRow(r) : null;
  }

  public boolean cancelInvite(String id) {
    init();
    int before = db().all("SELECT id FROM rl_invites WHERE id = ?", List.of(id)).size();
    db().run("DELETE FROM rl_invites WHERE id = ?", List.of(id));
    return before > 0;
  }

  /**
   * Turns an invite into an account with the password its person chose. The link then stops
   * working.
   */
  public Map<String, Object> acceptInvite(String code, String password, long now) {
    Map<String, Object> invite = inviteByCode(code, now);
    if (invite == null) {
      throw new AccountError(
          "This invite has expired or was already used. Ask for a new one.", "invite_gone");
    }
    String email = (String) invite.get("email");
    if (byEmail(email) != null) {
      throw new AccountError(
          email + " already has an account", "account_exists", Json.object("email", email));
    }
    Map<String, Object> user = setPassword(email, password, now, (String) invite.get("role"));
    db().run("DELETE FROM rl_invites WHERE id = ?", List.of(invite.get("id")));
    return user;
  }

  /** The account for an email and password, or null. Takes the same time either way. */
  public Map<String, Object> signIn(String email, String password) {
    Map<String, Object> user = byEmail(email);
    if (user == null) {
      String against = decoy;
      if (against == null) {
        against = Crypto.hashPassword(Crypto.hex(Crypto.randomBytes(16)));
        decoy = against;
      }
      Crypto.checkPassword(password, against);
      return null;
    }
    return Crypto.checkPassword(password, (String) user.get("hash")) ? user : null;
  }

  /**
   * A cookie value naming the user and when it expires, signed with the server's secret and the
   * user's password hash, so changing a password signs out every other browser.
   */
  public String sessionFor(Map<String, Object> user, long now) {
    long expires = now + SESSION_MS;
    String body = id(user) + "." + expires;
    return body + "." + sign(body, sessionKey(user));
  }

  /** The signed-in user for a cookie value, or null. */
  public Map<String, Object> fromSession(String value, long now) {
    String[] parts = value.split("\\.", -1);
    String id = parts[0];
    String expires = parts.length > 1 ? parts[1] : "";
    String signature = parts.length > 2 ? parts[2] : "";
    if (id.isEmpty() || expires.isEmpty() || signature.isEmpty() || !(Js.toNumber(expires) > now)) {
      return null;
    }
    Map<String, Object> user = byId(id);
    if (user == null) {
      return null;
    }
    return Crypto.sameText(sign(id + "." + expires, sessionKey(user)), signature) ? user : null;
  }

  /**
   * What a session is signed with: the password hash, and whether two-factor is on, so changing
   * either ends other sessions.
   */
  private static String sessionKey(Map<String, Object> user) {
    return user.get("hash") + (Boolean.TRUE.equals(user.get("twoFactor")) ? ".2fa" : "");
  }

  /**
   * A long-lived mark for a browser that signed in to an account. With it, failed tries by others
   * against that account cannot lock this browser out; the per-address limit still applies. A new
   * password withdraws it.
   */
  public String deviceFor(Map<String, Object> user) {
    return id(user) + "." + sign("device." + id(user), (String) user.get("hash"));
  }

  public boolean trustsDevice(String value, Map<String, Object> user) {
    String[] parts = value.split("\\.", -1);
    String id = parts[0];
    String signature = parts.length > 1 ? parts[1] : "";
    if (!id.equals(user.get("id")) || signature.isEmpty()) {
      return false;
    }
    return Crypto.sameText(sign("device." + id(user), (String) user.get("hash")), signature);
  }

  private String sign(String body, String hash) {
    return Crypto.signature(secret, body, hash);
  }
}
