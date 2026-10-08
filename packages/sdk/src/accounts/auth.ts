/**
 * Accounts: who may sign in, their password hashes, two-factor, invites, and the signed cookie that keeps them
 * signed in. The standalone server always has them, and an app turns them on with routes({ accounts: true }).
 */
import type { SqlStore } from "../store.js";
import { base64url, checkPassword, hashPassword, hex, hmac, randomBytes, sameText, sealText, sha256, unsealText } from "./crypto.js";

export { checkPassword, hashPassword };

/**
 * A problem with an account change, to show the person making it. A RangeError, as before, with a
 * `code` and `params` the dashboard words in its own language.
 */
export class AccountError extends RangeError {
  constructor(
    message: string,
    readonly code: string,
    readonly params: Record<string, string> = {},
  ) {
    super(message);
  }
}

export const SESSION_COOKIE = "runlight_session";
/** Thirty days, renewed on every sign-in. */
export const SESSION_MS = 30 * 86_400_000;
export const MIN_PASSWORD = 10;
/** The most sign-in keys the throttle remembers at once. */
const MAX_THROTTLED = 10_000;

/**
 * The owner can do everything, and nobody else can remove them or change their role; they can hand ownership to an
 * admin. An admin can do everything the owner can apart from that. A member changes sites, goals, links, and the
 * rest, but not people, the mail service, the assistant's settings, or deleting a site. A viewer reads every site's
 * stats and changes nothing.
 */
export type Role = "owner" | "admin" | "member" | "viewer";
const ROLES: readonly Role[] = ["owner", "admin", "member", "viewer"];
/** A stored role read back; anything unknown reads as a viewer, the least it could be. */
const roleFrom = (value: unknown): Role => (ROLES.includes(value as Role) ? (value as Role) : "viewer");

export interface User {
  id: string;
  email: string;
  hash: string;
  role: Role;
  createdAt: number;
  /** Whether sign-in also asks for a code from an authenticator app. */
  twoFactor: boolean;
  /** Recovery codes not yet used. */
  recoveryLeft: number;
}

// Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.
const STEP_MS = 30_000;
const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function base32(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

function unbase32(text: string): Uint8Array {
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const c of text.replace(/=+$/, "").toUpperCase()) {
    const i = BASE32.indexOf(c);
    if (i < 0) continue;
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

/** The six-digit code for a secret at a time step. */
export async function totp(secret: string, step: number): Promise<string> {
  const counter = new Uint8Array(8);
  new DataView(counter.buffer).setBigUint64(0, BigInt(step));
  const mac = await hmac("SHA-1", unbase32(secret), counter);
  const at = mac[mac.length - 1]! & 15;
  const n = ((mac[at]! & 127) << 24) | (mac[at + 1]! << 16) | (mac[at + 2]! << 8) | mac[at + 3]!;
  return String(n % 1_000_000).padStart(6, "0");
}

/** The address an authenticator app reads from the QR code. */
export function otpauthUri(secret: string, email: string, host: string): string {
  const label = encodeURIComponent(`Runlight (${host}):${email}`);
  return `otpauth://totp/${label}?secret=${secret}&issuer=${encodeURIComponent(`Runlight (${host})`)}&algorithm=SHA1&digits=6&period=30`;
}

/** Ten one-use recovery codes, like "k7dq-2mfa". */
function recoveryCodes(): string[] {
  return Array.from({ length: 10 }, () => {
    const raw = base32(randomBytes(5)).toLowerCase();
    return `${raw.slice(0, 4)}-${raw.slice(4, 8)}`;
  });
}

const recoveryHash = async (code: string) => hex(await sha256(code.replace(/[^a-z0-9]/gi, "").toLowerCase()));

const EMAIL = /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/;

/** How long an invite link works. */
export const INVITE_MS = 7 * 86_400_000;

/** Someone asked to join, until they choose a password. Only a hash of the link's code is kept. */
export interface Invite {
  id: string;
  email: string;
  role: Role;
  invitedBy: string;
  createdAt: number;
  expiresAt: number;
}

const codeHash = async (code: string) => hex(await sha256(code));

/** A password checked against nothing, so a wrong email takes as long as a wrong password. Made when first needed. */
let decoy: Promise<string> | null = null;

export class Accounts {
  private ready: Promise<void> | null = null;

  constructor(
    private readonly store: SqlStore,
    private readonly secret: string,
  ) {}

  /**
   * Changes to who has an account take turns, in this process and, on Postgres, across processes, so two
   * owners demoting each other at once cannot leave none, and a double-clicked invite makes one.
   */
  private turn<T>(fn: () => Promise<T>): Promise<T> {
    const run = () => (this.store.db.exclusive ? this.store.db.exclusive(() => fn()) : fn());
    const next = this.queue.then(run, run);
    this.queue = next.catch(() => {});
    return next;
  }

  private queue: Promise<unknown> = Promise.resolve();

  private init(): Promise<void> {
    // Several processes starting at once create the tables one at a time.
    const create = async () => {
      await this.store.db.run(`CREATE TABLE IF NOT EXISTS rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)`);
      // Roles came later; a table from before them gains the column, and its accounts stay owners.
      const columns = this.store.db.dialect === "postgres"
        ? await this.store.db.all(`SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = current_schema()`)
        : await this.store.db.all(`PRAGMA table_info(rl_users)`);
      if (!columns.some((c) => c.name === "role")) await this.store.db.run(`ALTER TABLE rl_users ADD COLUMN role TEXT NOT NULL DEFAULT 'owner'`);
      // Two-factor came later still: the secret (sealed), one being set up, recovery code hashes, and the last code's step.
      for (const [name, type] of [["totp_secret", "TEXT"], ["totp_pending", "TEXT"], ["totp_recovery", "TEXT"], ["totp_step", "BIGINT"]] as const) {
        if (!columns.some((c) => c.name === name)) await this.store.db.run(`ALTER TABLE rl_users ADD COLUMN ${name} ${type}`);
      }
      await this.store.db.run(
        `CREATE TABLE IF NOT EXISTS rl_invites (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, role TEXT NOT NULL, code_hash TEXT NOT NULL UNIQUE, invited_by TEXT NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)`,
      );
      // A server has one owner. One from before, with several, keeps the first and the rest become admins,
      // who can still do everything but remove the owner. Invites to join as an owner become invites as an admin.
      const owners = await this.store.db.all(`SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id`);
      for (const extra of owners.slice(1)) await this.store.db.run(`UPDATE rl_users SET role = 'admin' WHERE id = ?`, [String(extra.id)]);
      await this.store.db.run(`UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'`);
    };
    this.ready ??= (this.store.db.exclusive ? this.store.db.exclusive(create) : create()).catch((error) => {
        this.ready = null;
        throw error;
      });
    return this.ready;
  }

  private row(r: Record<string, unknown>): User {
    const recovery = r.totp_recovery ? (JSON.parse(String(r.totp_recovery)) as string[]) : [];
    return {
      id: String(r.id),
      email: String(r.email),
      hash: String(r.hash),
      role: roleFrom(r.role),
      createdAt: Number(r.created_at),
      twoFactor: Boolean(r.totp_secret),
      recoveryLeft: recovery.length,
    };
  }

  /** Seals a two-factor secret with the install's secret, so the database alone cannot make codes. */
  private seal(text: string): Promise<string> {
    return sealText(text, this.secret);
  }

  private unseal(sealed: string): Promise<string | null> {
    return unsealText(sealed, this.secret);
  }

  /** Starts turning on two-factor: a new secret, kept aside until a code from it is confirmed. */
  async startTwoFactor(id: string): Promise<string> {
    await this.init();
    const secret = base32(randomBytes(20));
    await this.store.db.run(`UPDATE rl_users SET totp_pending = ? WHERE id = ?`, [await this.seal(secret), id]);
    return secret;
  }

  /** Turns two-factor on once a code from the new secret checks out, and returns ten recovery codes, shown once. */
  async confirmTwoFactor(id: string, code: string, now: number): Promise<string[] | null> {
    await this.init();
    const [row] = await this.store.db.all(`SELECT totp_pending FROM rl_users WHERE id = ?`, [id]);
    const secret = row?.totp_pending ? await this.unseal(String(row.totp_pending)) : null;
    const step = secret ? await matchStep(secret, code, now, -1) : null;
    if (step === null) return null;
    const recovery = recoveryCodes();
    // The code that turned it on is not marked used, so signing in again at once with it works.
    await this.store.db.run(`UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?`, [
      await this.seal(secret!),
      JSON.stringify(await Promise.all(recovery.map(recoveryHash))),
      id,
    ]);
    return recovery;
  }

  /** New recovery codes in place of the old ones. */
  async newRecoveryCodes(id: string): Promise<string[]> {
    await this.init();
    const recovery = recoveryCodes();
    await this.store.db.run(`UPDATE rl_users SET totp_recovery = ? WHERE id = ?`, [JSON.stringify(await Promise.all(recovery.map(recoveryHash))), id]);
    return recovery;
  }

  /** Drops a set-up left half done, after too many wrong codes, so it must start again with the password. */
  async cancelTwoFactorSetup(id: string): Promise<void> {
    await this.init();
    await this.store.db.run(`UPDATE rl_users SET totp_pending = NULL WHERE id = ?`, [id]);
  }

  async disableTwoFactor(id: string): Promise<void> {
    await this.init();
    await this.store.db.run(`UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?`, [id]);
  }

  /**
   * Checks a six-digit code, or a recovery code, for an account with two-factor on.
   * A code works once: one already used, or older, is refused, and a recovery code is crossed off.
   */
  async checkSecondFactor(id: string, code: string, now: number): Promise<boolean> {
    // One check at a time per account, so two sign-ins at once cannot both use the same code.
    const before = this.checking.get(id) ?? Promise.resolve();
    const turn = before.then(() => this.checkSecondFactorNow(id, code, now));
    this.checking.set(id, turn.catch(() => {}));
    try {
      return await turn;
    } finally {
      if (this.checking.get(id) === turn) this.checking.delete(id);
    }
  }

  private readonly checking = new Map<string, Promise<unknown>>();

  private async checkSecondFactorNow(id: string, code: string, now: number): Promise<boolean> {
    await this.init();
    const [row] = await this.store.db.all(`SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?`, [id]);
    if (!row?.totp_secret) return false;
    const given = code.trim();
    if (/^\d{6}$/.test(given.replace(/\s/g, ""))) {
      const secret = await this.unseal(String(row.totp_secret));
      const step = secret ? await matchStep(secret, given.replace(/\s/g, ""), now, row.totp_step === null || row.totp_step === undefined ? -1 : Number(row.totp_step)) : null;
      if (step === null) return false;
      await this.store.db.run(`UPDATE rl_users SET totp_step = ? WHERE id = ?`, [step, id]);
      return true;
    }
    const hashes = row.totp_recovery ? (JSON.parse(String(row.totp_recovery)) as string[]) : [];
    const at = hashes.indexOf(await recoveryHash(given));
    if (at < 0) return false;
    hashes.splice(at, 1);
    await this.store.db.run(`UPDATE rl_users SET totp_recovery = ? WHERE id = ?`, [JSON.stringify(hashes), id]);
    return true;
  }

  /**
   * A short-lived ticket naming an account whose password checked out and
   * which still owes a code. Signed like a session, so it cannot be made up.
   */
  pendingFor(user: User, now: number): Promise<string> {
    return this.ticket("pending", user, now + 5 * 60_000);
  }

  /**
   * A ticket that looks and acts like pendingFor's, except that no code ever
   * passes with it. A wrong password gets one once an account with
   * two-factor has had too many, so the answer never tells a right password.
   */
  decoyFor(user: User, now: number): Promise<string> {
    return this.ticket("decoy", user, now + 5 * 60_000);
  }

  /** The account a code-step ticket names, and whether a right code may sign in with it. */
  async fromPending(value: string, now: number): Promise<{ user: User; real: boolean } | null> {
    const user = await this.fromTicket("pending", value, now);
    if (user) return { user, real: true };
    const decoy = await this.fromTicket("decoy", value, now);
    return decoy ? { user: decoy, real: false } : null;
  }

  /** A ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it. */
  linkFor(user: User, now: number): Promise<string> {
    return this.ticket("link", user, now + 15 * 60_000);
  }

  /**
   * The account a sign-in link is for. A link works once: using it withdraws it, and every link sent
   * before it. Uses take turns, so a link opened twice at once lets one in.
   */
  async fromLink(value: string, now: number): Promise<User | null> {
    const user = await this.fromTicket("link", value, now);
    if (!user) return null;
    const expires = Number(value.split(".")[1]);
    return this.turn(async () => {
      const key = `login-link-used:${user.id}`;
      if (expires <= Number((await this.store.setting(key)) ?? 0)) return null;
      await this.store.setSetting(key, String(expires));
      return user;
    });
  }

  private async ticket(kind: string, user: User, expires: number): Promise<string> {
    const body = `${user.id}.${expires}`;
    return `${body}.${await this.sign(`${kind}.${body}`, user.hash)}`;
  }

  private async fromTicket(kind: string, value: string, now: number): Promise<User | null> {
    const [id, expires, signature] = value.split(".");
    if (!id || !expires || !signature || !(Number(expires) > now)) return null;
    const user = await this.byId(id);
    if (!user) return null;
    return sameText(await this.sign(`${kind}.${id}.${expires}`, user.hash), signature) ? user : null;
  }

  async count(): Promise<number> {
    await this.init();
    const [row] = await this.store.db.all(`SELECT COUNT(*) AS n FROM rl_users`);
    return Number(row?.n ?? 0);
  }

  async byEmail(email: string): Promise<User | null> {
    await this.init();
    const [row] = await this.store.db.all(`SELECT * FROM rl_users WHERE email = ?`, [email.trim().toLowerCase()]);
    return row ? this.row(row) : null;
  }

  async byId(id: string): Promise<User | null> {
    await this.init();
    const [row] = await this.store.db.all(`SELECT * FROM rl_users WHERE id = ?`, [id]);
    return row ? this.row(row) : null;
  }

  async list(): Promise<User[]> {
    await this.init();
    return (await this.store.db.all(`SELECT * FROM rl_users ORDER BY created_at`)).map((r) => this.row(r));
  }

  /** Changes a role. The owner's never changes here, and nobody becomes the owner here: see handOver(). */
  async setRole(id: string, role: Role): Promise<User> {
    // The tables first: making them takes the same lock as a turn.
    await this.init();
    return this.turn(async () => {
      const user = (await this.list()).find((u) => u.id === id);
      if (!user) throw new AccountError("Unknown account", "unknown_account");
      if (user.role === "owner") throw new AccountError("Only the owner can change their own role, by handing ownership to an admin", "owner_protected");
      if (role === "owner") throw new AccountError("Ownership is handed over by the owner", "owner_hand_over");
      await this.store.db.run(`UPDATE rl_users SET role = ? WHERE id = ?`, [role, id]);
      return { ...user, role };
    });
  }

  /** Makes an admin the owner, and the owner an admin. */
  async handOver(from: string, to: string): Promise<void> {
    await this.init();
    return this.turn(async () => {
      const users = await this.list();
      const owner = users.find((u) => u.id === from);
      const next = users.find((u) => u.id === to);
      if (!owner || owner.role !== "owner") throw new AccountError("Only the owner can hand over ownership", "owner_hand_over");
      if (!next) throw new AccountError("Unknown account", "unknown_account");
      if (next.role !== "admin") throw new AccountError("Make them an admin first", "owner_needs_admin");
      await this.store.db.run(`UPDATE rl_users SET role = 'owner' WHERE id = ?`, [to]);
      await this.store.db.run(`UPDATE rl_users SET role = 'admin' WHERE id = ?`, [from]);
    });
  }

  /** Removes an account. The owner cannot be removed. */
  async remove(id: string): Promise<void> {
    // The tables first: making them takes the same lock as a turn.
    await this.init();
    return this.turn(async () => {
      const user = (await this.list()).find((u) => u.id === id);
      if (!user) throw new AccountError("Unknown account", "unknown_account");
      if (user.role === "owner") throw new AccountError("The owner cannot be removed", "owner_protected");
      await this.store.db.run(`DELETE FROM rl_users WHERE id = ?`, [id]);
      await this.store.setSetting(`login-link-used:${id}`, null);
    });
  }

  /**
   * Makes an account, or sets a new password on an existing one. A new account is the owner when it is the first,
   * and otherwise an admin unless a role is given, since a server has one owner.
   */
  async setPassword(email: string, password: string, now: number, role?: Role): Promise<User> {
    await this.init();
    const address = email.trim().toLowerCase();
    if (!EMAIL.test(address)) throw new AccountError("Enter an email address", "email_invalid");
    if (password.length < MIN_PASSWORD) throw new AccountError(`Use a password of at least ${MIN_PASSWORD} characters`, "password_short", { min: String(MIN_PASSWORD) });
    const hash = await hashPassword(password);
    const existing = await this.byEmail(address);
    if (existing) {
      await this.store.db.run(`UPDATE rl_users SET hash = ? WHERE id = ?`, [hash, existing.id]);
      return { ...existing, hash };
    }
    const first = (await this.count()) === 0;
    const given = role ?? (first ? "owner" : "admin");
    const user: User = { id: hex(randomBytes(12)), email: address, hash, role: given === "owner" && !first ? "admin" : given, createdAt: now, twoFactor: false, recoveryLeft: 0 };
    await this.store.db.run(`INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)`, [user.id, user.email, user.hash, user.role, user.createdAt]);
    return user;
  }

  private inviteRow(r: Record<string, unknown>): Invite {
    return { id: String(r.id), email: String(r.email), role: roleFrom(r.role), invitedBy: String(r.invited_by), createdAt: Number(r.created_at), expiresAt: Number(r.expires_at) };
  }

  /** Invites that still work, newest first. Expired ones are cleared on the way. */
  async invites(now: number): Promise<Invite[]> {
    await this.init();
    await this.store.db.run(`DELETE FROM rl_invites WHERE expires_at <= ?`, [now]);
    return (await this.store.db.all(`SELECT * FROM rl_invites ORDER BY created_at DESC`)).map((r) => this.inviteRow(r));
  }

  /**
   * Invites someone to join with a role, and returns the code for their link.
   * Asking again replaces the earlier invite, so only the newest link works.
   */
  async invite(email: string, role: Role, invitedBy: string, now: number): Promise<{ invite: Invite; code: string }> {
    await this.init();
    return this.turn(() => this.inviteNow(email, role, invitedBy, now));
  }

  private async inviteNow(email: string, role: Role, invitedBy: string, now: number): Promise<{ invite: Invite; code: string }> {
    const address = email.trim().toLowerCase();
    if (!EMAIL.test(address)) throw new AccountError("Enter an email address", "email_invalid");
    if (await this.byEmail(address)) throw new AccountError(`${address} already has an account`, "account_exists", { email: address });
    const code = base64url(randomBytes(24));
    const invite: Invite = { id: hex(randomBytes(12)), email: address, role, invitedBy, createdAt: now, expiresAt: now + INVITE_MS };
    await this.store.db.run(`DELETE FROM rl_invites WHERE email = ?`, [address]);
    await this.store.db.run(`INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`, [
      invite.id,
      invite.email,
      invite.role,
      await codeHash(code),
      invite.invitedBy,
      invite.createdAt,
      invite.expiresAt,
    ]);
    return { invite, code };
  }

  /** The invite a link's code belongs to, while it still works. */
  async inviteByCode(code: string, now: number): Promise<Invite | null> {
    await this.init();
    if (!/^[A-Za-z0-9_-]{20,64}$/.test(code)) return null;
    const [row] = await this.store.db.all(`SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?`, [await codeHash(code), now]);
    return row ? this.inviteRow(row) : null;
  }

  async cancelInvite(id: string): Promise<boolean> {
    await this.init();
    const before = (await this.store.db.all(`SELECT id FROM rl_invites WHERE id = ?`, [id])).length;
    await this.store.db.run(`DELETE FROM rl_invites WHERE id = ?`, [id]);
    return before > 0;
  }

  /** Turns an invite into an account with the password its person chose. The link then stops working. */
  async acceptInvite(code: string, password: string, now: number): Promise<User> {
    const invite = await this.inviteByCode(code, now);
    if (!invite) throw new AccountError("This invite has expired or was already used. Ask for a new one.", "invite_gone");
    if (await this.byEmail(invite.email)) throw new AccountError(`${invite.email} already has an account`, "account_exists", { email: invite.email });
    const user = await this.setPassword(invite.email, password, now, invite.role);
    await this.store.db.run(`DELETE FROM rl_invites WHERE id = ?`, [invite.id]);
    return user;
  }

  /** The account for an email and password, or null. Takes the same time either way. */
  async signIn(email: string, password: string): Promise<User | null> {
    const user = await this.byEmail(email);
    if (!user) {
      await checkPassword(password, await (decoy ??= hashPassword(hex(randomBytes(16)))));
      return null;
    }
    return (await checkPassword(password, user.hash)) ? user : null;
  }

  /**
   * A cookie value naming the user and when it expires, signed with the
   * server's secret and the user's password hash, so changing a password
   * signs out every other browser.
   */
  async sessionFor(user: User, now: number): Promise<string> {
    const expires = now + SESSION_MS;
    const body = `${user.id}.${expires}`;
    return `${body}.${await this.sign(body, this.sessionKey(user))}`;
  }

  /** The signed-in user for a cookie value, or null. */
  async fromSession(value: string, now: number): Promise<User | null> {
    const [id, expires, signature] = value.split(".");
    if (!id || !expires || !signature || !(Number(expires) > now)) return null;
    const user = await this.byId(id);
    if (!user) return null;
    return sameText(await this.sign(`${id}.${expires}`, this.sessionKey(user)), signature) ? user : null;
  }

  /** What a session is signed with: the password hash, and whether two-factor is on, so changing either ends other sessions. */
  private sessionKey(user: User): string {
    return `${user.hash}${user.twoFactor ? ".2fa" : ""}`;
  }

  /**
   * A long-lived mark for a browser that signed in to an account. With it, failed tries by others
   * against that account cannot lock this browser out; the per-address limit still applies.
   * A new password withdraws it.
   */
  async deviceFor(user: User): Promise<string> {
    return `${user.id}.${await this.sign(`device.${user.id}`, user.hash)}`;
  }

  async trustsDevice(value: string, user: User): Promise<boolean> {
    const [id, signature] = value.split(".");
    if (id !== user.id || !signature) return false;
    return sameText(await this.sign(`device.${user.id}`, user.hash), signature);
  }

  private async sign(body: string, hash: string): Promise<string> {
    return base64url(await hmac("SHA-256", this.secret, `${body}.${hash}`));
  }
}

/** The time step a code matches, one step either side for clocks that drift, newer than `after`; else null. */
async function matchStep(secret: string, code: string, now: number, after: number): Promise<number | null> {
  const current = Math.floor(now / STEP_MS);
  for (const step of [current, current - 1, current + 1]) {
    if (step > after && (await totp(secret, step)) === code) return step;
  }
  return null;
}

/**
 * Counts failed sign-ins under a key and refuses more than a few in a while.
 * Keys are hashed with a key made at start, so the map never holds an
 * address or an email as it was given.
 */
export class Throttle {
  private readonly failures = new Map<string, { count: number; until: number }>();
  private readonly salt = randomBytes(16);

  constructor(
    private readonly limit = 10,
    private readonly windowMs = 15 * 60_000,
  ) {}

  private async id(key: string): Promise<string> {
    return base64url(await hmac("SHA-256", this.salt, key)).slice(0, 22);
  }

  async blocked(key: string, now: number): Promise<boolean> {
    return this.isBlocked(await this.id(key), now);
  }

  private isBlocked(id: string, now: number): boolean {
    const entry = this.failures.get(id);
    if (!entry || entry.until <= now) return false;
    return entry.count >= this.limit;
  }

  /**
   * Counts a try before the slow check it guards, so a burst that arrives
   * while earlier tries are still being checked cannot get past the limit.
   * False, counting nothing, when the key is already at its limit. A try
   * that turns out right is taken back with forgive(). The hash is worked out
   * first, and the check and the count then happen with nothing in between.
   */
  async take(key: string, now: number): Promise<boolean> {
    const id = await this.id(key);
    if (this.isBlocked(id, now)) return false;
    this.count(id, now);
    return true;
  }

  /** Takes back one counted try, for one that turned out right. */
  async forgive(key: string): Promise<void> {
    const entry = this.failures.get(await this.id(key));
    if (entry && entry.count > 0) entry.count--;
  }

  async fail(key: string, now: number): Promise<void> {
    this.count(await this.id(key), now);
  }

  private count(id: string, now: number): void {
    const entry = this.failures.get(id);
    if (!entry || entry.until <= now) {
      this.failures.delete(id);
      this.failures.set(id, { count: 1, until: now + this.windowMs });
    } else entry.count++;
    // Expired entries go first, then the oldest that are not blocked, and blocked ones last, so the map
    // has a hard ceiling and a flood of made-up names cannot wipe out a real block.
    if (this.failures.size > MAX_THROTTLED) {
      for (const [k, v] of this.failures) if (v.until <= now) this.failures.delete(k);
      for (const [k, v] of this.failures) {
        if (this.failures.size <= MAX_THROTTLED) break;
        if (v.count < this.limit) this.failures.delete(k);
      }
      for (const k of this.failures.keys()) {
        if (this.failures.size <= MAX_THROTTLED) break;
        this.failures.delete(k);
      }
    }
  }

  async clear(key: string): Promise<void> {
    this.failures.delete(await this.id(key));
  }
}
