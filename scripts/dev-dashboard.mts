// A dashboard full of made-up traffic, for working on the UI.
//
//   npm run dev:dashboard            then open http://localhost:4800/runlight/
//   npm run dev:dashboard -- --reseed           (all made-up data)
//   npm run dev:dashboard -- --reseed-links     (only the short links)
//   RUNLIGHT_DEV_DB=/tmp/empty.db PORT=4802 npm run dev:dashboard -- --empty   (a site before its first visit)
//
// The bundle is rebuilt on every page load, so a refresh shows an edit.
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { bundle, locales } from "../packages/dashboard/scripts/build.mjs";
import { world } from "../packages/dashboard/scripts/world.mjs";
import { runlight } from "../packages/sdk/src/index.ts";
import { toNodeHandler } from "../packages/sdk/src/node.ts";
import { sqlite } from "../packages/sdk/src/stores/sqlite.ts";
import type { SessionRow } from "../packages/sdk/src/store.ts";

const PORT = Number(process.env.PORT ?? 4800);
const FILE = process.env.RUNLIGHT_DEV_DB ?? new URL("../data/dev.db", import.meta.url).pathname;
const DAYS = 120;

if (process.argv.includes("--reseed")) for (const suffix of ["", "-wal", "-shm"]) rmSync(FILE + suffix, { force: true });
const fresh = !existsSync(FILE);
mkdirSync(new URL("../data/", import.meta.url).pathname, { recursive: true });

const rl = runlight({ store: sqlite({ path: FILE }), site: { name: "joncphillips.com", hostnames: ["joncphillips.com"], timezone: "America/Toronto" } });
await rl.init();
const empty = process.argv.includes("--empty");
if (fresh && !empty) await seed();
if (process.argv.includes("--reseed-links")) {
  await rl.store.db.run("DELETE FROM rl_sessions WHERE id IN (SELECT session FROM rl_events WHERE kind = 'click')");
  await rl.store.db.run("DELETE FROM rl_events WHERE kind = 'click'");
  await rl.store.db.run("DELETE FROM rl_links");
}
if (!empty && (await rl.store.db.all("SELECT id FROM rl_links LIMIT 1")).length === 0) await seedLinks();

if (!empty && (await rl.store.goals("default")).length === 0) await seedGoals();

const routes = toNodeHandler(rl.routes({ token: null }).handler);
const links = toNodeHandler(rl.linkHandler());

createServer(async (req, res) => {
  const path = (req.url ?? "/").split("?")[0]!;
  // Share pages get the same live bundle; the API refuses a share id that does not exist.
  const share = /^\/runlight\/share\/([a-f0-9]{32})\/?$/.exec(path)?.[1] ?? "";
  if (path === "/runlight" || path === "/runlight/" || share) {
    res.setHeader("content-type", "text/html; charset=utf-8");
    res.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Runlight (dev)</title><link rel="stylesheet" href="/runlight/dev.css"></head>
<body><div id="app" data-base="/runlight"${share ? ` data-share="${share}"` : ""} data-world="/runlight/world.json" data-locales='${JSON.stringify(Object.fromEntries(Object.keys(locales()).map((c) => [c, `/runlight/locales/${c}.json`])))}'></div><script type="module" src="/runlight/dev.js"></script></body></html>`);
    return;
  }
  if (path === "/runlight/dev.js" || path === "/runlight/dev.css") {
    try {
      const { js, css } = await bundle({ minify: false });
      res.setHeader("content-type", path.endsWith(".js") ? "application/javascript" : "text/css");
      res.end(path.endsWith(".js") ? js : css);
    } catch (error) {
      res.statusCode = 500;
      res.end(String(error));
    }
    return;
  }
  const lang = /^\/runlight\/locales\/([a-z]+)\.json$/.exec(path);
  if (lang) {
    const all = locales();
    res.setHeader("content-type", "application/json");
    res.statusCode = all[lang[1]!] ? 200 : 404;
    res.end(all[lang[1]!] ?? "{}");
    return;
  }
  if (path === "/runlight/world.json") {
    res.setHeader("content-type", "application/json");
    res.end(world());
    return;
  }
  if (path.startsWith("/go/")) return void links(req, res);
  if (path.startsWith("/runlight")) return void routes(req, res);
  res.writeHead(302, { location: "/runlight/" }).end();
}).listen(PORT, () => console.log(`Runlight dev dashboard: http://localhost:${PORT}/runlight/`));

// Made-up traffic with a weekly rhythm, slow growth, and the mix of sources,
// places, and devices a small personal site gets.

function pick<T>(items: Array<[T, number]>): T {
  const total = items.reduce((sum, [, w]) => sum + w, 0);
  let r = Math.random() * total;
  for (const [item, w] of items) if ((r -= w) <= 0) return item;
  return items[items.length - 1]![0];
}

function randomHex(n: number): string {
  return Array.from({ length: n }, () => Math.floor(Math.random() * 16).toString(16)).join("");
}

async function seed() {
  console.log(`Seeding ${DAYS} days of made-up traffic...`);
  const store = rl.store;
  const pages: Array<[string, number]> = [
    ["/", 30], ["/blog/building-runlight", 14], ["/blog/cronwatch", 9], ["/blog/notes-on-photography", 7],
    ["/about", 8], ["/projects", 6], ["/blog/self-hosting-in-2026", 5], ["/uses", 4], ["/contact", 3],
    ["/blog/a-year-of-small-tools", 3], ["/now", 2],
  ];
  const sources: Array<[{ ref: string; source: string; channel: string; utm?: [string, string, string] }, number]> = [
    [{ ref: "", source: "", channel: "Direct" }, 30],
    [{ ref: "google.com", source: "Google", channel: "Organic Search" }, 28],
    [{ ref: "bing.com", source: "Bing", channel: "Organic Search" }, 3],
    [{ ref: "duckduckgo.com", source: "DuckDuckGo", channel: "Organic Search" }, 3],
    [{ ref: "chatgpt.com", source: "ChatGPT", channel: "AI" }, 6],
    [{ ref: "perplexity.ai", source: "Perplexity", channel: "AI" }, 2],
    [{ ref: "claude.ai", source: "Claude", channel: "AI" }, 2],
    [{ ref: "news.ycombinator.com", source: "Hacker News", channel: "Social" }, 5],
    [{ ref: "x.com", source: "X", channel: "Social" }, 3],
    [{ ref: "bsky.app", source: "Bluesky", channel: "Social" }, 3],
    [{ ref: "linkedin.com", source: "LinkedIn", channel: "Social" }, 2],
    [{ ref: "github.com", source: "GitHub", channel: "Social" }, 3],
    [{ ref: "", source: "Newsletter", channel: "Email", utm: ["newsletter", "email", "october-issue"] }, 4],
    [{ ref: "", source: "producthunt", channel: "Campaign", utm: ["producthunt", "launch", "runlight-launch"] }, 1],
    [{ ref: "someblog.net", source: "someblog.net", channel: "Referral" }, 3],
    [{ ref: "dev.to", source: "Dev.to", channel: "Social" }, 1],
  ];
  const places: Array<[[string, string, string], number]> = [
    [["CA", "CA-ON", "Toronto"], 14], [["CA", "CA-QC", "Montreal"], 4], [["US", "US-CA", "San Francisco"], 10],
    [["US", "US-NY", "New York"], 9], [["US", "US-TX", "Austin"], 4], [["GB", "GB-ENG", "London"], 9],
    [["DE", "DE-BE", "Berlin"], 6], [["FR", "FR-IDF", "Paris"], 4], [["NL", "NL-NH", "Amsterdam"], 4],
    [["AU", "AU-NSW", "Sydney"], 3], [["IN", "IN-KA", "Bengaluru"], 4], [["JP", "JP-13", "Tokyo"], 2],
    [["BR", "BR-SP", "São Paulo"], 2], [["SE", "SE-AB", "Stockholm"], 2],
  ];
  const clients: Array<[[string, string, string, string, string, string], number]> = [
    [["Chrome", "129", "macOS", "", "desktop", "1512x982"], 22], [["Safari", "18", "macOS", "", "desktop", "1440x900"], 12],
    [["Chrome", "129", "Windows", "10", "desktop", "1920x1080"], 14], [["Edge", "129", "Windows", "10", "desktop", "1920x1080"], 5],
    [["Firefox", "131", "Windows", "10", "desktop", "1536x864"], 4], [["Firefox", "131", "Linux", "", "desktop", "2560x1440"], 3],
    [["Safari", "18", "iOS", "18", "mobile", "393x852"], 18], [["Chrome", "129", "Android", "14", "mobile", "412x915"], 10],
    [["Samsung Internet", "26", "Android", "14", "mobile", "384x832"], 2], [["Safari", "17", "iOS", "17", "tablet", "820x1180"], 3],
    [["Brave", "129", "macOS", "", "desktop", "1728x1117"], 2],
  ];
  const languages: Array<[string, number]> = [["en-US", 40], ["en-GB", 12], ["en-CA", 12], ["de-DE", 6], ["fr-FR", 5], ["nl-NL", 3], ["ja-JP", 2]];
  const hours: Array<[number, number]> = Array.from({ length: 24 }, (_, h) => [h, 1 + 4 * Math.exp(-((h - 14) ** 2) / 18)]);
  const agents: Array<[string, number]> = [["ChatGPT-User", 6], ["Claude-User", 3], ["Perplexity-User", 2], ["GPTBot", 8], ["ClaudeBot", 6], ["PerplexityBot", 3], ["CCBot", 2]];

  const now = Date.now();
  const startDay = now - DAYS * 86_400_000;
  await store.db.run("BEGIN");
  let sessions = 0;
  for (let day = 0; day < DAYS; day++) {
    const dayStart = Math.floor((startDay + day * 86_400_000) / 86_400_000) * 86_400_000;
    const weekday = new Date(dayStart).getUTCDay();
    const base = 120 + day * 1.4;
    const spike = day === DAYS - 20 ? 5 : day === DAYS - 19 ? 2.2 : 1;
    const count = Math.round(base * (weekday === 0 || weekday === 6 ? 0.65 : 1) * spike * (0.85 + Math.random() * 0.3));
    const today: string[] = [];
    const isLast = day === DAYS - 1;
    for (let i = 0; i < count + (isLast ? 6 : 0); i++) {
      // The last few visits of the run are happening right now.
      const start = isLast && i >= count ? now - Math.floor(Math.random() * 240_000) : dayStart + pick(hours) * 3_600_000 + Math.floor(Math.random() * 3_600_000);
      if (start > now) continue;
      const src = spike > 2 && Math.random() < 0.6 ? sources[7]![0] : pick(sources);
      const [country, region, city] = pick(places);
      const [browser, browserVersion, os, osVersion, device, screen] = pick(clients);
      const views = Math.min(8, 1 + Math.floor(-Math.log(Math.random()) * 0.9));
      const id = randomHex(24);
      // Some people come back later the same day: same hash, new visit.
      const visitor = today.length > 0 && Math.random() < 0.18 ? today[Math.floor(Math.random() * today.length)]! : randomHex(16);
      today.push(visitor);
      const row: SessionRow = {
        id, site: "default", visitor, startedAt: start, hostname: "joncphillips.com",
        referrerHost: src.ref, referrerPath: src.ref ? "/" : "", source: src.source, channel: src.channel,
        utmSource: src.utm?.[0] ?? "", utmMedium: src.utm?.[1] ?? "", utmCampaign: src.utm?.[2] ?? "", utmTerm: "", utmContent: "",
        country, region, city, browser, browserVersion, os, osVersion, device, screen, language: pick(languages),
      };
      await store.insertSession(row);
      let t = start;
      let engagedTotal = 0;
      for (let v = 0; v < views; v++) {
        const path = v === 0 && src.source === "Hacker News" ? "/blog/building-runlight" : pick(pages);
        const pv = randomHex(12);
        await store.touchSession(id, t, "pageview", path);
        await store.insertEvent({ site: "default", ts: t, kind: "pageview", visitor, session: id, pageview: pv, path, hostname: "joncphillips.com", title: path, name: "", props: null, engagedMs: 0, scroll: null, link: "" });
        const engaged = views === 1 && Math.random() < 0.45 ? Math.floor(Math.random() * 9000) : Math.floor(8000 + Math.random() * 140_000 * (path.startsWith("/blog") ? 1.6 : 0.6));
        if (engaged >= 1000) {
          await store.addEngagement(id, engaged);
          await store.insertEvent({ site: "default", ts: t + engaged, kind: "engagement", visitor, session: id, pageview: pv, path, hostname: "joncphillips.com", title: "", name: "", props: null, engagedMs: engaged, scroll: Math.floor(30 + Math.random() * 70), link: "" });
          engagedTotal += engaged;
        }
        if (Math.random() < 0.06) {
          const name = pick<string>([["Outbound link", 5], ["Newsletter signup", 2], ["File download", 1], ["Copy code", 2]]);
          await store.touchSession(id, t + 2000, "event", path);
          await store.insertEvent({ site: "default", ts: t + 2000, kind: "event", visitor, session: id, pageview: pv, path, hostname: "joncphillips.com", title: "", name, props: null, engagedMs: 0, scroll: null, link: "" });
        }
        t += Math.max(engaged, 5000) + 2000;
      }
      void engagedTotal;
      sessions++;
    }
    const fetches = Math.round(20 + Math.random() * 25);
    for (let f = 0; f < fetches; f++) {
      const ts = dayStart + Math.floor(Math.random() * 86_400_000);
      if (ts > now) continue;
      const name = pick(agents);
      await store.insertEvent({ site: "default", ts, kind: "fetch", visitor: "", session: "", pageview: "", path: pick(pages), hostname: "joncphillips.com", title: "", name, props: null, engagedMs: 0, scroll: null, link: "" });
    }
  }
  await store.db.run("COMMIT");
  console.log(`Seeded ${sessions} visits.`);
}

/** Made-up short links with four months of clicks, most on a custom link domain. */
async function seedLinks() {
  console.log("Seeding short links...");
  const store = rl.store;
  await store.addLinkDomain("t.thedailypreset.com", "default", Date.now());
  const names = [
    "Golden hour preset", "Moody film pack", "Free presets", "Portrait glow", "Black and white set", "Winter blues",
    "Lightroom mobile guide", "Newsletter issue 52", "Instagram bio", "YouTube description", "Podcast episode 12",
    "Spring sale", "Black Friday", "Preset bundle", "Desert tones", "City nights", "Cinematic pack", "Faded film",
    "Travel collection", "Wedding pack", "Product launch", "Affiliate: camera bag", "Affiliate: tripod", "Gear list",
    "Workshop signup", "Course waitlist", "Discord invite", "Feedback form", "Behind the scenes", "Brand kit",
  ];
  const now = Date.now();
  const made: Array<{ id: string; weight: number; created: number }> = [];
  for (const [i, name] of names.entries()) {
    const own = i % 5 === 4;
    const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 24);
    const created = now - Math.floor((DAYS - (i % 9) * 3) * 86_400_000);
    const id = randomHex(24);
    await store.insertLink({
      id, site: "default", domain: own ? "" : "t.thedailypreset.com", slug, name,
      url: own ? `https://joncphillips.com/${slug}` : `https://thedailypreset.com/${slug}?ref=link`,
      createdAt: created, updatedAt: created,
    });
    made.push({ id, weight: Math.max(0.2, 6 / (i + 1)), created });
  }
  const refs: Array<[[string, string, string], number]> = [
    [["instagram.com", "Instagram", "Social"], 30], [["", "", "Direct"], 25], [["youtube.com", "YouTube", "Social"], 12],
    [["", "Newsletter", "Email"], 15], [["t.co", "X", "Social"], 6], [["pinterest.com", "Pinterest", "Social"], 8],
  ];
  const places: Array<[[string, string, string], number]> = [
    [["US", "US-CA", "Los Angeles"], 30], [["CA", "CA-ON", "Toronto"], 15], [["GB", "GB-ENG", "London"], 12],
    [["DE", "DE-BY", "Munich"], 8], [["AU", "AU-VIC", "Melbourne"], 6], [["BR", "BR-SP", "São Paulo"], 5],
  ];
  const devices: Array<[[string, string, string, string, string], number]> = [
    [["Safari", "18", "iOS", "18", "mobile"], 45], [["Chrome", "129", "Android", "14", "mobile"], 20],
    [["Chrome", "129", "macOS", "", "desktop"], 20], [["Chrome", "129", "Windows", "10", "desktop"], 15],
  ];
  await store.db.run("BEGIN");
  let clicks = 0;
  const recent: string[] = [];
  for (let day = 0; day < DAYS; day++) {
    const dayStart = Math.floor((now - (DAYS - day) * 86_400_000) / 86_400_000) * 86_400_000;
    for (const link of made) {
      if (dayStart < link.created) continue;
      const n = Math.round(link.weight * (2 + Math.random() * 6) * (day > DAYS - 30 ? 1.4 : 1));
      for (let k = 0; k < n; k++) {
        const ts = dayStart + Math.floor(Math.random() * 86_400_000);
        if (ts > now) continue;
        const [refHost, source, channel] = pick(refs);
        const [country, region, city] = pick(places);
        const [browser, browserVersion, os, osVersion, device] = pick(devices);
        const session = randomHex(24);
        // About a third of clicks come from someone who clicked before that day.
        const visitor = recent.length > 20 && Math.random() < 0.35 ? recent[Math.floor(Math.random() * recent.length)]! : randomHex(16);
        recent.push(visitor);
        if (recent.length > 400) recent.shift();
        await store.insertSession({
          id: session, site: "default", visitor, startedAt: ts, hostname: "t.thedailypreset.com",
          referrerHost: refHost, referrerPath: refHost ? "/" : "", source, channel,
          utmSource: source === "Newsletter" ? "newsletter" : "", utmMedium: source === "Newsletter" ? "email" : "", utmCampaign: "", utmTerm: "", utmContent: "",
          country, region, city, browser, browserVersion, os, osVersion, device, screen: "", language: "en-US",
        });
        await store.touchSession(session, ts, "click", "/");
        await store.insertEvent({ site: "default", ts, kind: "click", visitor, session, pageview: "", path: "/", hostname: "t.thedailypreset.com", title: "", name: "", props: null, engagedMs: 0, scroll: null, link: link.id });
        clicks++;
      }
    }
  }
  await store.db.run("COMMIT");
  console.log(`Seeded ${made.length} links and ${clicks} clicks.`);
}

/** Made-up purchases on some existing visits, and a goal of each kind. */
async function seedGoals() {
  const store = rl.store;
  const [{ n }] = await store.db.all<{ n: number }>("SELECT COUNT(*) AS n FROM rl_sessions WHERE site = 'default' AND hostname = 'joncphillips.com'");
  const buyers = await store.db.all<{ id: string; visitor: string; last_at: number }>(
    "SELECT id, visitor, last_at FROM rl_sessions WHERE site = 'default' AND hostname = 'joncphillips.com' ORDER BY RANDOM() LIMIT ?",
    [Math.round(Number(n) * 0.012)],
  );
  await store.db.run("BEGIN");
  for (const b of buyers) {
    const revenue = pick<number>([[29, 5], [49, 4], [99, 2], [199, 1]]);
    await store.insertEvent({ site: "default", ts: Number(b.last_at), kind: "event", visitor: b.visitor, session: b.id, pageview: "", path: "/store/checkout", hostname: "joncphillips.com", title: "", name: "Purchase", props: { revenue }, engagedMs: 0, scroll: null, link: "" });
  }
  await store.db.run("COMMIT");
  const now = Date.now();
  const base = { site: "default", clickBy: "" as const, valueMode: "none" as const, value: 0, valueProp: "", currency: "USD" };
  await store.saveGoal({ ...base, id: randomHex(24), name: "Purchase", kind: "event", match: "Purchase", valueMode: "prop", valueProp: "revenue", createdAt: now });
  await store.saveGoal({ ...base, id: randomHex(24), name: "Newsletter signup", kind: "event", match: "Newsletter signup", valueMode: "fixed", value: 2, createdAt: now + 1 });
  await store.saveGoal({ ...base, id: randomHex(24), name: "Read the Runlight post", kind: "page", match: "/blog/building-runlight", createdAt: now + 2 });
  await store.saveGoal({ ...base, id: randomHex(24), name: "Email me", kind: "click", clickBy: "selector", match: "a[href^='mailto:']", createdAt: now + 3 });
  console.log(`Seeded ${buyers.length} purchases and 4 goals.`);
}
