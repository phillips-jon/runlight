import pg from "pg";
import { SqlStore, type Db } from "../store.js";

export interface PostgresOptions {
  /** A connection string, such as process.env.DATABASE_URL. */
  url?: string;
  /** Or a pool the app already has. Runlight never ends a pool it did not make. */
  pool?: pg.Pool;
  /** Connections in the pool Runlight makes. Default 10, and at least 2. */
  max?: number;
  /**
   * The longest one statement may run in the pool Runlight makes, in milliseconds, so a report over a
   * huge range cannot hold a connection for good. Default 120000. 0 means no limit.
   */
  statementTimeout?: number;
}

/** Arbitrary but fixed, so every Runlight process takes the same lock to create tables. */
const MIGRATION_LOCK = 7_331_906;

/** `?` placeholders to `$1, $2, ...`, leaving quoted text alone. */
export function numberPlaceholders(sql: string): string {
  let out = "";
  let n = 0;
  let quote: string | null = null;
  for (const ch of sql) {
    if (quote) {
      if (ch === quote) quote = null;
      out += ch;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
      out += ch;
    } else if (ch === "?") {
      out += `$${++n}`;
    } else {
      out += ch;
    }
  }
  return out;
}

function driver(query: (sql: string, params: unknown[]) => Promise<pg.QueryResult>): Pick<Db, "all" | "run"> {
  const cache = new Map<string, string>();
  const text = (sql: string) => {
    let numbered = cache.get(sql);
    if (numbered === undefined) {
      numbered = numberPlaceholders(sql);
      if (cache.size < 500) cache.set(sql, numbered);
    }
    return numbered;
  };
  return {
    async all<T>(sql: string, params: unknown[] = []): Promise<T[]> {
      return (await query(text(sql), params)).rows as T[];
    },
    async run(sql: string, params: unknown[] = []): Promise<void> {
      await query(text(sql), params);
    },
  };
}

/**
 * Runlight's tables in Postgres, through pg. Tables are prefixed `rl_`, so
 * the database can be the app's own. Counts and BIGINT columns arrive as
 * strings from pg; the store turns them into numbers.
 */
export function postgres(options: PostgresOptions): SqlStore {
  if (!options.pool && !options.url) throw new Error("Runlight: postgres() needs a url or a pool");
  const owned = !options.pool;
  // Settings changes hold one connection while they read through another, so one connection would wait on itself.
  if ((options.max ?? options.pool?.options.max ?? 10) < 2) throw new Error("Runlight: postgres() needs a pool of at least 2 connections");
  const timeout = options.statementTimeout ?? 120_000;
  const pool =
    options.pool ??
    new pg.Pool({
      connectionString: options.url,
      max: options.max ?? 10,
      // A tracker hit waits at most this long for a busy pool, rather than for good.
      connectionTimeoutMillis: 10_000,
      ...(timeout > 0 ? { statement_timeout: timeout } : {}),
    });
  // An idle connection dropped by the server (a restart, a failover) is replaced on next use; unheard, it would end the process.
  if (owned) pool.on("error", (error) => console.error("Runlight: a Postgres connection was lost; it reconnects on the next query.", error.message));

  /**
   * Runs `fn` with a connection of its own. While it is out of the pool, the pool no longer listens for
   * its errors, so a connection dropped between two statements would end the process; this listens
   * instead, and a broken connection is thrown away when it goes back.
   */
  async function withClient<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
    const client = await pool.connect();
    let lost: Error | undefined;
    const onError = (error: Error) => {
      lost = error;
      console.error("Runlight: a Postgres connection was lost while in use.", error.message);
    };
    client.on("error", onError);
    try {
      return await fn(client);
    } finally {
      client.off("error", onError);
      client.release(lost);
    }
  }

  const db: Db = {
    dialect: "postgres",
    ...driver((sql, params) => pool.query(sql, params)),
    async exclusive<T>(fn: (db: Db) => Promise<T>): Promise<T> {
      return withClient(async (client) => {
        // Asked for again and again rather than waited on: a waiting statement would hold up an index being
        // built CONCURRENTLY by whoever has the lock, and the two would wait on each other for good.
        while (!(await client.query("SELECT pg_try_advisory_lock($1) AS ok", [MIGRATION_LOCK])).rows[0]?.ok) {
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
        try {
          return await fn({ dialect: "postgres", ...driver((sql, params) => client.query(sql, params)) });
        } finally {
          // A lost connection ends its session, and the lock with it.
          await client.query("SELECT pg_advisory_unlock($1)", [MIGRATION_LOCK]).catch(() => {});
        }
      });
    },
    async transaction<T>(fn: (db: Db) => Promise<T>): Promise<T> {
      return withClient(async (client) => {
        await client.query("BEGIN");
        try {
          const result = await fn({ dialect: "postgres", ...driver((sql, params) => client.query(sql, params)) });
          await client.query("COMMIT");
          return result;
        } catch (error) {
          await client.query("ROLLBACK").catch(() => {});
          throw error;
        }
      });
    },
    async close(): Promise<void> {
      if (owned) await pool.end();
    },
  };
  return new SqlStore(db);
}
