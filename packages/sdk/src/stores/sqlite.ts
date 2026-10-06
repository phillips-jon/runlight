import Database from "better-sqlite3";
import { SqlStore, type Db } from "../store.js";

export interface SqliteOptions {
  /** A file path, or ":memory:". */
  path: string;
}

/**
 * Runlight's tables in a SQLite file, through better-sqlite3. Tables are
 * prefixed `rl_`, so the file can be the app's own database.
 */
export function sqlite(options: SqliteOptions): SqlStore {
  let handle: Database.Database | null = null;
  const open = (): Database.Database => {
    if (!handle) {
      handle = new Database(options.path);
      handle.pragma("journal_mode = WAL");
      handle.pragma("synchronous = NORMAL");
      handle.pragma("busy_timeout = 5000");
    }
    return handle;
  };
  // better-sqlite3 binds every JS number as REAL, which turns integer
  // arithmetic in SQL (minute buckets, for one) into fractions.
  const bind = (params: unknown[]) => params.map((p) => (typeof p === "number" && Number.isSafeInteger(p) ? BigInt(p) : p));
  const db: Db = {
    dialect: "sqlite",
    async all<T>(sql: string, params: unknown[] = []): Promise<T[]> {
      return open().prepare(sql).all(...bind(params)) as T[];
    },
    async run(sql: string, params: unknown[] = []): Promise<void> {
      open().prepare(sql).run(...bind(params));
    },
    async close(): Promise<void> {
      handle?.close();
      handle = null;
    },
  };
  return new SqlStore(db);
}
