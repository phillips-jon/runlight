import { SqlStore, type Db } from "../store.js";

export interface BunSqliteOptions {
  /** A file path, or ":memory:". */
  path: string;
}

type BunDatabase = {
  exec(sql: string): void;
  query(sql: string): { all(...params: unknown[]): unknown[]; run(...params: unknown[]): unknown };
  close(): void;
};

/**
 * Runlight's tables in a SQLite file, through Bun's built-in bun:sqlite, for
 * apps that run on Bun (better-sqlite3 does not load there).
 *
 *   import { bunSqlite } from "@runlight/sdk/bun";
 *   runlight({ store: bunSqlite({ path: "./data/runlight.db" }) })
 */
export function bunSqlite(options: BunSqliteOptions): SqlStore {
  let handle: BunDatabase | null = null;
  const open = async (): Promise<BunDatabase> => {
    if (!handle) {
      const { Database } = (await import(/* @vite-ignore */ "bun:sqlite" as string)) as { Database: new (path: string) => BunDatabase };
      handle = new Database(options.path);
      handle.exec("PRAGMA journal_mode = WAL");
      handle.exec("PRAGMA synchronous = NORMAL");
      handle.exec("PRAGMA busy_timeout = 5000");
    }
    return handle;
  };
  // Whole numbers as integers, so integer arithmetic in SQL stays integral.
  const bind = (params: unknown[]) => params.map((p) => (typeof p === "number" && Number.isSafeInteger(p) ? BigInt(p) : p === undefined ? null : p));
  const db: Db = {
    dialect: "sqlite",
    async all<T>(sql: string, params: unknown[] = []): Promise<T[]> {
      return (await open()).query(sql).all(...bind(params)) as T[];
    },
    async run(sql: string, params: unknown[] = []): Promise<void> {
      (await open()).query(sql).run(...bind(params));
    },
    async close(): Promise<void> {
      handle?.close();
      handle = null;
    },
  };
  return new SqlStore(db);
}
