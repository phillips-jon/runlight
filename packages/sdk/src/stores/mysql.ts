import mysql2 from "mysql2/promise";
import { SqlStore, type Db } from "../store.js";

export interface MysqlOptions {
  /** A connection URL, such as process.env.DATABASE_URL (mysql://user:password@host:3306/database). */
  url?: string;
  /** Or a pool the app already has, from mysql2/promise. Runlight never ends a pool it did not make. */
  pool?: mysql2.Pool;
  /** Connections in the pool Runlight makes. Default 10, and at least 2. */
  max?: number;
  /**
   * The longest one statement may run on the pool Runlight makes, in milliseconds, so a report over a
   * huge range cannot hold a connection for good. Default 120000. 0 means no limit. MySQL applies it
   * to reads only; MariaDB to every statement.
   */
  statementTimeout?: number;
}

/** How long a statement waits for a free connection before it gives up. */
const ACQUIRE_TIMEOUT = 10_000;

/**
 * SQL written for SQLite and Postgres, as MySQL and MariaDB read it: `?` becomes the value, escaped;
 * a "quoted" identifier is quoted with backticks; and a backslash inside 'text' is doubled, since
 * MySQL reads it as an escape where standard SQL takes it literally.
 */
export function mysqlText(sql: string, params: unknown[] = [], escape: (value: unknown) => string = (value) => mysql2.escape(value as mysql2.SqlValue)): string {
  let out = "";
  let n = 0;
  let quote: string | null = null;
  for (const ch of sql) {
    if (quote) {
      if (ch === quote) {
        quote = null;
        out += ch === '"' ? "`" : ch;
      } else if (quote === "'" && ch === "\\") out += "\\\\";
      else if (quote === '"' && ch === "`") out += "``";
      else out += ch;
    } else if (ch === "'" || ch === '"' || ch === "`") {
      quote = ch;
      out += ch === '"' ? "`" : ch;
    } else if (ch === "?") {
      if (n >= params.length) throw new Error("Runlight: a statement has more placeholders than values");
      out += escape(params[n++]);
    } else {
      out += ch;
    }
  }
  if (n !== params.length) throw new Error("Runlight: a statement has more values than placeholders");
  return out;
}

/** Sums and averages arrive as DECIMAL, which mysql2 gives as text; the store wants numbers. */
const typeCast = (field: { type: string; string(): string | null }, next: () => unknown): unknown => {
  if (field.type === "NEWDECIMAL" || field.type === "DECIMAL") {
    const text = field.string();
    return text === null ? null : Number(text);
  }
  return next();
};

type Connection = mysql2.PoolConnection;

/** Runs `fn` on a connection: one from the pool, or the one a lock or transaction holds. */
type On = <T>(fn: (conn: Connection) => Promise<T>) => Promise<T>;

function driver(on: On): Pick<Db, "all" | "run" | "affected"> {
  const query = (sql: string, params: unknown[] = []) =>
    on(async (conn) => (await conn.query({ sql: mysqlText(sql, params), typeCast } as mysql2.QueryOptions))[0]);
  return {
    async all<T>(sql: string, params?: unknown[]): Promise<T[]> {
      const result = await query(sql, params);
      return (Array.isArray(result) ? result : []) as T[];
    },
    async run(sql: string, params?: unknown[]): Promise<void> {
      await query(sql, params);
    },
    async affected(sql: string, params?: unknown[]): Promise<number> {
      const result = (await query(sql, params)) as { affectedRows?: number };
      return Number(result.affectedRows ?? 0);
    },
  };
}

/**
 * Runlight's tables in MySQL 8.4 or MariaDB 11.4 and later, through mysql2. Tables are prefixed `rl_`,
 * so the database can be the app's own. Text is utf8mb4 with a binary collation, so it compares and
 * sorts by code point, case and trailing spaces included, as SQLite and Postgres do.
 */
export function mysql(options: MysqlOptions): SqlStore {
  if (!options.pool && !options.url) throw new Error("Runlight: mysql() needs a url or a pool");
  const owned = !options.pool;
  const limit = options.max ?? (options.pool as unknown as { pool?: { config?: { connectionLimit?: number } } } | undefined)?.pool?.config?.connectionLimit ?? 10;
  // Settings changes hold one connection while they read through another, so one connection would wait on itself.
  if (limit < 2) throw new Error("Runlight: mysql() needs a pool of at least 2 connections");
  const timeout = options.statementTimeout ?? 120_000;
  const pool =
    options.pool ??
    mysql2.createPool({
      // mysql2 reads a mariadb:// URL the same once it is called mysql://.
      uri: options.url?.replace(/^mariadb:/, "mysql:"),
      connectionLimit: options.max ?? 10,
      waitForConnections: true,
      connectTimeout: 10_000,
      charset: "utf8mb4",
      enableKeepAlive: true,
    });

  const lost = (error: Error) => console.error("Runlight: a MySQL connection was lost; it reconnects on the next query.", error.message);
  /** Connections already set up for Runlight: the core connection behind each pooled one. */
  const ready = new WeakSet<object>();
  let mariadb: Promise<boolean> | null = null;

  /** The statement timeout as a session setting, which MySQL and MariaDB name differently. */
  async function limitStatements(conn: Connection, ms: number): Promise<void> {
    mariadb ??= conn.query("SELECT VERSION() AS v").then(
      ([rows]) => /mariadb/i.test(String((rows as Array<{ v: string }>)[0]?.v)),
      (error) => {
        mariadb = null;
        throw error;
      },
    );
    if (await mariadb) await conn.query(`SET SESSION max_statement_time = ${ms / 1000}`);
    else await conn.query(`SET SESSION max_execution_time = ${ms}`);
  }

  /** A connection of its own, waited for at most ACQUIRE_TIMEOUT, set up on its first use. */
  async function acquire(): Promise<Connection> {
    const conn = await new Promise<Connection>((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        settled = true;
        reject(new Error("Runlight: no MySQL connection was free within 10 seconds"));
      }, ACQUIRE_TIMEOUT);
      pool.getConnection().then(
        (c) => {
          if (settled) return c.release();
          settled = true;
          clearTimeout(timer);
          resolve(c);
        },
        (error) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          reject(error);
        },
      );
    });
    const core = (conn as unknown as { connection: object & { on(event: "error", fn: (error: Error) => void): void } }).connection;
    if (!ready.has(core)) {
      // A connection dropped by the server (a restart, a failover) while idle is replaced on next use; unheard, it would end the process.
      core.on("error", lost);
      try {
        if (owned && timeout > 0) await limitStatements(conn, timeout);
      } catch (error) {
        conn.destroy();
        throw error;
      }
      ready.add(core);
    }
    return conn;
  }

  /**
   * Runs `fn` with a connection of its own. One that broke, or that `fn` leaves in a state it could not
   * undo, is closed rather than pooled again.
   */
  const pooled: On = async (fn) => {
    const conn = await acquire();
    let keep = true;
    try {
      return await fn(conn);
    } catch (error) {
      if ((error as { fatal?: boolean }).fatal || (error as { unclean?: boolean }).unclean) keep = false;
      throw error;
    } finally {
      if (keep) conn.release();
      else conn.destroy();
    }
  };
  /** Every statement on the one connection already held. */
  const pinned = (conn: Connection): On => (fn) => fn(conn);
  /** Marks an error as leaving its connection unfit for the pool. */
  const unclean = (error: unknown) => Object.assign(error instanceof Error ? error : new Error(String(error)), { unclean: true });

  const db: Db = {
    dialect: "mysql",
    ...driver(pooled),
    async exclusive<T>(fn: (db: Db) => Promise<T>): Promise<T> {
      return pooled(async (conn) => {
        // One lock per database, so installs sharing a server do not wait on each other. Lock names are 64 characters at most.
        const name = "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))";
        for (;;) {
          const [rows] = await conn.query(`SELECT GET_LOCK(${name}, 5) AS ok`);
          const ok = (rows as Array<{ ok: unknown }>)[0]?.ok;
          if (ok === null || ok === undefined) throw new Error("Runlight: MySQL refused the lock for creating tables");
          if (Number(ok) === 1) break;
          // Not got within 5 seconds: another process is creating the tables. Ask again.
        }
        try {
          // An index on a big table takes a while to build, so the build may run past the statement timeout.
          if (owned && timeout > 0) await limitStatements(conn, 0);
          const result = await fn({ dialect: "mysql", ...driver(pinned(conn)) });
          if (owned && timeout > 0) await limitStatements(conn, timeout);
          return result;
        } catch (error) {
          // The session may be left without its statement timeout, so the connection goes.
          throw unclean(error);
        } finally {
          // A lost connection ends its session, and the lock with it.
          await conn.query(`DO RELEASE_LOCK(${name})`).catch(() => {});
        }
      });
    },
    async transaction<T>(fn: (db: Db) => Promise<T>): Promise<T> {
      return pooled(async (conn) => {
        // As Postgres does by default: each statement sees what was committed before it began, and
        // InnoDB takes no gap locks, so two writers to neighbouring rows do not deadlock.
        await conn.query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED");
        await conn.query("START TRANSACTION");
        try {
          const result = await fn({ dialect: "mysql", ...driver(pinned(conn)) });
          await conn.query("COMMIT");
          return result;
        } catch (error) {
          // A connection still in its transaction must never go back to the pool.
          const undone = await conn.query("ROLLBACK").then(
            () => true,
            () => false,
          );
          throw undone ? error : unclean(error);
        }
      });
    },
    async close(): Promise<void> {
      if (owned) await pool.end();
    },
  };
  return new SqlStore(db);
}
