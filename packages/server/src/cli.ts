#!/usr/bin/env node
/**
 * npx runlight.sh starts the server. Settings come from the environment:
 *
 *   PORT              where to listen (3000)
 *   HOST              which address to listen on (0.0.0.0)
 *   DATA_DIR          where the SQLite file and the secret live (./runlight-data)
 *   DATABASE_URL      a postgres:// URL, to use Postgres instead of SQLite
 *   RUNLIGHT_SECRET   signs sessions and encrypts saved keys (made and kept in DATA_DIR if unset)
 *   RUNLIGHT_TOKEN    also accepted as a bearer token on the API
 *   RUNLIGHT_URL      the dashboard's public address, which can never become a link domain
 *   TRUST_PROXY       "false" when no proxy sits in front, so forwarded addresses are ignored
 *   RUNLIGHT_GEO      city (the default), country, off, or the path to an MMDB file
 */
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import path from "node:path";
import type { SqlStore } from "@runlight/sdk";
import { BodyTooLarge, toRequest, writeResponse } from "@runlight/sdk/node";
import { Geo, fileLookup } from "./geo.js";
import { createServer } from "./server.js";
import { VERSION } from "./version.js";

const env = (name: string) => process.env[name]?.trim() || undefined;

const HELP = `Runlight ${VERSION}, privacy friendly web analytics for any number of sites.

Usage:
  npx runlight.sh                      Start the server
  npx runlight.sh password <email>     Make an account, or give one a new password
  npx runlight.sh agents --log <file>  Count AI agents from a web server's access log
  npx runlight.sh --version            Print the version

Settings are environment variables. PORT (3000) and HOST (0.0.0.0) set where it
listens. DATA_DIR (./runlight-data) holds the SQLite file and the secret, and
DATABASE_URL switches to Postgres. RUNLIGHT_SECRET signs sessions and encrypts
saved keys, RUNLIGHT_TOKEN also works as a bearer token on the API, and
TRUST_PROXY=false ignores forwarded addresses when nothing sits in front.
RUNLIGHT_URL is the dashboard's public address, such as
https://stats.example.com, which short links can never take over.
RUNLIGHT_GEO picks where locations come from when no platform header gives
them. It is city by default, which downloads DB-IP's free city database into
DATA_DIR and refreshes it each month. Set it to country for a smaller file, to
off, or to the path of your own MMDB file.

Docs: https://runlight.sh/docs/server/
`;

async function openStore(dataDir: string): Promise<SqlStore> {
  const url = env("DATABASE_URL");
  if (url && /^postgres(ql)?:\/\//.test(url)) {
    const { postgres } = await import("@runlight/sdk/postgres");
    return postgres({ url });
  }
  const { sqlite } = await import("@runlight/sdk/sqlite");
  return sqlite({ path: path.join(dataDir, "runlight.db") });
}

/** RUNLIGHT_SECRET, or one made on first run and kept beside the data, readable only by this user. */
function secretFor(dataDir: string): string {
  const given = env("RUNLIGHT_SECRET");
  if (given) return given;
  const file = path.join(dataDir, "secret");
  if (existsSync(file)) return readFileSync(file, "utf8").trim();
  const made = randomBytes(32).toString("hex");
  writeFileSync(file, `${made}\n`, { mode: 0o600 });
  chmodSync(file, 0o600);
  return made;
}

const AGENTS_HELP = `Count AI agents on a site that has only the script tag, from its web server's log.

Usage:
  npx runlight.sh agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_...

  --log <file>    The access log, in nginx or Apache's combined format, or Caddy's JSON
  --to <url>      Your Runlight, as its dashboard address (or RUNLIGHT_URL)
  --key <key>     The site's key from Settings, Install, Key for CMS plugins (or RUNLIGHT_OBSERVE_KEY)
  --site <url>    The site's address, such as https://example.com, when the log has no host in it
  --follow        Keep running and send fetches as they happen
  --state <file>  Remember where it stopped, so the next run, or a restarted --follow, starts there.
                  Only one run at a time can use it.

Docs: https://runlight.sh/docs/server/#ai-agents-from-a-log
`;

async function agents(args: string[]): Promise<void> {
  const flag = (name: string) => {
    const at = args.indexOf(`--${name}`);
    return at >= 0 ? args[at + 1] : undefined;
  };
  if (args.includes("--help") || args.includes("-h")) return void process.stdout.write(AGENTS_HELP);
  const log = flag("log");
  const to = flag("to") ?? env("RUNLIGHT_URL");
  const key = flag("key") ?? env("RUNLIGHT_OBSERVE_KEY");
  if (!log || !to || !key) {
    process.stderr.write(AGENTS_HELP);
    process.exitCode = 1;
    return;
  }
  const { runAgents } = await import("./agents.js");
  const site = flag("site");
  const state = flag("state");
  await runAgents({ log: path.resolve(log), to, key, follow: args.includes("--follow"), ...(site ? { site } : {}), ...(state ? { state: path.resolve(state) } : {}) });
}

async function main(): Promise<void> {
  const [command, ...args] = process.argv.slice(2);
  if (command === "--help" || command === "-h" || command === "help") return void process.stdout.write(HELP);
  if (command === "--version" || command === "-v") return void process.stdout.write(`${VERSION}\n`);
  if (command === "agents") return agents(args);

  const dataDir = path.resolve(env("DATA_DIR") ?? "./runlight-data");
  mkdirSync(dataDir, { recursive: true });
  const store = await openStore(dataDir);
  const geoSetting = env("RUNLIGHT_GEO") ?? "city";
  const geo = geoSetting === "city" || geoSetting === "country" ? new Geo(path.join(dataDir, "geo"), geoSetting) : null;
  const lookup = geo ? geo.lookup : geoSetting !== "off" ? fileLookup(path.resolve(geoSetting)) : undefined;
  const url = env("RUNLIGHT_URL");
  if (url && !/^https?:\/\/[^/?#]+\/?$/.test(url)) throw new Error("Set RUNLIGHT_URL to the dashboard's address only, such as https://stats.example.com");
  const server = createServer({
    ...(lookup ? { geo: lookup } : {}),
    ...(url ? { url } : {}),
    geoCredit: Boolean(geo),
    store,
    secret: secretFor(dataDir),
    ...(env("RUNLIGHT_TOKEN") ? { token: env("RUNLIGHT_TOKEN") } : {}),
    // "false" with nothing in front, or the one header your proxy sets, such as cf-connecting-ip behind Cloudflare.
    trustProxy: ((value) => (value === "false" ? false : value === "x-forwarded-for" || value === "x-real-ip" || value === "cf-connecting-ip" ? value : true))(env("TRUST_PROXY")?.toLowerCase()),
  });

  if (command === "password") {
    const email = args[0];
    if (!email) throw new Error("Name the account: npx runlight.sh password you@example.com");
    await server.runlight.init();
    const password = randomBytes(12).toString("base64url");
    const existed = Boolean(await server.accounts.byEmail(email));
    const user = await server.accounts.setPassword(email, password, Date.now());
    // Someone at the server is who they say, so a lost authenticator is no longer in the way.
    const reset = user.twoFactor;
    if (reset) await server.accounts.disableTwoFactor(user.id);
    process.stdout.write(
      `${existed ? "New password" : `Account made, as ${user.role === "owner" ? "the owner" : "an admin"},`} for ${email.trim().toLowerCase()}: ${password}\n${reset ? "Two-factor sign-in is now off for this account; turn it on again under Account.\n" : ""}Sign in, and change it by running this again whenever you like.\n`,
    );
    await store.close();
    return;
  }
  if (command && command !== "start") throw new Error(`Unknown command "${command}". Run npx runlight.sh --help.`);

  await server.runlight.init();
  const port = Number(env("PORT") ?? 3000);
  const host = env("HOST") ?? "0.0.0.0";
  const http = createHttpServer(async (req, res) => {
    try {
      const response = await server.handler(await toRequest(req, res), { ip: req.socket.remoteAddress ?? "" });
      await writeResponse(res, response);
    } catch (error) {
      // An upload cut off part way leaves the connection unfit for another request, so it closes.
      if (error instanceof BodyTooLarge) return void (res.headersSent || res.writeHead(413, { "content-type": "application/json", connection: "close" }).end(JSON.stringify({ error: "That request is too large" })));
      console.error("Runlight:", error);
      if (!res.headersSent) res.writeHead(500).end();
    }
  });
  http.listen(port, host, async () => {
    const shown = host === "0.0.0.0" || host === "::" ? "localhost" : host;
    console.log(`Runlight ${VERSION} is listening on http://${shown}:${port}`);
    console.log(`Data: ${env("DATABASE_URL") ? "Postgres" : path.join(dataDir, "runlight.db")}`);
    if ((await server.accounts.count()) === 0) {
      console.log(`\nNo account yet. Open this link to create the first one:\n  http://${shown}:${port}/setup?code=${server.setupCode}\n`);
    }
  });

  // The scheduled check (salts, email reports, retention, and rollups) and this month's location data: now, then every five minutes.
  const tick = () => {
    server.check().catch((error) => console.error("Runlight: the scheduled check failed", error));
    geo?.refresh().catch((error) => console.error("Runlight: could not refresh location data", error));
  };
  void tick();
  const timer = setInterval(tick, 5 * 60_000);
  timer.unref();

  const stop = () => {
    clearInterval(timer);
    http.close(() => void store.close().finally(() => process.exit(0)));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

main().catch((error) => {
  console.error(`Runlight: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
