// Regressions for what the October 2026 audit found and confirmed.
import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";
import { STORES, cleanup, freshStore, setup, type StoreKind } from "./helpers.js";

after(cleanup);

const auth = { authorization: "Bearer secret", "content-type": "application/json" };

for (const kind of STORES) describe(kind, () => suite(kind));

function suite(kind: StoreKind) {
  const write = (t: ReturnType<typeof setup>, method: string, path: string, body?: unknown, headers: Record<string, string> = auth) =>
    t.routes.handler(new Request(`https://example.com/runlight${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));

  test("a visitor's pageview and event arriving together make one session", async () => {
    const t = setup(kind);
    await Promise.all([
      t.send({ k: "pageview", u: "https://example.com/", i: "p1" }),
      t.send({ k: "event", u: "https://example.com/", n: "Signup", i: "p1" }),
      t.send({ k: "event", u: "https://example.com/", n: "Clicked" }),
    ]);
    const stats = await t.get("/api/stats?period=today&compare=off");
    assert.equal(stats.stats.visits, 1);
    assert.equal(stats.stats.visitors, 1);
  });

  test("renaming a click goal keeps its history, and click and event goals cannot share a name", async () => {
    const t = setup(kind);
    const made = await write(t, "POST", "/api/goals", { name: "Buy", kind: "click", clickBy: "selector", match: ".buy" });
    const { goal } = (await made.json()) as { goal: { id: string } };
    await t.send({ k: "event", u: "https://example.com/", n: "Buy" });
    assert.equal((await write(t, "PATCH", `/api/goals/${goal.id}`, { name: "Purchase button", kind: "click", clickBy: "selector", match: ".buy" })).status, 200);
    const report = await t.get("/api/goals?period=today&compare=off");
    assert.equal(report.goals[0].name, "Purchase button");
    assert.equal(report.goals[0].conversions, 1, "the click made under the old name still counts");
    const clash = await write(t, "POST", "/api/goals", { name: "Signup", kind: "event", match: "Purchase button" });
    assert.equal(clash.status, 400);
  });

  test("page goal wildcards and revenue from properties count the same on every database", async () => {
    const t = setup(kind);
    await t.send({ k: "pageview", u: "https://example.com/thanks/a" });
    for (const amount of [5, "2.5", "-1", "12abc", "1e3", "abc", ".5"]) {
      await t.send({ k: "event", u: "https://example.com/", n: "Paid", p: { amount } }, { ip: "203.0.113.20" });
    }
    await write(t, "POST", "/api/goals", { name: "Lower", kind: "page", match: "/thanks*" });
    await write(t, "POST", "/api/goals", { name: "Upper", kind: "page", match: "/Thanks*" });
    await write(t, "POST", "/api/goals", { name: "Paid", kind: "event", match: "Paid", valueMode: "prop", valueProp: "amount" });
    const goals = Object.fromEntries((await t.get("/api/goals?period=today&compare=off")).goals.map((g: any) => [g.name, g]));
    assert.equal(goals.Lower.conversions, 1);
    assert.equal(goals.Upper.conversions, 0, "paths are case-sensitive, as exact goals already were");
    assert.ok(Math.abs(goals.Paid.revenue - 6.5) < 1e-9, `numbers and plain numeric text count, nothing else (got ${goals.Paid.revenue})`);
  });

  test("the heatmap puts a half-hour timezone's visits in the right local hour", async () => {
    const t = setup(kind, { site: { timezone: "Asia/Kolkata" } });
    // 12:40 UTC on Tuesday, October 6th is 18:10 in Kolkata.
    t.advance(40 * 60_000);
    await t.send({ k: "pageview", u: "https://example.com/" });
    const rhythm = await t.get("/api/rhythm?from=2026-10-06&to=2026-10-06");
    assert.equal(rhythm.grid[1][18], 1);
    assert.equal(rhythm.grid[1][17], 0);
  });

  test("a JSON body must be JSON by its media type, so a no-cors text/plain post cannot pass", async () => {
    const t = setup(kind);
    const sneaky = await write(t, "POST", "/api/goals", { name: "X", kind: "event", match: "X" }, { authorization: "Bearer secret", "content-type": "text/plain; application/json" });
    assert.equal(sneaky.status, 415);
    const fine = await write(t, "POST", "/api/goals", { name: "X", kind: "event", match: "X" }, { authorization: "Bearer secret", "content-type": "application/json; charset=utf-8" });
    assert.equal(fine.status, 201);
  });

  test("a managed install counts the first hit it gets, before anything else has loaded its sites", async () => {
    const store = freshStore(kind);
    const first = runlight({ store, managedSites: true });
    await first.addSite({ hostnames: "blog.example.com" });
    const cold = runlight({ store, managedSites: true });
    const { POST, GET } = cold.routes({ token: "secret" });
    await POST(new Request("https://stats.example.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": "203.0.113.4" }, body: JSON.stringify({ k: "pageview", u: "https://blog.example.com/" }) }));
    const stats = (await (await GET(new Request("https://stats.example.com/runlight/api/stats?period=today", { headers: auth }))).json()) as any;
    assert.equal(stats.stats.pageviews, 1);
  });
}

test("on SQLite, a write made while a transaction is open is never rolled back with it", async () => {
  const store = sqlite({ path: ":memory:" });
  await store.migrate();
  const event = (path: string) => ({ site: "s", ts: 1, kind: "pageview" as const, visitor: "v", session: "x", pageview: "", path, hostname: "", title: "", name: "", props: null, engagedMs: 0, scroll: null, link: "" });
  let release!: () => void;
  const open = store
    .transaction(async (tx) => {
      await tx.insertEvent(event("/inside"));
      await new Promise<void>((resolve) => (release = resolve));
      throw new Error("roll back");
    })
    .catch(() => "rolled back");
  // Live traffic during the import.
  const live = store.insertEvent(event("/live"));
  const second = store.transaction(async (tx) => tx.insertEvent(event("/second")));
  await new Promise((resolve) => setTimeout(resolve, 10));
  release();
  assert.equal(await open, "rolled back");
  await live;
  await second;
  const paths = (await store.db.all<{ path: string }>(`SELECT path FROM rl_events ORDER BY path`)).map((r) => r.path);
  assert.deepEqual(paths, ["/live", "/second"]);
});

test("a click goal's selector with $' or $& leaves the tracker script valid", async () => {
  const t = setup("sqlite");
  for (const match of [".a$'", "[data-x=\"$&\"]", ".b$`"]) {
    const r = await t.routes.handler(new Request("https://example.com/runlight/api/goals", { method: "POST", headers: auth, body: JSON.stringify({ name: `G ${match}`, kind: "click", clickBy: "selector", match }) }));
    assert.equal(r.status, 201);
  }
  const script = await (await t.routes.GET(new Request("https://example.com/runlight/s.js"))).text();
  assert.doesNotThrow(() => new Function(script), "s.js still parses");
  assert.ok(script.includes(".a$'"));
});

test("filters on inherited object keys are refused, not run as SQL", async () => {
  const t = setup("sqlite");
  const r = await t.routes.GET(new Request("https://example.com/runlight/api/stats?filter=constructor:is:x", { headers: auth }));
  assert.equal(r.status, 400);
});

test("links and link domains only change from the site that owns them", async () => {
  const rl = runlight({
    store: sqlite({ path: ":memory:" }),
    sites: [
      { id: "a", hostnames: ["a.com"] },
      { id: "b", hostnames: ["b.com"] },
    ],
  });
  const { POST, PATCH, DELETE } = rl.routes({ token: "secret" });
  const call = (handler: typeof POST, method: string, path: string, body?: unknown) =>
    handler(new Request(`https://x.com/runlight${path}`, { method, headers: auth, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
  const made = (await (await call(POST, "POST", "/api/links?site=a", { url: "https://a.com/x" })).json()) as { link: { id: string } };
  assert.equal((await call(PATCH, "PATCH", `/api/links/${made.link.id}?site=b`, { name: "stolen" })).status, 404);
  assert.equal((await call(DELETE, "DELETE", `/api/links/${made.link.id}?site=b`)).status, 404);
  assert.equal((await call(POST, "POST", "/api/link-domains?site=a", { domain: "go.a.com" })).status, 201);
  assert.equal((await call(POST, "POST", "/api/link-domains?site=b", { domain: "go.a.com" })).status, 409);
  assert.equal((await call(DELETE, "DELETE", "/api/link-domains/go.a.com?site=b")).status, 404);
  assert.equal((await call(DELETE, "DELETE", `/api/links/${made.link.id}?site=a`)).status, 200);
});

test("a saved SMTP password is kept only while the server it goes to stays the same", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), secret: "k".repeat(32) });
  const base = { service: "smtp", host: "smtp.example.com", port: "587", security: "starttls", username: "me", from: "r@example.com" };
  await rl.saveMailSettings({ ...base, password: "hunter2-long" });
  await rl.saveMailSettings({ ...base, password: "", from: "reports@example.com" });
  assert.equal((await rl.mailSettings())?.password, "hunter2-long", "same server, blank field: kept");
  await rl.saveMailSettings({ ...base, host: "evil.example", password: "", from: "reports@example.com" });
  assert.equal((await rl.mailSettings())?.password ?? "", "", "a new host needs the password typed again");
});

test("a mail service's reply shows only its own message, and a webhook only its status", async () => {
  const { serviceMessage } = await import("../src/mail/transports.js");
  assert.equal(serviceMessage(JSON.stringify({ message: "The domain is not verified" })), "The domain is not verified");
  assert.equal(serviceMessage(JSON.stringify({ errors: [{ message: "Bad key", field: "x" }] })), "Bad key");
  assert.equal(serviceMessage("<ErrorResponse><Error><Message>Email address is not verified.</Message></Error></ErrorResponse>"), "Email address is not verified.");
  assert.equal(serviceMessage("<html><body>internal admin page with secrets</body></html>"), "");
});

test("each site's tracker carries only its own click rules on the standalone server", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), managedSites: true });
  await rl.addSite({ hostnames: "client-a.com" });
  await rl.addSite({ hostnames: "client-b.com" });
  const { GET, POST } = rl.routes({ token: "secret" });
  for (const [site, name] of [["client-a.com", "Upgrade to Pro"], ["client-b.com", "Book a demo"]]) {
    await POST(new Request(`https://stats.x.com/runlight/api/goals?site=${site}`, { method: "POST", headers: auth, body: JSON.stringify({ name, kind: "click", clickBy: "selector", match: ".cta" }) }));
  }
  const script = async (query: string) => (await GET(new Request(`https://stats.x.com/runlight/s.js${query}`))).text();
  const a = await script("?site=client-a.com");
  assert.ok(a.includes("Upgrade to Pro"));
  assert.ok(!a.includes("Book a demo") && !a.includes("client-b.com"), "another site's goals and domain stay hidden");
  const bare = await script("");
  assert.ok(!bare.includes("Upgrade to Pro") && !bare.includes("Book a demo"), "a script that names no site carries no rules");
  assert.ok(!(await script("?site=nobody")).includes("client-"));
});

test("a site's observe key reports AI fetches for that site only, and reads nothing", async () => {
  const rl = runlight({
    store: sqlite({ path: ":memory:" }),
    sites: [
      { id: "a", hostnames: ["a.com"] },
      { id: "b", hostnames: ["b.com"] },
    ],
  });
  const { GET, POST } = rl.routes({ token: "secret" });
  const keyFor = async (site: string) => ((await (await GET(new Request(`https://x.com/runlight/api/observe-key?site=${site}`, { headers: auth }))).json()) as { key: string }).key;
  const a = await keyFor("a");
  assert.match(a, /^rlo_[a-f0-9]{40}$/);
  assert.equal(await keyFor("a"), a, "the same key until it is replaced");
  const gpt = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot";
  const report = (key: string, url: string) =>
    POST(new Request("https://x.com/runlight/api/observe", { method: "POST", headers: { authorization: `Bearer ${key}`, "content-type": "application/json" }, body: JSON.stringify({ url, userAgent: gpt }) }));
  assert.equal((await report(a, "https://a.com/post")).status, 204);
  assert.equal((await report(a, "https://b.com/post")).status, 401, "a's key cannot write into b");
  assert.equal((await report("rlo_wrong", "https://a.com/post")).status, 401);
  assert.equal((await GET(new Request("https://x.com/runlight/api/stats?site=a", { headers: { authorization: `Bearer ${a}` } }))).status, 401, "it reads nothing");
  const replaced = ((await (await POST(new Request("https://x.com/runlight/api/observe-key/new?site=a", { method: "POST", headers: auth }))).json()) as { key: string }).key;
  assert.notEqual(replaced, a);
  assert.equal((await report(a, "https://a.com/post")).status, 401, "the old key stops working");
  const pages = (await (await GET(new Request("https://x.com/runlight/api/breakdown?site=a&period=today&dimension=ai_page", { headers: auth }))).json()) as any;
  assert.deepEqual(pages.rows.map((r: any) => r.value), ["/post"]);
});

test("a local test counts while a site is being set up, and local traffic is ignored after its first visit", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["example.com"] } });
  const { POST, GET } = rl.routes({ token: "secret" });
  const hit = (url: string) =>
    POST(new Request("https://x.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": "203.0.113.5" }, body: JSON.stringify({ k: "pageview", u: url }) }));
  await hit("http://localhost:3000/");
  const views = async () => ((await (await GET(new Request("https://x.com/runlight/api/stats?period=today", { headers: auth }))).json()) as any).stats.pageviews;
  assert.equal(await views(), 1, "the first local test shows up");
  await hit("http://localhost:3000/again");
  await hit("http://myapp.test/");
  assert.equal(await views(), 1, "after that, local hits are ignored");
  await hit("https://example.com/");
  assert.equal(await views(), 2);
});

test("an export is a ZIP of CSV files for the view, and a share link can export its own site", async () => {
  const { csvRow } = await import("../src/zip.js");
  assert.equal(csvRow(["=SUM(A1)", "+1", "-2", "a,b", 'say "hi"', 12]), `'=SUM(A1),'+1,-2,"a,b","say ""hi""",12`, "spreadsheet formulas are defused");
  const t = setup("sqlite");
  await t.send({ k: "pageview", u: "https://example.com/pricing" });
  const answer = await t.routes.GET(new Request("https://example.com/runlight/api/export?period=today", { headers: { authorization: "Bearer secret" } }));
  assert.equal(answer.headers.get("content-type"), "application/zip");
  const bytes = new Uint8Array(await answer.arrayBuffer());
  assert.deepEqual([...bytes.slice(0, 4)], [0x50, 0x4b, 0x03, 0x04], "starts like a ZIP");
  const text = new TextDecoder().decode(bytes);
  for (const name of ["overview.csv", "over-time.csv", "page.csv", "channel.csv"]) assert.ok(text.includes(name), name);
  assert.ok(text.includes("/pricing,1,1"));
  // A spreadsheet reads the units as they are: paths as written, percents, and seconds.
  await t.send({ k: "pageview", u: "https://example.com/café", i: "cafe" });
  const sheet = await (await t.routes.GET(new Request("https://example.com/runlight/api/breakdown?period=today&dimension=page&format=csv", { headers: { authorization: "Bearer secret" } }))).text();
  assert.match(sheet.split("\n")[0]!, /^value,visitors,pageviews,timeOnPageSeconds,scrollDepth/);
  assert.match(sheet, /\/café,/);
  const made = await t.routes.POST(new Request("https://example.com/runlight/api/shares", { method: "POST", headers: auth, body: "{}" }));
  const { share } = (await made.json()) as { share: { id: string } };
  const shared = await t.routes.GET(new Request("https://example.com/runlight/api/export?period=today", { headers: { "x-runlight-share": share.id } }));
  assert.equal(shared.status, 200);
});

// SQLite has one connection, so a transaction holds it and other writes wait their turn.
{
  test("sqlite: a tracker hit that lands during an import that rolls back is still kept", async () => {
    const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["example.com"] } });
    await rl.init();
    const { POST, GET } = rl.routes({ token: "t" });
    let hit: Promise<Response> | null = null;
    await assert.rejects(
      rl.store.transaction(async (store) => {
        await store.db.run(`INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES ('x', 'default', '', 'gone', '', 'https://a.com', 0, 0)`);
        // A visitor arrives while the import is half written.
        hit = POST(new Request("https://example.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": "203.0.113.5" }, body: JSON.stringify({ k: "pageview", u: "https://example.com/" }) }));
        await new Promise((resolve) => setTimeout(resolve, 20));
        throw new Error("the import failed");
      }),
      /the import failed/,
    );
    await hit;
    assert.equal(await rl.store.linkBySlug("gone"), null, "the import rolled back");
    const stats = (await (await GET(new Request("https://example.com/runlight/api/stats?period=today", { headers: { authorization: "Bearer t" } }))).json()) as any;
    assert.equal(stats.stats.pageviews, 1, "the visit was written after the rollback, not inside it");
  });
}

test("a write signed in by cookie must be JSON, so a form on another page cannot make one", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "a", name: "Site A", hostnames: ["a.com"] }] });
  const { POST } = rl.routes({ authorize: (request) => request.headers.get("cookie") === "session=ok" });
  const form = await POST(new Request("https://x.com/runlight/api/observe-key/new?site=a", { method: "POST", headers: { cookie: "session=ok", "content-type": "application/x-www-form-urlencoded" }, body: "" }));
  assert.equal(form.status, 415);
  const page = await POST(new Request("https://x.com/runlight/api/observe-key/new?site=a", { method: "POST", headers: { cookie: "session=ok", "content-type": "application/json" }, body: "{}" }));
  assert.equal(page.status, 200);
});

test("a write without a cookie must be JSON too, for routes left open behind Basic auth or an address list", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "a", name: "Site A", hostnames: ["a.com"] }] });
  const { GET, POST } = rl.routes({ token: null, cronSecret: "cron", observeKey: "observe" });
  const key = ((await (await GET(new Request("https://x.com/runlight/api/observe-key?site=a"))).json()) as any).key;
  // What a form on another page sends: the browser adds the Basic credentials itself.
  const form = await POST(new Request("https://x.com/runlight/api/observe-key/new?site=a", { method: "POST", headers: { authorization: "Basic YWRtaW46cGFzcw==", "content-type": "text/plain", origin: "https://evil.example" }, body: "x=y" }));
  assert.equal(form.status, 415);
  assert.equal(((await (await GET(new Request("https://x.com/runlight/api/observe-key?site=a"))).json()) as any).key, key, "the key stayed");
  // A bearer token, which a browser never adds on its own, still needs no JSON: a platform cron, a plugin, the tracker.
  assert.equal((await POST(new Request("https://x.com/runlight/api/check", { method: "POST", headers: { authorization: "Bearer cron" } }))).status, 200);
  assert.equal((await POST(new Request("https://x.com/runlight/api/observe", { method: "POST", headers: { authorization: "Bearer observe", "content-type": "application/json" }, body: JSON.stringify({ url: "https://a.com/", userAgent: "GPTBot/1.0" }) }))).status, 204);
  assert.equal((await POST(new Request("https://x.com/runlight/e", { method: "POST", headers: { "content-type": "text/plain", "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36" }, body: JSON.stringify({ k: "pageview", u: "https://a.com/" }) }))).status, 202);
});

test("short link clicks are not visits in the heatmap, raw or rolled up, nor the first visit", async () => {
  const now = Date.UTC(2026, 9, 7, 12);
  let clock = now;
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "a", name: "Site A", hostnames: ["a.com"] }], now: () => clock });
  await rl.init();
  const day = Date.UTC(2026, 9, 5, 15);
  // A session opened only by a short link click, then a real visit.
  await rl.store.db.run(`INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'a', 'v1', ?, ?, 0, 0, 0)`, [day - 3_600_000, day - 3_600_000]);
  await rl.store.db.run(`INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'a', 'v2', ?, ?, 1, 0, 0)`, [day, day]);
  assert.equal(await rl.store.firstOwnVisit("a"), day);
  const query = { site: "a", from: Date.UTC(2026, 9, 1), to: Date.UTC(2026, 9, 7), filters: [] };
  const sum = (rows: Array<{ visits: number }>) => rows.reduce((n, r) => n + r.visits, 0);
  assert.equal(sum(await rl.store.hourly(query)), 1, "raw");
  clock = now + 3 * 3_600_000;
  await rl.buildRollups();
  assert.equal(sum(await rl.store.hourly(query)), 1, "rolled up");
});

test("a read token can open a link's stats, and still cannot change it", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "a", name: "Site A", hostnames: ["a.com"] }] });
  const { handler } = rl.routes({ token: "owner" });
  const owner = { authorization: "Bearer owner", "content-type": "application/json" };
  const made = (await (await handler(new Request("https://x.com/runlight/api/links?site=a", { method: "POST", headers: owner, body: JSON.stringify({ url: "https://example.com/sale" }) }))).json()) as any;
  const secret = ((await (await handler(new Request("https://x.com/runlight/api/tokens", { method: "POST", headers: owner, body: JSON.stringify({ name: "Script", site: "a" }) }))).json()) as any).secret as string;
  const read = { authorization: `Bearer ${secret}` };
  assert.equal((await handler(new Request(`https://x.com/runlight/api/links/${made.link.id}?period=7d`, { headers: read }))).status, 200);
  assert.equal((await handler(new Request(`https://x.com/runlight/api/links/${made.link.id}`, { method: "DELETE", headers: read }))).status, 401);
});
