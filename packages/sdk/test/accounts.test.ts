import assert from "node:assert/strict";
import { createCipheriv, createDecipheriv, createHash, randomBytes, scryptSync } from "node:crypto";
import { after, test } from "node:test";
import { checkPassword, hashPassword, runlight } from "../src/index.js";
import { sealText, unsealText } from "../src/accounts/crypto.js";
import { STORES, cleanup, freshStore } from "./helpers.js";

after(cleanup);

const req = (path: string, init: RequestInit = {}) => new Request(`https://example.com${path}`, init);
const form = (fields: Record<string, string>, cookie = "") => ({
  method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded", ...(cookie ? { cookie } : {}) },
  body: new URLSearchParams(fields).toString(),
});
const cookieOf = (response: Response) => (response.headers.get("set-cookie") ?? "").split(";")[0]!;

test("passwords hashed before, with scrypt, still check, and a PBKDF2 hash made elsewhere checks too", async () => {
  // The standalone server's own format, as it has always written it.
  const salt = randomBytes(16);
  const key = scryptSync("a long password", salt, 32, { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 });
  const old = `scrypt$${salt.toString("base64url")}$${key.toString("base64url")}`;
  assert.equal(await checkPassword("a long password", old), true);
  assert.equal(await checkPassword("a wrong password", old), false);
  // What an edge runtime without scrypt writes.
  const pbkdf2 = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(salt), iterations: 100_000 },
    await crypto.subtle.importKey("raw", new TextEncoder().encode("a long password"), "PBKDF2", false, ["deriveBits"]),
    256,
  );
  const edge = `pbkdf2$100000$${salt.toString("base64url")}$${Buffer.from(pbkdf2).toString("base64url")}`;
  assert.equal(await checkPassword("a long password", edge), true);
  assert.equal(await checkPassword("a long passwore", edge), false);
  assert.equal(await checkPassword("x", "pbkdf2$99999999999$a$b"), false, "an absurd round count is refused, not run");
  assert.match(await hashPassword("a long password"), /^scrypt\$/, "Node has scrypt, so new hashes use it");
});

test("two-factor secrets sealed by the server open here, and the other way round", async () => {
  const secret = "s".repeat(64);
  const key = createHash("sha256").update(`totp:${secret}`).digest();
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const body = Buffer.concat([cipher.update("JBSWY3DPEHPK3PXP", "utf8"), cipher.final()]);
  const sealedByNode = `${iv.toString("base64url")}.${body.toString("base64url")}.${cipher.getAuthTag().toString("base64url")}`;
  assert.equal(await unsealText(sealedByNode, secret), "JBSWY3DPEHPK3PXP");
  assert.equal(await unsealText(sealedByNode, "another secret"), null);

  const [i, b, t] = (await sealText("JBSWY3DPEHPK3PXP", secret)).split(".");
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(i!, "base64url"));
  decipher.setAuthTag(Buffer.from(t!, "base64url"));
  assert.equal(Buffer.concat([decipher.update(Buffer.from(b!, "base64url")), decipher.final()]).toString("utf8"), "JBSWY3DPEHPK3PXP");
});

for (const kind of STORES) {
  test(`${kind}: an app with accounts on makes its first account with its token, then invites people by role`, async () => {
    const rl = runlight({ store: freshStore(kind), secret: "k".repeat(64) });
    const { handler } = rl.routes({ token: "app-token", accounts: true });
    const json = (cookie: string, method: string, path: string, body?: unknown) =>
      handler(req(`/runlight${path}`, { method, headers: { cookie, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));

    // Nobody yet: the dashboard sends you to set up, which asks for the app's token.
    const start = await handler(req("/runlight/"));
    assert.equal(start.status, 303);
    assert.equal(start.headers.get("location"), "/runlight/setup");
    const page = await (await handler(req("/runlight/setup"))).text();
    assert.match(page, /RUNLIGHT_TOKEN/);
    assert.match(page, /action="\/runlight\/setup"/);
    assert.match(page, /href="\/runlight\/auth\.css"/);
    const wrong = await handler(req("/runlight/setup", form({ code: "guess", email: "jon@example.com", password: "a long password", again: "a long password" })));
    assert.equal(wrong.status, 403);
    const made = await handler(req("/runlight/setup", form({ code: "app-token", email: "jon@example.com", password: "a long password", again: "a long password" })));
    assert.equal(made.status, 303);
    assert.equal(made.headers.get("location"), "/runlight/");
    assert.match(made.headers.get("set-cookie") ?? "", /Path=\/runlight;/, "the session is for Runlight's paths only");
    const owner = cookieOf(made);
    assert.equal((await handler(req("/runlight/setup"))).headers.get("location"), "/runlight/login", "setup closes once there is an account");

    // Signed in, the dashboard and its API answer; signed out, they do not.
    assert.equal((await handler(req("/runlight/", { headers: { cookie: owner } }))).status, 200);
    assert.match(await (await handler(req("/runlight/", { headers: { cookie: owner } }))).text(), /data-accounts=""/);
    assert.equal((await handler(req("/runlight/api/sites"))).status, 401);
    assert.equal((await handler(req("/runlight/api/sites", { headers: { cookie: owner } }))).status, 200);
    assert.equal((await handler(req("/runlight/api/sites", { headers: { authorization: "Bearer app-token" } }))).status, 200, "a script's token still works");
    assert.equal(((await (await json(owner, "GET", "/api/account")).json()) as any).account.role, "owner");

    // The owner invites a member, who joins with their own password.
    const sent = (await (await json(owner, "POST", "/api/people", { email: "mo@example.com", role: "member" })).json()) as any;
    assert.equal(sent.emailed, false, "no mail service here, so the link is for passing on");
    const link = new URL(sent.link);
    assert.equal(link.pathname, "/runlight/invite");
    assert.match(await (await handler(req(`${link.pathname}${link.search}`))).text(), /as a member/);
    const joined = await handler(req("/runlight/invite", form({ code: link.searchParams.get("code")!, password: "another long one", again: "another long one" })));
    assert.equal(joined.status, 303);
    const member = cookieOf(joined);

    // A member changes a site's settings, but not people, the mail service, or the assistant's settings.
    assert.equal((await json(member, "POST", "/api/goals", { name: "Signup", kind: "page", match: "/thanks" })).status, 201);
    assert.equal((await json(member, "GET", "/api/people")).status, 403);
    assert.equal(((await (await json(member, "PUT", "/api/mail", {})).json()) as any).code, "admin_only");
    assert.equal((await json(member, "PUT", "/api/assistant", {})).status, 403);

    // Signing out ends the session; signing in again with the password starts one.
    const out = await handler(req("/runlight/logout"));
    assert.equal(out.headers.get("location"), "/runlight/login");
    assert.equal((await handler(req("/runlight/"))).headers.get("location"), "/runlight/login");
    const back = await handler(req("/runlight/login", form({ email: "mo@example.com", password: "another long one", next: "/runlight/?period=7d" })));
    assert.equal(back.status, 303);
    assert.equal(back.headers.get("location"), "/runlight/?period=7d");
    const elsewhere = await handler(req("/runlight/login", form({ email: "mo@example.com", password: "another long one", next: "//evil.example/" })));
    assert.equal(elsewhere.headers.get("location"), "/runlight/", "never sent off the app");
  });
}

test("in development, or left open on purpose, the first account needs no proof; in production without a token, setup stays shut", async () => {
  const before = process.env.NODE_ENV;
  const token = process.env.RUNLIGHT_TOKEN;
  delete process.env.RUNLIGHT_TOKEN;
  try {
    process.env.NODE_ENV = "development";
    const dev = runlight({ store: freshStore("sqlite") }).routes({ accounts: true });
    const page = await (await dev.handler(req("/runlight/setup"))).text();
    assert.doesNotMatch(page, /RUNLIGHT_TOKEN/);
    const made = await dev.handler(req("/runlight/setup", form({ code: "", email: "jon@example.com", password: "a long password", again: "a long password" })));
    assert.equal(made.status, 303);

    process.env.NODE_ENV = "production";
    const open = runlight({ store: freshStore("sqlite") }).routes({ token: null, accounts: true });
    assert.equal((await open.handler(req("/runlight/setup"))).status, 200, "token: null leaves setup open, as it leaves everything");
    const prod = runlight({ store: freshStore("sqlite"), secret: "k".repeat(64) }).routes({ accounts: true });
    const shut = await prod.handler(req("/runlight/setup"));
    assert.equal(shut.status, 403);
    assert.match(await shut.text(), /Set RUNLIGHT_TOKEN/);
    const tried = await prod.handler(req("/runlight/setup", form({ code: "", email: "jon@example.com", password: "a long password", again: "a long password" })));
    assert.equal(tried.status, 403);
  } finally {
    if (before === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = before;
    if (token !== undefined) process.env.RUNLIGHT_TOKEN = token;
  }
});
