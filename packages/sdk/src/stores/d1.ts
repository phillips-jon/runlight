import { SqlStore, type Db } from "../store.js";

/** The parts of Cloudflare's D1 binding Runlight uses, so there is no dependency on its types. */
export interface D1Database {
  prepare(sql: string): D1PreparedStatement;
}
interface D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
  run(): Promise<unknown>;
}

export interface D1Options {
  /** The D1 binding from your Worker's environment, such as env.DB. */
  database: D1Database;
}

/**
 * Runlight's tables in Cloudflare D1, for Workers and Pages.
 *
 *   export default { fetch: (request, env) => runlight({ store: d1({ database: env.DB }) }).routes().handler(request) };
 *
 * D1 has no interactive transactions, so a link import writes each link
 * step by step instead of all at once; a failure part way through leaves
 * the links written so far, and running the import again skips them.
 */
export function d1(options: D1Options): SqlStore {
  const stmt = (sql: string, params: unknown[]) => {
    const prepared = options.database.prepare(sql);
    return params.length ? prepared.bind(...params.map((p) => (p === undefined ? null : p))) : prepared;
  };
  const db: Db = {
    dialect: "sqlite",
    // A Worker may only send so many queries per request, so long jobs go in fewer, larger pieces.
    metered: true,
    async all<T>(sql: string, params: unknown[] = []): Promise<T[]> {
      return (await stmt(sql, params).all<T>()).results;
    },
    async run(sql: string, params: unknown[] = []): Promise<void> {
      await stmt(sql, params).run();
    },
    async transaction<T>(fn: (inner: Db) => Promise<T>): Promise<T> {
      return fn(db);
    },
  };
  return new SqlStore(db);
}
