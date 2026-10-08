import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import Database from "better-sqlite3";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

const dir = mkdtempSync(path.join(tmpdir(), "runlight-storage-"));
after(() => rmSync(dir, { recursive: true, force: true }));

test("an upgrade that stopped after adding a column but before recording its version starts the next time", async () => {
  const file = path.join(dir, "upgrade.db");
  await sqlite({ path: file }).migrate();
  // As an upgrade from version 9 leaves things when it stops between its two steps.
  const raw = new Database(file);
  raw.prepare("UPDATE rl_meta SET value = '9' WHERE key = 'schema'").run();
  raw.close();
  const store = sqlite({ path: file });
  await store.migrate();
  assert.deepEqual(await store.db.all("SELECT value FROM rl_meta WHERE key = 'schema'"), [{ value: "11" }]);
  await store.close();
});

test("a database that can only be read still answers reports", async () => {
  const file = path.join(dir, "readonly.db");
  const now = Date.UTC(2026, 9, 6, 12);
  const first = runlight({ store: sqlite({ path: file }), site: { hostnames: ["example.com"] }, now: () => now });
  await first.init();
  await first.store.close();
  chmodSync(file, 0o444);
  const rl = runlight({ store: sqlite({ path: file }), site: { hostnames: ["example.com"] }, now: () => now });
  const response = await rl.routes({ token: "t" }).GET(new Request("https://example.com/runlight/api/stats?period=today", { headers: { authorization: "Bearer t" } }));
  assert.equal(response.status, 200);
  await rl.store.close();
});
