import type { Client, InStatement, Transaction } from "@libsql/client";
import { SqlStore, type Db } from "../store.js";

export interface LibsqlOptions {
  /** A client the app already has, from createClient() in @libsql/client (or @libsql/client/web on the edge). */
  client: Client;
}

type Executor = Pick<Client, "execute"> | Transaction;

/** Rows as plain objects, with whole numbers as numbers rather than bigints. */
function rows<T>(result: { rows: unknown[]; columns: string[] }): T[] {
  return result.rows.map((row) => {
    const out: Record<string, unknown> = {};
    result.columns.forEach((name, i) => {
      const value = (row as unknown[])[i];
      out[name] = typeof value === "bigint" && value <= BigInt(Number.MAX_SAFE_INTEGER) && value >= BigInt(Number.MIN_SAFE_INTEGER) ? Number(value) : value;
    });
    return out as T;
  });
}

function db(exec: Executor, client: Client | null): Db {
  const statement = (sql: string, params: unknown[]): InStatement => ({ sql, args: params as InStatement extends { args?: infer A } ? A : never });
  const self: Db = {
    dialect: "sqlite",
    async all<T>(sql: string, params: unknown[] = []): Promise<T[]> {
      return rows<T>(await exec.execute(statement(sql, params)));
    },
    async run(sql: string, params: unknown[] = []): Promise<void> {
      await exec.execute(statement(sql, params));
    },
  };
  // Over HTTP every statement is its own request, so a transaction has to be the client's own.
  if (client) {
    self.transaction = async <T>(fn: (inner: Db) => Promise<T>): Promise<T> => {
      const tx = await client.transaction("write");
      try {
        const result = await fn(db(tx, null));
        await tx.commit();
        return result;
      } catch (error) {
        await tx.rollback().catch(() => {});
        throw error;
      } finally {
        tx.close();
      }
    };
  }
  return self;
}

/**
 * Runlight's tables in libSQL: Turso, or a local libSQL file. Works on the
 * edge with @libsql/client/web, since nothing here needs Node.
 *
 *   import { createClient } from "@libsql/client";
 *   libsql({ client: createClient({ url: process.env.TURSO_URL!, authToken: process.env.TURSO_TOKEN }) })
 */
export function libsql(options: LibsqlOptions): SqlStore {
  // A local file is one connection taking turns, as the SQLite store is, so a tracker hit waits
  // for a transaction instead of meeting a locked database. Over HTTP the client's own transactions apply.
  if ((options.client as { protocol?: string }).protocol === "file") {
    // Another process holding the file waits a little rather than failing at once.
    void options.client.execute("PRAGMA busy_timeout = 5000").catch(() => {});
    return new SqlStore(takingTurns(db(options.client, options.client)));
  }
  return new SqlStore(db(options.client, options.client));
}

/**
 * Statements one at a time, with a transaction holding its turn until it ends. The client runs
 * a transaction on a connection of its own, so without this a statement meanwhile meets a locked file.
 */
function takingTurns(inner: Db): Db {
  let tail: Promise<unknown> = Promise.resolve();
  const turn = <T>(fn: () => Promise<T>): Promise<T> => {
    const result = tail.then(fn, fn);
    tail = result.catch(() => {});
    return result;
  };
  return {
    ...inner,
    all: (sql, params) => turn(() => inner.all(sql, params)),
    run: (sql, params) => turn(() => inner.run(sql, params)),
    transaction: (fn) => turn(() => inner.transaction!(fn)),
  };
}
