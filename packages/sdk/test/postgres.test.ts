import assert from "node:assert/strict";
import { after, test } from "node:test";
import pg from "pg";
import { runlight } from "../src/index.js";
import { numberPlaceholders, postgres } from "../src/stores/postgres.js";

test("placeholders are numbered outside quotes only", () => {
  assert.equal(numberPlaceholders("SELECT ? WHERE a = '?' AND b = ? AND c = \"?\""), "SELECT $1 WHERE a = '?' AND b = $2 AND c = \"?\"");
});

const url = process.env.RUNLIGHT_TEST_PG;
const pools: pg.Pool[] = [];
after(async () => {
  for (const pool of pools) await pool.end();
});

test("two processes starting at once create the tables once", { skip: !url && "RUNLIGHT_TEST_PG is not set" }, async () => {
  const schema = `rl_test_${Math.random().toString(36).slice(2, 10)}`;
  const admin = new pg.Pool({ connectionString: url, max: 1 });
  pools.push(admin);
  await admin.query(`CREATE SCHEMA ${schema}`);
  try {
    const make = () => {
      const pool = new pg.Pool({ connectionString: url, max: 3, options: `-c search_path=${schema}` });
      pools.push(pool);
      return runlight({ store: postgres({ pool }) });
    };
    const apps = Array.from({ length: 4 }, make);
    await Promise.all(apps.map((app) => app.init()));
    const { rows } = await admin.query(`SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema = $1`, [schema]);
    assert.equal(rows[0].n, 8);
  } finally {
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
  }
});
