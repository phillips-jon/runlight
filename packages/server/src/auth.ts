/**
 * Accounts for the standalone server: who may sign in, their password
 * hashes, and the signed cookie that keeps them signed in. Library mode
 * never uses this; the app there brings its own auth or a token.
 */
import { createHash, createHmac, randomBytes, scrypt as scryptCb, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";
import type { SqlStore } from "@runlight/sdk";

const scrypt = promisify(scryptCb) as (password: string, salt: Buffer, keylen: number, options: { N: number; r: number; p: number; maxmem: number }) => Promise<Buffer>;
const SCRYPT = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

export const SESSION_COOKIE = "runlight_session";
/** Thirty days, renewed on every sign-in. */
export const SESSION_MS = 30 * 86_400_000;
export const MIN_PASSWORD = 10;
/** The most sign-in keys the throttle remembers at once. */
const MAX_THROTTLED = 10_000;

/** An owner can do everything; a viewer can read every site's stats and change nothing. */
export type Role = "owner" | "viewer";

export interface User {
  id: string;
  email: string;
  hash: string;
  role: Role;
  createdAt: number;
}

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

const codeHash = (code: string) => createHash("sha256").update(code).digest("hex");

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scrypt(password, salt, 32, SCRYPT);
  return `scrypt$${salt.toString("base64url")}$${key.toString("base64url")}`;
}

export async function checkPassword(password: string, stored: string): Promise<boolean> {
  const [kind, salt, hash] = stored.split("$");
  if (kind !== "scrypt" || !salt || !hash) return false;
  const expected = Buffer.from(hash, "base64url");
  const key = await scrypt(password, Buffer.from(salt, "base64url"), expected.length, SCRYPT);
  return key.length === expected.length && timingSafeEqual(key, expected);
}

/** A password checked against nothing, so a wrong email takes as long as a wrong password. */
const DECOY = hashPassword(randomBytes(16).toString("hex"));

export class Accounts {
  private ready: Promise<void> | null = null;

  constructor(
    private readonly store: SqlStore,
    private readonly secret: string,
  ) {}

  private init(): Promise<void> {
    this.ready ??= (async () => {
      await this.store.db.run(`CREATE TABLE IF NOT EXISTS rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)`);
      // Roles came later; a table from before them gains the column, and its accounts stay owners.
      const columns = this.store.db.dialect === "postgres"
        ? await this.store.db.all(`SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = current_schema()`)
        : await this.store.db.all(`PRAGMA table_info(rl_users)`);
      if (!columns.some((c) => c.name === "role")) await this.store.db.run(`ALTER TABLE rl_users ADD COLUMN role TEXT NOT NULL DEFAULT 'owner'`);
      await this.store.db.run(
        `CREATE TABLE IF NOT EXISTS rl_invites (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, role TEXT NOT NULL, code_hash TEXT NOT NULL UNIQUE, invited_by TEXT NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)`,
      );
    })().catch((error) => {
        this.ready = null;
        throw error;
      });
    return this.ready;
  }

  private row(r: Record<string, unknown>): User {
    return { id: String(r.id), email: String(r.email), hash: String(r.hash), role: r.role === "viewer" ? "viewer" : "owner", createdAt: Number(r.created_at) };
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

  /** Changes a role. The last owner cannot become a viewer, or nobody could manage the server. */
  async setRole(id: string, role: Role): Promise<User> {
    const users = await this.list();
    const user = users.find((u) => u.id === id);
    if (!user) throw new RangeError("Unknown account");
    if (user.role === "owner" && role === "viewer" && users.filter((u) => u.role === "owner").length === 1) throw new RangeError("Keep at least one owner");
    await this.store.db.run(`UPDATE rl_users SET role = ? WHERE id = ?`, [role, id]);
    return { ...user, role };
  }

  /** Removes an account. The last owner cannot be removed. */
  async remove(id: string): Promise<void> {
    const users = await this.list();
    const user = users.find((u) => u.id === id);
    if (!user) throw new RangeError("Unknown account");
    if (user.role === "owner" && users.filter((u) => u.role === "owner").length === 1) throw new RangeError("Keep at least one owner");
    await this.store.db.run(`DELETE FROM rl_users WHERE id = ?`, [id]);
  }

  /** Makes an account, or sets a new password on an existing one. */
  async setPassword(email: string, password: string, now: number, role: Role = "owner"): Promise<User> {
    await this.init();
    const address = email.trim().toLowerCase();
    if (!EMAIL.test(address)) throw new RangeError("Enter an email address");
    if (password.length < MIN_PASSWORD) throw new RangeError(`Use a password of at least ${MIN_PASSWORD} characters`);
    const hash = await hashPassword(password);
    const existing = await this.byEmail(address);
    if (existing) {
      await this.store.db.run(`UPDATE rl_users SET hash = ? WHERE id = ?`, [hash, existing.id]);
      return { ...existing, hash };
    }
    const user: User = { id: randomBytes(12).toString("hex"), email: address, hash, role, createdAt: now };
    await this.store.db.run(`INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)`, [user.id, user.email, user.hash, user.role, user.createdAt]);
    return user;
  }

  private inviteRow(r: Record<string, unknown>): Invite {
    return { id: String(r.id), email: String(r.email), role: r.role === "viewer" ? "viewer" : "owner", invitedBy: String(r.invited_by), createdAt: Number(r.created_at), expiresAt: Number(r.expires_at) };
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
    const address = email.trim().toLowerCase();
    if (!EMAIL.test(address)) throw new RangeError("Enter an email address");
    if (await this.byEmail(address)) throw new RangeError(`${address} already has an account`);
    const code = randomBytes(24).toString("base64url");
    const invite: Invite = { id: randomBytes(12).toString("hex"), email: address, role, invitedBy, createdAt: now, expiresAt: now + INVITE_MS };
    await this.store.db.run(`DELETE FROM rl_invites WHERE email = ?`, [address]);
    await this.store.db.run(`INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`, [
      invite.id,
      invite.email,
      invite.role,
      codeHash(code),
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
    const [row] = await this.store.db.all(`SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?`, [codeHash(code), now]);
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
    if (!invite) throw new RangeError("This invite has expired or was already used. Ask for a new one.");
    if (await this.byEmail(invite.email)) throw new RangeError(`${invite.email} already has an account`);
    const user = await this.setPassword(invite.email, password, now, invite.role);
    await this.store.db.run(`DELETE FROM rl_invites WHERE id = ?`, [invite.id]);
    return user;
  }

  /** The account for an email and password, or null. Takes the same time either way. */
  async signIn(email: string, password: string): Promise<User | null> {
    const user = await this.byEmail(email);
    if (!user) {
      await checkPassword(password, await DECOY);
      return null;
    }
    return (await checkPassword(password, user.hash)) ? user : null;
  }

  /**
   * A cookie value naming the user and when it expires, signed with the
   * server's secret and the user's password hash, so changing a password
   * signs out every other browser.
   */
  sessionFor(user: User, now: number): string {
    const expires = now + SESSION_MS;
    const body = `${user.id}.${expires}`;
    return `${body}.${this.sign(body, user.hash)}`;
  }

  /** The signed-in user for a cookie value, or null. */
  async fromSession(value: string, now: number): Promise<User | null> {
    const [id, expires, signature] = value.split(".");
    if (!id || !expires || !signature || !(Number(expires) > now)) return null;
    const user = await this.byId(id);
    if (!user) return null;
    const expected = Buffer.from(this.sign(`${id}.${expires}`, user.hash));
    const given = Buffer.from(signature);
    return expected.length === given.length && timingSafeEqual(expected, given) ? user : null;
  }

  private sign(body: string, hash: string): string {
    return createHmac("sha256", this.secret).update(`${body}.${hash}`).digest("base64url");
  }
}

/** Counts failed sign-ins under a key and refuses more than a few in a while. */
export class Throttle {
  private readonly failures = new Map<string, { count: number; until: number }>();

  constructor(
    private readonly limit = 10,
    private readonly windowMs = 15 * 60_000,
  ) {}

  blocked(key: string, now: number): boolean {
    const entry = this.failures.get(key);
    if (!entry || entry.until <= now) return false;
    return entry.count >= this.limit;
  }

  fail(key: string, now: number): void {
    const entry = this.failures.get(key);
    if (!entry || entry.until <= now) {
      this.failures.delete(key);
      this.failures.set(key, { count: 1, until: now + this.windowMs });
    } else entry.count++;
    // Expired entries go first, then the oldest, so the map has a hard ceiling.
    if (this.failures.size > MAX_THROTTLED) {
      for (const [k, v] of this.failures) if (v.until <= now) this.failures.delete(k);
      for (const k of this.failures.keys()) {
        if (this.failures.size <= MAX_THROTTLED) break;
        this.failures.delete(k);
      }
    }
  }

  clear(key: string): void {
    this.failures.delete(key);
  }
}
