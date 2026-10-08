import assert from "node:assert/strict";
import { test } from "node:test";
import { sqlite } from "@runlight/sdk/sqlite";
import { Throttle, base32, totp } from "../src/auth.js";
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
  assert.equal((await api("DELETE", `/api/people/${other!.id}/2fa`)).status, 415, "it asks for the owner's password");
  assert.equal((await api("DELETE", `/api/people/${other!.id}/2fa`, { password: "nope" })).status, 400);
  assert.equal((await server.accounts.byId(other!.id))!.twoFactor, true);
  assert.equal((await api("DELETE", `/api/people/${other!.id}/2fa`, { password: "a long password" })).status, 200);
  assert.equal((await server.accounts.byId(other!.id))!.twoFactor, false);

  // An owner's own two-factor goes off only through Account, which asks for the password.
  const mine = (await (await api("POST", "/api/account/2fa/start", { password: "a long password" })).json()) as any;
  cookie = cookieOf(await api("POST", "/api/account/2fa/confirm", { code: code(mine.secret) }));
  const me = (await server.accounts.byEmail("jon@example.com"))!;
  assert.equal((await api("DELETE", `/api/people/${me.id}/2fa`)).status, 400);
  assert.equal((await api("DELETE", `/api/people/${me.id}/2fa`, { password: "a long password" })).status, 400);
  assert.equal((await server.accounts.byId(me.id))!.twoFactor, true);
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

test("with two-factor on, failed passwords from others cannot lock its owner out, nor tell which password was right", async () => {
  let now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  const user = await server.accounts.setPassword("jon@example.com", "a long password", now);
  const secret = await server.accounts.startTwoFactor(user.id);
  await server.accounts.confirmTwoFactor(user.id, totp(secret, Math.floor(now / 30_000)), now);
  now += 60_000;
  const login = (password: string, ip: string) =>
    server.handler(new Request(`${origin}/login`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "x-forwarded-for": ip }, body: new URLSearchParams({ email: "jon@example.com", password }).toString() }));
  for (let i = 0; i < 50; i++) assert.equal((await login("wrong wrong wrong", `203.0.113.${i}`)).status, 401);
  // Past the account's limit, a wrong password reaches the code step too, where no code passes.
  const decoy = await login("wrong wrong wrong", "203.0.113.200");
  assert.equal(decoy.status, 200);
  const fake = /name="pending" value="([^"]+)"/.exec(await decoy.text())![1]!;
  const code = (pending: string) => server.handler(req("/login/code", form({ pending, code: totp(secret, Math.floor(now / 30_000)) })));
  assert.equal((await code(fake)).status, 401, "even the right code fails after a wrong password");
  // The owner, from a new browser, gets the real step.
  const step = await login("a long password", "192.0.2.77");
  assert.equal(step.status, 200, "a new browser reaches the code step");
  const real = /name="pending" value="([^"]+)"/.exec(await step.text())![1]!;
  assert.equal(real.split(".").length, fake.split(".").length);
  now += 30_000;
  assert.equal((await code(real)).status, 303);
  // Each address still has its own limit.
  for (let i = 0; i < 10; i++) await login("wrong wrong wrong", "198.51.100.9");
  assert.equal((await login("a long password", "198.51.100.9")).status, 429);
});

test("without two-factor, a held-up account answers every password alike, and a right one emails a sign-in link", async () => {
  const { createServer: listen } = await import("node:http");
  const got: any[] = [];
  const hook = listen((r, res) => {
    let text = "";
    r.on("data", (c) => (text += c));
    r.on("end", () => {
      got.push(JSON.parse(text));
      res.end("ok");
    });
  });
  await new Promise<void>((resolve) => hook.listen(0, "127.0.0.1", resolve));
  try {
    const now = Date.UTC(2026, 9, 7, 12);
    const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), url: origin, now: () => now });
    await server.accounts.setPassword("jon@example.com", "a long password", now);
    const login = (password: string, ip: string) =>
      server.handler(new Request(`${origin}/login`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "x-forwarded-for": ip }, body: new URLSearchParams({ email: "jon@example.com", password }).toString() }));
    for (let i = 0; i < 50; i++) await login("wrong wrong wrong", `203.0.113.${i}`);
    // Without a mail service the account waits, as before.
    assert.equal((await login("a long password", "192.0.2.77")).status, 429);
    await server.runlight.saveMailSettings({ service: "webhook", url: `http://127.0.0.1:${(hook.address() as { port: number }).port}/`, from: "runlight@example.com" });
    const wrong = await login("wrong again", "192.0.2.78");
    const right = await login("a long password", "192.0.2.79");
    assert.deepEqual([wrong.status, right.status], [429, 429]);
    assert.equal((await wrong.text()).replace(/wrong again|a long password/g, ""), (await right.text()).replace(/wrong again|a long password/g, ""), "the same page either way");
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(got.length, 1, "only the right password sends a link");
    assert.equal(got[0].to, "jon@example.com");
    const link = /https:\/\/stats\.example\.com\/login\/link\?\S+/.exec(got[0].text)![0];
    const opened = await server.handler(new Request(link));
    assert.equal(opened.status, 303);
    assert.match(opened.headers.get("set-cookie") ?? "", /runlight_session=/);
    assert.equal((await server.handler(new Request(link))).status, 410, "a link works once");
    assert.equal((await server.handler(new Request(link.replace(/ticket=[^&]+/, "ticket=x.1.y")))).status, 410);
  } finally {
    hook.close();
  }
});

test("six-digit codes are counted before they are checked, and confirming a new set-up has its own few tries", async () => {
  const now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  const user = await server.accounts.setPassword("jon@example.com", "a long password", now);
  const secret = await server.accounts.startTwoFactor(user.id);
  await server.accounts.confirmTwoFactor(user.id, totp(secret, Math.floor(now / 30_000)), now);
  const pending = server.accounts.pendingFor((await server.accounts.byId(user.id))!, now);
  const burst = await Promise.all(Array.from({ length: 200 }, () => server.handler(req("/login/code", form({ pending, code: "000000" }))).then((r) => r.status)));
  assert.equal(burst.filter((s) => s === 401).length, 5);
  assert.equal(burst.filter((s) => s === 429).length, 195);

  // Someone holding a session tries to finish a set-up its owner left half done.
  const other = await server.accounts.setPassword("amy@example.com", "a long password", now);
  await server.accounts.startTwoFactor(other.id);
  const cookie = `runlight_session=${encodeURIComponent(server.accounts.sessionFor(other, now))}`;
  const confirm = (code: string) => server.handler(req("/api/account/2fa/confirm", { method: "POST", headers: { cookie, "content-type": "application/json" }, body: JSON.stringify({ code }) }));
  for (let i = 0; i < 5; i++) assert.equal((await confirm(String(i).padStart(6, "0"))).status, 400);
  const stopped = await confirm("000009");
  assert.equal(stopped.status, 429);
  assert.equal(((await stopped.json()) as any).code, "twofactor_restart");
  assert.equal((await server.accounts.byId(other.id))!.twoFactor, false);
  const [row] = await server.runlight.store.db.all(`SELECT totp_pending FROM rl_users WHERE id = ?`, [other.id]);
  assert.equal(row!.totp_pending, null, "the half-done set-up is gone");
});

test("a burst of wrong passwords is counted before they are checked, so it cannot pass the limit", async () => {
  const now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  await server.accounts.setPassword("jon@example.com", "a long password", now);
  const login = (password: string, ip = "198.51.100.7") =>
    server.handler(new Request(`${origin}/login`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "x-forwarded-for": ip }, body: new URLSearchParams({ email: "jon@example.com", password }).toString() }));
  const statuses = await Promise.all(Array.from({ length: 40 }, (_, i) => login(`guess ${i}`).then((r) => r.status)));
  assert.equal(statuses.filter((s) => s === 401).length, 10, "ten checked");
  assert.equal(statuses.filter((s) => s === 429).length, 30);

  // The password re-checks in Account are counted the same way.
  const cookie = cookieOf(await login("a long password", "192.0.2.1"));
  const change = (current: string) => server.handler(req("/api/account/password", { method: "POST", headers: { cookie, "content-type": "application/json" }, body: JSON.stringify({ current, next: "a new long password" }) }));
  const rechecked = await Promise.all(Array.from({ length: 30 }, (_, i) => change(`guess ${i}`).then((r) => r.status)));
  assert.equal(rechecked.filter((s) => s === 400).length, 10);
  assert.equal(rechecked.filter((s) => s === 429).length, 20);
});

test("a right password does not use up a try, and the throttle never holds an address or an email", () => {
  const throttle = new Throttle(2);
  const now = Date.UTC(2026, 9, 7, 12);
  assert.equal(throttle.take("jon@example.com\n198.51.100.7", now), true);
  throttle.forgive("jon@example.com\n198.51.100.7");
  assert.equal(throttle.take("jon@example.com\n198.51.100.7", now), true);
  assert.equal(throttle.take("jon@example.com\n198.51.100.7", now), true);
  assert.equal(throttle.take("jon@example.com\n198.51.100.7", now), false, "two wrong tries reach the limit");
  const held = [...(throttle as unknown as { failures: Map<string, unknown> }).failures.keys()].join(" ");
  assert.doesNotMatch(held, /198\.51|example/);
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

test("two owners demoting each other at once leave one owner, and a double-clicked invite makes one", async () => {
  const now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  const a = await server.accounts.setPassword("a@example.com", "a long password", now);
  const b = await server.accounts.setPassword("b@example.com", "a long password", now);
  const results = await Promise.allSettled([server.accounts.setRole(a.id, "viewer"), server.accounts.setRole(b.id, "viewer")]);
  assert.deepEqual(results.map((r) => r.status).sort(), ["fulfilled", "rejected"]);
  assert.equal((await server.accounts.list()).filter((u) => u.role === "owner").length, 1);
  const invites = await Promise.allSettled([server.accounts.invite("new@example.com", "viewer", "A", now), server.accounts.invite("new@example.com", "viewer", "A", now)]);
  assert.deepEqual(invites.map((r) => r.status), ["fulfilled", "fulfilled"]);
});

test("signing in again right after turning on two-factor works with the same code", async () => {
  const now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now });
  const user = await server.accounts.setPassword("jon@example.com", "a long password", now);
  const secret = await server.accounts.startTwoFactor(user.id);
  const code = totp(secret, Math.floor(now / 30_000));
  assert.ok(await server.accounts.confirmTwoFactor(user.id, code, now));
  assert.equal(await server.accounts.checkSecondFactor(user.id, code, now), true);
  assert.equal(await server.accounts.checkSecondFactor(user.id, code, now), false, "and then only once");
});
