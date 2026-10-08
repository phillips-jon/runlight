---
title: Configuration
description: This page covers every option for runlight() and routes(), including stores and sites.
group: Reference
order: 11
---

```ts
import { runlight } from "@runlight/sdk";

export const rl = runlight({ store, site, /* ...options */ });
export const routes = rl.routes({ /* ...route options */ });
```

## Stores

Runlight keeps everything in a handful of tables prefixed `rl_`, created on first use and upgraded in place.

### SQLite

```ts
import { sqlite } from "@runlight/sdk/sqlite";

sqlite({ path: "./data/runlight.db" });
```

SQLite needs `better-sqlite3` and suits a single server, where the file can live beside your app’s own database. On a serverless host with no lasting disk, use Postgres.

### Postgres

```ts
import { postgres } from "@runlight/sdk/postgres";

postgres({ url: process.env.DATABASE_URL });
```

Postgres needs `pg`. Pass `url`, or pass `pool` to share a pool your app already has (Runlight never ends a pool it did not make). When Runlight makes the pool, `max` sets its connections and defaults to 5. If several processes start at once, the tables are still created only once.

### libSQL and Turso

```ts
import { libsql } from "@runlight/sdk/libsql";
import { createClient } from "@libsql/client"; // or "@libsql/client/web" on the edge

libsql({ client: createClient({ url: process.env.TURSO_URL, authToken: process.env.TURSO_TOKEN }) });
```

This store needs `@libsql/client`. Turso over HTTP works anywhere `fetch` does, including Vercel Edge and Deno Deploy, and a `file:` URL points to a local SQLite file.

### Cloudflare D1

```ts
import { d1 } from "@runlight/sdk/d1";

d1({ database: env.DB });
```

Pass the D1 binding from your Worker’s environment. D1 has no interactive transactions, so a link import writes each link on its own; if one fails part way, running the import again skips the links already written.

### Bun

```ts
import { bunSqlite } from "@runlight/sdk/bun";

bunSqlite({ path: "./data/runlight.db" });
```

This store uses Bun’s built-in SQLite, for apps on Bun, where `better-sqlite3` does not load.

## runlight() options

| Option | Default | What it does |
| --- | --- | --- |
| `store` | (required) | Where the numbers live, one of `sqlite`, `postgres`, `libsql`, `d1`, or `bunSqlite`. |
| `site` | `{}` | The site this install counts. |
| `sites` | | Several sites in one install, each with its hostnames, used in place of `site`. |
| `geo` | | Your own location lookup, for hosts that send no location headers. |
| `trustProxy` | `true` | Read the visitor’s address from proxy headers. |
| `linkPath` | `"/go"` | Where short links on your app’s own domain live. |
| `rateLimit` | `120` | Tracker requests allowed from one address each minute, or `false` or `0` for no limit. |
| `mail` | | The mail service for [email reports](/docs/reports/), set in code. |
| `managedSites` | `false` | Keep sites in the database and manage them from the dashboard, as the [standalone server](/docs/server/) does, in place of `site` and `sites`. |
| `secret` | `RUNLIGHT_SECRET`, then `RUNLIGHT_TOKEN` | Encrypts the keys stored in the database, for the mail service, the AI Assistant, and connected installs. |

### Sites

| Field | Default | What it does |
| --- | --- | --- |
| `id` | `"default"` for the first site | Stable id stored with every row, made of letters, digits, dots, dashes, and underscores. |
| `name` | the first hostname | Shown on the dashboard and editable in Settings. |
| `hostnames` | `[]` (any) | Which hostnames count toward this site, ignoring `www.`. With several sites, each site needs at least one. |
| `timezone` | `"UTC"` | IANA timezone for days, weeks, and the hours on the dashboard, such as `"America/Toronto"`, and editable in Settings. |

A visit from a hostname no site claims is ignored, so a staging copy of your site does not count unless you add its hostname.

### Rate limit

Each process counts tracker requests per visitor address over one minute and drops the rest quietly, so a script cannot flood a site with made-up visits. A real visitor sends a few requests a minute, far below the default of 120. The count lives in memory under a hashed address and is cleared every minute, so no address is ever kept. On hosts that run many short-lived copies of your app, such as Cloudflare Workers, each copy counts on its own, so the limit there is looser.

### Location

Country, region, and city come from your host’s headers on Vercel, Cloudflare, and Netlify, with no setup. Elsewhere, pass `geo`, a function that turns an IP address into a location. This example backs it with an MMDB file.

```ts
runlight({
  store,
  geo: async (ip) => {
    const found = reader.get(ip); // your MMDB reader
    return found ? { country: found.country?.iso_code, city: found.city?.names?.en } : null;
  },
});
```

The address is dropped after the lookup, so only the place is kept.

## routes() options

| Option | Default | What it does |
| --- | --- | --- |
| `basePath` | `"/runlight"` | Where the routes are mounted, with the script at `{basePath}/s.js`. |
| `token` | `RUNLIGHT_TOKEN` | Protects the dashboard and API. Send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=` to get a cookie. `null` leaves everything open, for example behind your own auth. |
| `authorize` | | Your own check, used in place of a token. Return `true` for full access, `"read"` for someone who may only read, or `false`, from a function or a promise. |
| `cronSecret` | `CRON_SECRET` | A second secret the [scheduled check](/docs/cron/) accepts besides the token. |
| `origin` | | Your app's public address, such as `https://example.com`. A [link domain](/docs/links/#custom-domains) can never be its host, and links in email reports point to it, whatever Host header a request names. Without it, the request's own host stands in. |
| `observeKey` | `RUNLIGHT_OBSERVE_KEY` | An install-wide key a [WordPress](/docs/wordpress/), [Drupal](/docs/drupal/), or [Craft](/docs/craft/) site can use to report AI agent fetches to `POST /api/observe` for any site. Each site also has its own key in **Settings**, **Install**, which reports only for that site, and is the better choice. |

With no token, the dashboard and API answer 503 until you set one, unless `NODE_ENV` is `development`. Collecting visits, the script, short links, share links, and unsubscribe links never need the token.

## Environment variables

| Variable | Used for |
| --- | --- |
| `RUNLIGHT_TOKEN` | The dashboard and API token. |
| `RUNLIGHT_SECRET` | Encrypting stored keys for mail, the AI Assistant, and connected installs (falls back to the token). |
| `CRON_SECRET` | Calling the scheduled check. |
| `RUNLIGHT_OBSERVE_KEY` | CMS plugins reporting AI agent fetches. |
