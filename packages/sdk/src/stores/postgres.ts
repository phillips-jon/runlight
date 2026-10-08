import pg from "pg";
import { SqlStore, type Db } from "../store.js";

export interface PostgresOptions {
  /** A connection string, such as process.env.DATABASE_URL. */
  url?: string;
  /** Or a pool the app already has. Runlight never ends a pool it did not make. */
  pool?: pg.Pool;
  /** Connections in the pool Runlight makes. Default 5. */
  max?: number;
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
  const pool = options.pool ?? new pg.Pool({ connectionString: options.url, max: options.max ?? 5 });
  // An idle connection dropped by the server (a restart, a failover) is replaced on next use; unheard, it would end the process.
  if (owned) pool.on("error", (error) => console.error("Runlight: a Postgres connection was lost; it reconnects on the next query.", error.message));

  const db: Db = {
    dialect: "postgres",
    ...driver((sql, params) => pool.query(sql, params)),
    async exclusive<T>(fn: (db: Db) => Promise<T>): Promise<T> {
      const client = await pool.connect();
      try {
        await client.query("SELECT pg_advisory_lock($1)", [MIGRATION_LOCK]);
        try {
          return await fn({ dialect: "postgres", ...driver((sql, params) => client.query(sql, params)) });
        } finally {
          await client.query("SELECT pg_advisory_unlock($1)", [MIGRATION_LOCK]);
        }
      } finally {
        client.release();
      }
    },
    async transaction<T>(fn: (db: Db) => Promise<T>): Promise<T> {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const result = await fn({ dialect: "postgres", ...driver((sql, params) => client.query(sql, params)) });
        await client.query("COMMIT");
        return result;
      } catch (error) {
        await client.query("ROLLBACK").catch(() => {});
        throw error;
      } finally {
        client.release();
      }
    },
    async close(): Promise<void> {
      if (owned) await pool.end();
    },
  };
  return new SqlStore(db);
}
