import pg from "pg";
import { runlight, type RunlightOptions } from "../src/index.js";
import type { SqlStore } from "../src/store.js";
import { postgres } from "../src/stores/postgres.js";
import { sqlite } from "../src/stores/sqlite.js";

export type StoreKind = "sqlite" | "postgres";

/** SQLite always; Postgres too when RUNLIGHT_TEST_PG holds a connection string. */
export const STORES: StoreKind[] = process.env.RUNLIGHT_TEST_PG ? ["sqlite", "postgres"] : ["sqlite"];

const cleanups: Array<() => Promise<void>> = [];

/** Drops the schemas the Postgres tests made. Register with after(). */
export async function cleanup(): Promise<void> {
  while (cleanups.length > 0) await cleanups.pop()!();
}

/** A fresh store: an in-memory SQLite, or a Postgres schema of its own. */
export function freshStore(kind: StoreKind): SqlStore {
  if (kind === "sqlite") return sqlite({ path: ":memory:" });
  const schema = `rl_test_${Math.random().toString(36).slice(2, 10)}`;
  const url = process.env.RUNLIGHT_TEST_PG!;
  const pool = new pg.Pool({ connectionString: url, max: 3, options: `-c search_path=${schema}` });
  const ready = pool.query(`CREATE SCHEMA ${schema}`);
  const store = postgres({ pool });
  const migrate = store.migrate.bind(store);
  store.migrate = async () => {
    await ready;
    return migrate();
  };
  cleanups.push(async () => {
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
