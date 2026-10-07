// A dashboard full of made-up traffic, for working on the UI.
//
//   npm run dev:dashboard            then open http://localhost:4800/runlight/
//   npm run dev:dashboard -- --reseed
//
// The bundle is rebuilt on every page load, so a refresh shows an edit.
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { bundle } from "../packages/dashboard/scripts/build.mjs";
import { runlight } from "../packages/sdk/src/index.ts";
import { toNodeHandler } from "../packages/sdk/src/node.ts";
import { sqlite } from "../packages/sdk/src/stores/sqlite.ts";
import type { SessionRow } from "../packages/sdk/src/store.ts";

const PORT = Number(process.env.PORT ?? 4800);
const FILE = new URL("../data/dev.db", import.meta.url).pathname;
const DAYS = 120;

if (process.argv.includes("--reseed")) for (const suffix of ["", "-wal", "-shm"]) rmSync(FILE + suffix, { force: true });
const fresh = !existsSync(FILE);
mkdirSync(new URL("../data/", import.meta.url).pathname, { recursive: true });

const rl = runlight({ store: sqlite({ path: FILE }), site: { name: "joncphillips.com", hostnames: ["joncphillips.com"], timezone: "America/Toronto" } });
await rl.init();
if (fresh) await seed();

const routes = toNodeHandler(rl.routes({ token: null }).handler);

createServer(async (req, res) => {
  const path = (req.url ?? "/").split("?")[0]!;
  if (path === "/runlight" || path === "/runlight/") {
    res.setHeader("content-type", "text/html; charset=utf-8");
    res.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Runlight (dev)</title><link rel="stylesheet" href="/runlight/dev.css"></head>
<body><div id="app" data-base="/runlight"></div><script type="module" src="/runlight/dev.js"></script></body></html>`);
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
