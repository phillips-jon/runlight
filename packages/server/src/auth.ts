/**
 * Accounts for the standalone server: who may sign in, their password
 * hashes, and the signed cookie that keeps them signed in. Library mode
 * never uses this; the app there brings its own auth or a token.
 */
import { createHmac, randomBytes, scrypt as scryptCb, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";
import type { SqlStore } from "@runlight/sdk";

const scrypt = promisify(scryptCb) as (password: string, salt: Buffer, keylen: number, options: { N: number; r: number; p: number; maxmem: number }) => Promise<Buffer>;
const SCRYPT = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

export const SESSION_COOKIE = "runlight_session";
/** Thirty days, renewed on every sign-in. */
export const SESSION_MS = 30 * 86_400_000;
export const MIN_PASSWORD = 10;

export interface User {
  id: string;
  email: string;
  hash: string;
  createdAt: number;
}

const EMAIL = /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/;

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
    this.ready ??= this.store.db
      .run(`CREATE TABLE IF NOT EXISTS rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)`)
      .catch((error) => {
        this.ready = null;
        throw error;
      });
    return this.ready;
  }

  private row(r: Record<string, unknown>): User {
    return { id: String(r.id), email: String(r.email), hash: String(r.hash), createdAt: Number(r.created_at) };
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

  /** Makes an account, or sets a new password on an existing one. */
  async setPassword(email: string, password: string, now: number): Promise<User> {
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
    const user: User = { id: randomBytes(12).toString("hex"), email: address, hash, createdAt: now };
    await this.store.db.run(`INSERT INTO rl_users (id, email, hash, created_at) VALUES (?, ?, ?, ?)`, [user.id, user.email, user.hash, user.createdAt]);
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

/** Counts failed sign-ins by address and refuses more than a few in a while. */
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
    if (!entry || entry.until <= now) this.failures.set(key, { count: 1, until: now + this.windowMs });
    else entry.count++;
    // Old entries go, so the map cannot grow without end.
    if (this.failures.size > 10_000) for (const [k, v] of this.failures) if (v.until <= now) this.failures.delete(k);
  }

  clear(key: string): void {
    this.failures.delete(key);
  }
}
