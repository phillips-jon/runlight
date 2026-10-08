import assert from "node:assert/strict";
import { test } from "node:test";
import { sqlite } from "@runlight/sdk/sqlite";
import { base32, totp } from "../src/auth.js";
import { createServer } from "../src/server.js";

const origin = "https://stats.example.com";
const req = (path: string, init: RequestInit = {}) => new Request(`${origin}${path}`, init);
const form = (fields: Record<string, string>) => ({ method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(fields).toString() });
const cookieOf = (response: Response) => (response.headers.get("set-cookie") ?? "").split(";")[0]!;

test("codes match RFC 6238's test values", () => {
  const secret = base32(Buffer.from("12345678901234567890"));
  assert.equal(secret, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ");
  assert.equal(totp(secret, Math.floor(59 / 30)), "287082");
  assert.equal(totp(secret, Math.floor(1111111109 / 30)), "081804");
  assert.equal(totp(secret, Math.floor(1234567890 / 30)), "005924");
  assert.equal(totp(secret, Math.floor(2000000000 / 30)), "279037");
});

test("two-factor sign-in: turned on with a code, then asked for at every sign-in", async () => {
  let now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  const handle = server.handler;
  await server.accounts.setPassword("jon@example.com", "a long password", now);
  await server.accounts.setPassword("other@example.com", "a long password", now);
  let cookie = cookieOf(await handle(req("/login", form({ email: "jon@example.com", password: "a long password" }))));
  const api = (method: string, path: string, body?: unknown, as = cookie) =>
    handle(req(path, { method, headers: { cookie: as, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
  const code = (secret: string) => totp(secret, Math.floor(now / 30_000));

  assert.equal((await api("POST", "/api/account/2fa/start", { password: "wrong" })).status, 400, "turning it on asks for the password");
  const started = (await (await api("POST", "/api/account/2fa/start", { password: "a long password" })).json()) as any;
  assert.match(started.secret, /^[A-Z2-7]{32}$/);
  assert.match(started.uri, /^otpauth:\/\/totp\/Runlight%20\(stats\.example\.com\)%3Ajon%40example\.com\?secret=/);
  assert.equal((await api("POST", "/api/account/2fa/confirm", { code: "000000" })).status, 400);
  const before = cookie;
  const confirming = await api("POST", "/api/account/2fa/confirm", { code: code(started.secret) });
  const confirmed = (await confirming.json()) as any;
  // Turning it on ends every other session; this browser carries on with a new one.
  cookie = cookieOf(confirming);
  assert.equal((await api("GET", "/api/account", undefined, before)).status, 401, "the old session ended");
  assert.equal(confirmed.recovery.length, 10);
  const account = (await (await api("GET", "/api/account")).json()) as any;
  assert.equal(account.account.twoFactor, true);
  assert.equal((await server.accounts.byEmail("jon@example.com"))!.twoFactor, true);

  // The password now only earns the second step.
  now += 60_000;
  const first = await handle(req("/login", form({ email: "jon@example.com", password: "a long password" })));
  assert.equal(first.status, 200);
  assert.equal(first.headers.get("set-cookie"), null, "no session yet");
  const pending = /name="pending" value="([^"]+)"/.exec(await first.text())![1]!;
  assert.equal((await handle(req("/login/code", form({ pending, code: "123456" })))).status, 401);
  assert.equal((await handle(req("/login/code", form({ pending: "made.up.ticket", code: code(started.secret) })))).status, 303, "a made-up ticket goes back to sign-in");
  const good = code(started.secret);
  const signed = await handle(req("/login/code", form({ pending, code: good, next: "/?site=x" })));
  assert.equal(signed.status, 303);
  assert.equal(signed.headers.get("location"), "/?site=x");
  assert.equal((await api("GET", "/api/account", undefined, cookieOf(signed))).status, 200);
  assert.equal((await handle(req("/login/code", form({ pending, code: good })))).status, 401, "a code works once");

  // A recovery code works once too.
  const recovery = confirmed.recovery[0];
  assert.equal((await handle(req("/login/code", form({ pending, code: recovery.toUpperCase() })))).status, 303);
  assert.equal((await handle(req("/login/code", form({ pending, code: recovery })))).status, 401);
  assert.equal(((await (await api("GET", "/api/account")).json()) as any).account.recoveryLeft, 9);

  // A ticket expires after five minutes.
  now += 6 * 60_000;
  assert.equal((await handle(req("/login/code", form({ pending, code: code(started.secret) })))).status, 303);
  assert.equal((await handle(req("/login/code", form({ pending, code: code(started.secret) })))).headers.get("location"), "/login?next=%2F");

  // Turning it off asks for the password; an owner can also reset someone else's.
  assert.equal((await api("POST", "/api/account/2fa/disable", { password: "nope" })).status, 400);
  const disabled = await api("POST", "/api/account/2fa/disable", { password: "a long password" });
  assert.equal(disabled.status, 200);
  cookie = cookieOf(disabled);
  assert.equal((await server.accounts.byEmail("jon@example.com"))!.twoFactor, false);
  const other = await server.accounts.byEmail("other@example.com");
  await server.accounts.confirmTwoFactor(other!.id, "x", now);
  const secret = await server.accounts.startTwoFactor(other!.id);
  await server.accounts.confirmTwoFactor(other!.id, code(secret), now);
  assert.equal((await server.accounts.byId(other!.id))!.twoFactor, true);
  assert.equal((await api("DELETE", `/api/people/${other!.id}/2fa`)).status, 200);
  assert.equal((await server.accounts.byId(other!.id))!.twoFactor, false);
});

test("failed tries by others cannot lock out a browser that signed in before, and codes allow five tries", async () => {
  let now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  const handle = server.handler;
  await server.accounts.setPassword("jon@example.com", "a long password", now);
  const login = (password: string, ip: string, cookie = "") =>
    handle(new Request(`${origin}/login`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "x-forwarded-for": ip, ...(cookie ? { cookie } : {}) }, body: new URLSearchParams({ email: "jon@example.com", password }).toString() }));
  const first = await login("a long password", "198.51.100.1");
  const device = (first.headers.getSetCookie?.() ?? []).find((c) => c.startsWith("runlight_device="))!.split(";")[0]!;
  assert.ok(device, "signing in marks the browser");
  // Someone tries fifty wrong passwords from fifty addresses.
  for (let i = 0; i < 50; i++) await login("wrong wrong wrong", `203.0.113.${i}`);
  assert.equal((await login("a long password", "192.0.2.77")).status, 429, "a new browser waits");
  assert.equal((await login("a long password", "192.0.2.77", device)).status, 303, "the owner's own browser gets in");

  // The code step: five wrong codes, then a wait.
  const secret = await server.accounts.startTwoFactor((await server.accounts.byEmail("jon@example.com"))!.id);
  await server.accounts.confirmTwoFactor((await server.accounts.byEmail("jon@example.com"))!.id, totp(secret, Math.floor(now / 30_000)), now);
  now += 60_000;
  const step = await login("a long password", "198.51.100.1", device);
  const pending = /name="pending" value="([^"]+)"/.exec(await step.text())![1]!;
  const code = (value: string) => handle(req("/login/code", form({ pending, code: value })));
  for (let i = 0; i < 5; i++) assert.equal((await code("000000")).status, 401);
  assert.equal((await code(totp(secret, Math.floor(now / 30_000)))).status, 429, "even the right code waits after five wrong ones");
});

test("the same code used twice at once signs in only once", async () => {
  const now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  const user = await server.accounts.setPassword("jon@example.com", "a long password", now);
  const secret = await server.accounts.startTwoFactor(user.id);
  await server.accounts.confirmTwoFactor(user.id, totp(secret, Math.floor(now / 30_000) - 1), now);
  const code = totp(secret, Math.floor(now / 30_000));
  const results = await Promise.all([server.accounts.checkSecondFactor(user.id, code, now), server.accounts.checkSecondFactor(user.id, code, now)]);
  assert.deepEqual(results.sort(), [false, true]);
});

test("an account write must be JSON, so a form on another page cannot make one", async () => {
  const now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  await server.accounts.setPassword("jon@example.com", "a long password", now);
  const cookie = cookieOf(await server.handler(req("/login", form({ email: "jon@example.com", password: "a long password" }))));
  const forged = await server.handler(req("/api/account/2fa/start", { method: "POST", headers: { cookie, "content-type": "text/plain" }, body: '{"password":"a long password"}' }));
  assert.equal(forged.status, 415);
});
