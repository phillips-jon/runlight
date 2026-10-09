import pg from "pg";
import mysql2 from "mysql2/promise";
import { runlight, type RunlightOptions } from "../src/index.js";
import type { SqlStore } from "../src/store.js";
import { postgres } from "../src/stores/postgres.js";
import { mysql } from "../src/stores/mysql.js";
import { sqlite } from "../src/stores/sqlite.js";
import { libsql } from "../src/stores/libsql.js";
import { d1 } from "../src/stores/d1.js";
import { createClient } from "@libsql/client";
import Database from "better-sqlite3";

export type StoreKind = "sqlite" | "postgres" | "libsql" | "d1" | "mysql";

/**
 * SQLite, libSQL, and D1 always; Postgres too when RUNLIGHT_TEST_PG holds a connection string, and MySQL or
 * MariaDB when RUNLIGHT_TEST_MYSQL holds a connection URL.
 */
export const STORES: StoreKind[] = [
  "sqlite",
  "libsql",
  "d1",
  ...(process.env.RUNLIGHT_TEST_PG ? (["postgres"] as const) : []),
  ...(process.env.RUNLIGHT_TEST_MYSQL ? (["mysql"] as const) : []),
];

/** A new, empty MySQL database of its own, dropped by cleanup(), and a URL that reaches it. */
export function freshMysqlDatabase(): { url: string; ready: Promise<void> } {
  const name = `rl_test_${Math.random().toString(36).slice(2, 10)}`;
  const base = new URL(process.env.RUNLIGHT_TEST_MYSQL!);
  const ready = (async () => {
    const admin = await mysql2.createConnection(base.href);
    try {
      await admin.query(`CREATE DATABASE ${name}`);
    } finally {
      await admin.end();
    }
  })();
  cleanups.push(async () => {
    const admin = await mysql2.createConnection(base.href);
    try {
      await admin.query(`DROP DATABASE IF EXISTS ${name}`);
    } finally {
      await admin.end();
    }
  });
  const url = new URL(base.href);
  url.pathname = `/${name}`;
  return { url: url.href, ready };
}

/** Cloudflare's D1 binding, played by an in-memory SQLite, so the D1 store runs the same tests. */
function fakeD1() {
  const handle = new Database(":memory:");
  const prepare = (sql: string) => {
    let params: unknown[] = [];
    const statement = {
      bind(...values: unknown[]) {
        params = values.map((v) => (typeof v === "number" && Number.isSafeInteger(v) ? BigInt(v) : v));
        return statement;
      },
      async all<T>() {
        const prepared = handle.prepare(sql);
        return { results: (prepared.reader ? prepared.all(...params) : (prepared.run(...params), [])) as T[] };
      },
      async run() {
        return handle.prepare(sql).run(...params);
      },
    };
    return statement;
  };
  return { prepare };
}

const cleanups: Array<() => Promise<void>> = [];

/** Drops the schemas the Postgres tests made. Register with after(). */
export async function cleanup(): Promise<void> {
  while (cleanups.length > 0) await cleanups.pop()!();
}

/** A fresh store: an in-memory SQLite, or a Postgres schema or MySQL database of its own. */
export function freshStore(kind: StoreKind): SqlStore {
  if (kind === "sqlite") return sqlite({ path: ":memory:" });
  if (kind === "libsql") return libsql({ client: createClient({ url: ":memory:" }) });
  if (kind === "d1") return d1({ database: fakeD1() });
  if (kind === "mysql") {
    const { url, ready } = freshMysqlDatabase();
    const store = mysql({ url, max: 3 });
    // Nothing reaches the database before it exists.
    const db = store.db as unknown as Record<string, unknown>;
    for (const name of ["all", "run", "affected", "exclusive", "transaction"]) {
      const inner = db[name] as (...args: unknown[]) => Promise<unknown>;
      db[name] = async (...args: unknown[]) => {
        await ready;
        return inner(...args);
      };
    }
    // Registered after the database's own cleanup, so it runs first: the pool closes before the database goes.
    cleanups.push(() => store.close());
    return store;
  }
  const schema = `rl_test_${Math.random().toString(36).slice(2, 10)}`;
  const url = process.env.RUNLIGHT_TEST_PG!;
  const pool = new pg.Pool({ connectionString: url, max: 3, options: `-c search_path=${schema}` });
  const ready = pool.query(`CREATE SCHEMA ${schema}`);
  const store = postgres({ pool });
  // Nothing reaches the database before the schema exists: a request can reach the accounts tables before
  // anything migrates.
  const db = store.db as unknown as Record<string, unknown>;
  for (const name of ["all", "run", "affected", "exclusive", "transaction"]) {
    const inner = db[name] as ((...args: unknown[]) => Promise<unknown>) | undefined;
    if (!inner) continue;
    db[name] = async (...args: unknown[]) => {
      await ready;
      return inner(...args);
    };
  }
  const migrate = store.migrate.bind(store);
  store.migrate = async () => {
    await ready;
    return migrate();
  };
  cleanups.push(async () => {
    await ready.catch(() => {});
    await pool.query(`DROP SCHEMA ${schema} CASCADE`);
    await pool.end();
  });
  return store;
}

export const CHROME_MAC =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
export const SAFARI_IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

/** A Runlight on an in-memory database with a clock the test moves. */
export function setup(kind: StoreKind, options: Partial<RunlightOptions> = {}) {
  let now = Date.UTC(2026, 9, 6, 12, 0);
  const rl = runlight({ store: freshStore(kind), now: () => now, ...options });
  const routes = rl.routes({ token: "secret" });

  const send = async (body: Record<string, unknown>, init: { ua?: string; ip?: string; headers?: Record<string, string> } = {}) => {
    const response = await routes.POST(
      new Request("https://example.com/runlight/e", {
        method: "POST",
        body: JSON.stringify(body),
        headers: { "user-agent": init.ua ?? CHROME_MAC, "x-forwarded-for": init.ip ?? "203.0.113.1", ...init.headers },
      }),
    );
    if (response.status !== 202) throw new Error(`collect answered ${response.status}`);
  };

  const get = async (path: string): Promise<any> => {
    const response = await routes.GET(new Request(`https://example.com/runlight${path}`, { headers: { authorization: "Bearer secret" } }));
    if (response.status !== 200) throw new Error(`${path} answered ${response.status}: ${await response.text()}`);
    return response.json();
  };

  return {
    rl,
    routes,
    send,
    get,
    advance(ms: number) {
      now += ms;
    },
    get now() {
      return now;
    },
  };
}
