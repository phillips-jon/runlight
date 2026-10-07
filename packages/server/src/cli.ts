#!/usr/bin/env node
/**
 * npx runlight.sh starts the server. Settings come from the environment:
 *
 *   PORT              where to listen (3000)
 *   HOST              which address to listen on (0.0.0.0)
 *   DATA_DIR          where the SQLite file and the secret live (./runlight-data)
 *   DATABASE_URL      a postgres:// URL, to use Postgres instead of SQLite
 *   RUNLIGHT_SECRET   signs sessions and encrypts mail keys (made and kept in DATA_DIR if unset)
 *   RUNLIGHT_TOKEN    also accepted as a bearer token on the API
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
  npx runlight.sh --version            Print the version

Settings are environment variables. PORT (3000) and HOST (0.0.0.0) set where it
listens. DATA_DIR (./runlight-data) holds the SQLite file and the secret, and
DATABASE_URL switches to Postgres. RUNLIGHT_SECRET signs sessions and encrypts
mail keys, RUNLIGHT_TOKEN also works as a bearer token on the API, and
TRUST_PROXY=false ignores forwarded addresses when nothing sits in front.
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

async function main(): Promise<void> {
  const [command, ...args] = process.argv.slice(2);
  if (command === "--help" || command === "-h" || command === "help") return void process.stdout.write(HELP);
  if (command === "--version" || command === "-v") return void process.stdout.write(`${VERSION}\n`);

  const dataDir = path.resolve(env("DATA_DIR") ?? "./runlight-data");
  mkdirSync(dataDir, { recursive: true });
  const store = await openStore(dataDir);
  const geoSetting = env("RUNLIGHT_GEO") ?? "city";
  const geo = geoSetting === "city" || geoSetting === "country" ? new Geo(path.join(dataDir, "geo"), geoSetting) : null;
  const lookup = geo ? geo.lookup : geoSetting !== "off" ? fileLookup(path.resolve(geoSetting)) : undefined;
  const server = createServer({
    ...(lookup ? { geo: lookup } : {}),
    geoCredit: Boolean(geo),
    store,
    secret: secretFor(dataDir),
    ...(env("RUNLIGHT_TOKEN") ? { token: env("RUNLIGHT_TOKEN") } : {}),
    trustProxy: env("TRUST_PROXY") !== "false",
  });

  if (command === "password") {
    const email = args[0];
    if (!email) throw new Error("Name the account: npx runlight.sh password you@example.com");
    await server.runlight.init();
    const password = randomBytes(12).toString("base64url");
    const existed = Boolean(await server.accounts.byEmail(email));
    await server.accounts.setPassword(email, password, Date.now());
    process.stdout.write(`${existed ? "New password" : "Account made"} for ${email.trim().toLowerCase()}: ${password}\nSign in, and change it by running this again whenever you like.\n`);
    await store.close();
    return;
  }
  if (command && command !== "start") throw new Error(`Unknown command "${command}". Run npx runlight.sh --help.`);

  await server.runlight.init();
  const port = Number(env("PORT") ?? 3000);
  const host = env("HOST") ?? "0.0.0.0";
  const http = createHttpServer(async (req, res) => {
    try {
      const response = await server.handler(await toRequest(req), { ip: req.socket.remoteAddress ?? "" });
      await writeResponse(res, response);
    } catch (error) {
      if (error instanceof BodyTooLarge) return void (res.headersSent || res.writeHead(413, { "content-type": "application/json" }).end(JSON.stringify({ error: "That request is too large" })));
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

  // Salts, email reports, and this month's location data: now, then every five minutes.
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
