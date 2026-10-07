---
title: Configuration
description: Every option for runlight(), its stores, its sites, and its routes.
group: Reference
order: 10
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

Needs `better-sqlite3`. The right choice for a single server; the file can live beside your app’s own database. On a serverless host with no lasting disk, use Postgres.

### Postgres

```ts
import { postgres } from "@runlight/sdk/postgres";

postgres({ url: process.env.DATABASE_URL });
```

Needs `pg`. Options: `url`, or `pool` to share a pool your app already has (Runlight never ends a pool it did not make), and `max` connections when Runlight makes the pool (default 5). Several processes starting at once create the tables once.

### libSQL and Turso

```ts
import { libsql } from "@runlight/sdk/libsql";
import { createClient } from "@libsql/client"; // or "@libsql/client/web" on the edge

libsql({ client: createClient({ url: process.env.TURSO_URL, authToken: process.env.TURSO_TOKEN }) });
```

Needs `@libsql/client`. Turso over HTTP works anywhere `fetch` does, including Vercel Edge and Deno Deploy; a `file:` URL is a local SQLite file.

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

Bun’s built-in SQLite, for apps on Bun, where `better-sqlite3` does not load.

## runlight() options

| Option | Default | What it does |
| --- | --- | --- |
| `store` | (required) | Where the numbers live: `sqlite`, `postgres`, `libsql`, `d1`, or `bunSqlite`. |
| `site` | `{}` | The site this install counts. |
| `sites` | | Several sites in one install, each with its hostnames. Used instead of `site`. |
| `geo` | | Your own location lookup, for hosts that send no location headers. |
| `trustProxy` | `true` | Read the visitor’s address from proxy headers. |
| `linkPath` | `"/go"` | Where short links on your app’s own domain live. |
| `mail` | | The mail service for [email reports](/docs/reports/), set in code. |
| `secret` | `RUNLIGHT_SECRET`, then `RUNLIGHT_TOKEN` | Encrypts mail service keys stored in the database. |

### Sites

| Field | Default | What it does |
| --- | --- | --- |
| `id` | `"default"` for the first site | Stable id stored with every row. Letters, digits, dots, dashes, and underscores. |
| `name` | the first hostname | Shown on the dashboard. Can be changed in Settings. |
| `hostnames` | `[]` (any) | Which hostnames count toward this site. `www.` is ignored. With several sites, each needs at least one. |
| `timezone` | `"UTC"` | IANA timezone for days, weeks, and the hours on the dashboard, such as `"America/Toronto"`. Can be changed in Settings. |

A visit from a hostname no site claims is ignored, so a staging copy of your site does not count unless you add its hostname.

### Location

Country, region, and city come from your host’s headers on Vercel, Cloudflare, and Netlify, with no setup. Elsewhere, pass `geo`, a function from an IP address to a location, for example backed by an MMDB file:

```ts
runlight({
  store,
  geo: async (ip) => {
    const found = reader.get(ip); // your MMDB reader
    return found ? { country: found.country?.iso_code, city: found.city?.names?.en } : null;
  },
});
```

The address is looked up and then dropped; only the place is kept.

## routes() options

| Option | Default | What it does |
| --- | --- | --- |
| `basePath` | `"/runlight"` | Where the routes are mounted. The script is at `{basePath}/s.js`. |
| `token` | `RUNLIGHT_TOKEN` | Protects the dashboard and API. Send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=` to get a cookie. `null` leaves everything open, for example behind your own auth. |
| `authorize` | | Your own check instead of a token: `(request) => boolean`. |
| `cronSecret` | `CRON_SECRET` | Also accepted by the [scheduled check](/docs/cron/). |
| `observeKey` | `RUNLIGHT_OBSERVE_KEY` | Lets a [WordPress](/docs/wordpress/), [Drupal](/docs/drupal/), or [Craft](/docs/craft/) site report AI agent fetches to `POST /api/observe` without the token. It can report fetches and nothing else. |

With no token in production, the dashboard and API answer 503 until you set one. Collecting visits, the script, short links, share links, and unsubscribe links never need the token.

## Environment variables

| Variable | Used for |
| --- | --- |
| `RUNLIGHT_TOKEN` | The dashboard and API token. |
| `RUNLIGHT_SECRET` | Encrypting stored mail service keys (falls back to the token). |
| `CRON_SECRET` | Calling the scheduled check. |
| `RUNLIGHT_OBSERVE_KEY` | CMS plugins reporting AI agent fetches. |
