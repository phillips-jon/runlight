import assert from "node:assert/strict";
import { after, test } from "node:test";
import mysql2 from "mysql2/promise";
import { runlight } from "../src/index.js";
import { mysql, mysqlText } from "../src/stores/mysql.js";
import { STORES, cleanup, freshMysqlDatabase, setup } from "./helpers.js";

after(cleanup);

const url = process.env.RUNLIGHT_TEST_MYSQL;
const skip = !url && "RUNLIGHT_TEST_MYSQL is not set";
const HOUR = 3_600_000;

test("values fill placeholders outside quotes only, names are quoted with backticks, and backslashes stay literal", () => {
  const escape = (value: unknown) => (typeof value === "string" ? `'${value}'` : String(value));
  assert.equal(
    mysqlText(`SELECT "key", ? FROM t WHERE a = '?' AND b LIKE ? ESCAPE '\\' AND c = ?`, ["x", 2, null], escape),
    "SELECT `key`, 'x' FROM t WHERE a = '?' AND b LIKE 2 ESCAPE '\\\\' AND c = null",
  );
  assert.throws(() => mysqlText("SELECT ?, ?", [1]), /more placeholders/);
  assert.throws(() => mysqlText("SELECT ?", [1, 2]), /more values/);
});

test("a MySQL pool of one connection is refused, since settings changes need two", () => {
  assert.throws(() => mysql({ url: "mysql://127.0.0.1:1/none", max: 1 }), /at least 2 connections/);
});

test("two MySQL processes starting at once create the tables once", { skip }, async () => {
  const { url: database, ready } = freshMysqlDatabase();
  await ready;
  const apps = Array.from({ length: 4 }, () => runlight({ store: mysql({ url: database, max: 3 }) }));
  try {
    await Promise.all(apps.map((app) => app.init()));
    const [row] = await apps[0]!.store.db.all<{ n: number }>(`SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE()`);
    assert.equal(Number(row!.n), 15);
  } finally {
    for (const app of apps) await app.store.close();
  }
});

test("a MySQL connection the server drops is replaced, and the process carries on", { skip }, async () => {
  const { url: database, ready } = freshMysqlDatabase();
  await ready;
  const store = mysql({ url: database, max: 2 });
  const logged: unknown[] = [];
  const error = console.error;
  console.error = (...args: unknown[]) => void logged.push(args);
  const admin = await mysql2.createConnection(url!);
  try {
    await store.migrate();
    const name = new URL(database).pathname.slice(1);
    const [ids] = await admin.query(`SELECT id FROM information_schema.processlist WHERE db = ?`, [name]);
    assert.ok((ids as unknown[]).length > 0);
    for (const { id } of ids as Array<{ id: number }>) await admin.query(`KILL ${Number(id)}`);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal((await store.sites()).length, 0);
    assert.ok(logged.length > 0, "the lost connection was reported");
  } finally {
    console.error = error;
    await admin.end();
    await store.close();
  }
});

test("a server set to NO_BACKSLASH_ESCAPES cannot turn a value into SQL", { skip }, async () => {
  const { url: database, ready } = freshMysqlDatabase();
  await ready;
  // An app's own pool whose every connection starts with the mode on, as a server configured that way would.
  const pool = mysql2.createPool({ uri: database, connectionLimit: 2 });
  pool.on("connection", (conn) => void conn.query("SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')"));
  const store = mysql({ pool });
  try {
    await store.migrate();
    const value = "a\\' , 'x') -- \\\\ end";
    await store.setSetting("odd", value);
    assert.equal(await store.setting("odd"), value);
    assert.equal(await store.setting("x"), null, "nothing else was written");
    const [row] = await store.db.all<{ mode: string }>("SELECT @@SESSION.sql_mode AS mode");
    assert.doesNotMatch(String(row!.mode), /NO_BACKSLASH_ESCAPES/);
  } finally {
    await pool.end();
  }
});

for (const kind of STORES) {
  test(`${kind}: the longest values the tracker accepts are kept whole`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    const path = `/${"p".repeat(1200)}`;
    const title = "t".repeat(600);
    await t.send({ k: "pageview", u: `https://example.com${path}`, t: title, i: "a1", r: `https://${"r".repeat(60)}.example.org/${"q".repeat(800)}` });
    const utm = (c: string) => c.repeat(250);
    await t.send({ k: "pageview", u: `https://example.com/?utm_source=${utm("s")}&utm_medium=${utm("m")}&utm_campaign=${utm("c")}&utm_term=${utm("t")}&utm_content=${utm("o")}`, i: "a2" }, { ip: "203.0.113.2" });
    const props = Object.fromEntries(Array.from({ length: 8 }, (_, i) => [`${i}${"k".repeat(70)}`, "v".repeat(600)]));
    await t.send({ k: "event", u: "https://example.com/", n: "n".repeat(130), i: "a2", p: props }, { ip: "203.0.113.2" });

    const pages = (await t.get("/api/breakdown?period=today&dimension=page")).rows as Array<{ value: string }>;
    assert.ok(pages.some((r) => r.value === path.slice(0, 1000)), "the path, cut where the tracker cuts it");
    for (const [dimension, c] of [["utm_source", "s"], ["utm_medium", "m"], ["utm_campaign", "c"], ["utm_term", "t"], ["utm_content", "o"]] as const) {
      assert.deepEqual(((await t.get(`/api/breakdown?period=today&dimension=${dimension}`)).rows as Array<{ value: string }>).map((r) => r.value), [c.repeat(200)]);
    }
    const [event] = (await t.get("/api/breakdown?period=today&dimension=event")).rows as Array<{ value: string }>;
    assert.equal(event!.value, "n".repeat(120));
    const read = await t.get(`/api/event-props?period=today&event=${"n".repeat(120)}&key=0${"k".repeat(59)}`);
    assert.equal(read.keys.length, 8);
    assert.deepEqual(read.rows.map((r: { value: string }) => r.value), ["v".repeat(500)]);
    // A day of them adds up the same way.
    t.advance(26 * HOUR);
    assert.ok((await t.rl.buildRollups()) >= 1);
    assert.ok(((await t.get("/api/breakdown?period=7d&dimension=page")).rows as Array<{ value: string }>).some((r) => r.value === path.slice(0, 1000)));
  });

  test(`${kind}: text is compared exactly and sorted by code point, case and trailing spaces included`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    const values = ["a", "a ", "A", "b", "é", "É", "\u{1F600}", "�", "a\t"];
    for (const [i, value] of values.entries()) {
      await t.send({ k: "event", u: "https://example.com/", n: "Pick", i: `x${i}`, p: { choice: value } }, { ip: `203.0.113.${i + 1}` });
    }
    const rows = (await t.get("/api/event-props?period=today&event=Pick&key=choice")).rows as Array<{ value: string; events: number }>;
    const byCodePoint = [...values].sort((x, y) => {
      const a = [...x].map((c) => c.codePointAt(0)!);
      const b = [...y].map((c) => c.codePointAt(0)!);
      for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i]! - b[i]!;
      return a.length - b.length;
    });
    assert.deepEqual(rows.map((r) => r.value), byCodePoint);
    assert.ok(rows.every((r) => r.events === 1), "no two values counted as one");
  });
}
