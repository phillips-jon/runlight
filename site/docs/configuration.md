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

Postgres needs `pg`. Pass `url`, or pass `pool` to share a pool your app already has (Runlight never ends a pool it did not make). A pool needs at least 2 connections. When Runlight makes the pool, `max` sets its connections and defaults to 10, a request waits at most 10 seconds for a free one (a tracker hit tries twice more before it is let go), and `statementTimeout` stops any one query after that many milliseconds, 120000 by default (0 turns it off). If several processes start at once, the tables are still created only once.

### MySQL and MariaDB

```ts
import { mysql } from "@runlight/sdk/mysql";

mysql({ url: process.env.DATABASE_URL });
```

This store needs `mysql2` and works with MySQL 8.4 or later and MariaDB 11.4 or later. Pass a `mysql://` or `mariadb://` URL as `url`, or pass `pool` to share a pool from `mysql2/promise` your app already has (Runlight never ends a pool it did not make). A pool needs at least 2 connections. When Runlight makes the pool, `max` sets its connections and defaults to 10, a request waits at most 10 seconds for a free one (a tracker hit tries twice more before it is let go), and `statementTimeout` stops any one query after that many milliseconds, 120000 by default (0 turns it off). On MySQL that limit covers reads, and on MariaDB it covers every statement. If several processes start at once, the tables are still created only once.

The tables use `utf8mb4` with the `utf8mb4_0900_bin` collation. Text is compared and sorted by code point, with case and trailing spaces kept, so every report reads the same as it would on SQLite or Postgres.

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
| `store` | (required) | Where the numbers live, one of `sqlite`, `postgres`, `mysql`, `libsql`, `d1`, or `bunSqlite`. |
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
| `accounts` | `false` | Sign-in accounts for the dashboard, with invites by role. See [Accounts](#accounts) below. |
| `authorize` | | Your own check, used in place of a token. Return `true` for full access, `"member"` for someone who can change everything apart from the mail service, the assistant’s settings, and deleting a site, `"read"` for someone who may only read, or `false`, from a function or a promise. |
| `cronSecret` | `CRON_SECRET` | A second secret the [scheduled check](/docs/cron/) accepts besides the token. |
| `origin` | | Your app’s public address, such as `https://example.com`. A [link domain](/docs/links/#custom-domains) can never be its host, and links in email reports point to it, whatever Host header a request names. Without it, the request’s own host stands in, and a connected hub cannot add link domains or email reports. |
| `ownHosts` | | A function that returns more names your app answers on, such as `["app.example.com"]`, which can never become link domains either. |
| `signIn` | | Your own sign-in page. An app connecting over OAuth sends a signed-out owner there with `?next=`, and the dashboard links to it when a session ends. |
| `signOut` | | A link to sign out, shown in the dashboard’s footer. |
| `geoCredit` | `false` | Credits [DB-IP](https://db-ip.com) in the dashboard’s footer, as its free location data asks. |
| `observeKey` | `RUNLIGHT_OBSERVE_KEY` | An install-wide key a [WordPress](/docs/wordpress/), [Drupal](/docs/drupal/), or [Craft](/docs/craft/) site can use to report AI agent fetches to `POST /api/observe` for any site. Each site also has its own key in **Settings**, **Install**, which reports only for that site, and is the better choice. |

The options `accountOf` and `tokenMade` connect the routes to the standalone server’s own accounts and are internal to it.

With no token, the dashboard and API answer 503 until you set one, unless `NODE_ENV` is `development`. Collecting visits, the script, short links, share links, and unsubscribe links never need the token.

## Accounts

Turn on accounts to let several people sign in to the dashboard, each with their own email, password, and role, the same way the [standalone server](/docs/server/#make-your-account) does.

```ts
export const { GET, POST, PUT, PATCH, DELETE } = rl.routes({ accounts: true });
```

The dashboard then asks everyone to sign in at `/runlight/login`. To create the first account, open `/runlight/setup` and enter your `RUNLIGHT_TOKEN` along with your email and password, so only whoever runs the app can. That account is the owner. In development with no token, or with `token: null`, which leaves everything open, the first account needs no token, so make it before anyone else can reach the page.

The owner and admins invite more people in **Settings**, **People**, as an admin, a member, or a viewer, and the invite goes out by email when a [mail service](/docs/reports/) is set up. Everyone can turn on two-factor sign-in under **Account**. The token still works as a bearer token for scripts.

Sessions are signed with `RUNLIGHT_SECRET`, or the token when that is not set, so keep it the same across restarts and deploys. Passwords are hashed with scrypt where the runtime has it, as Node, Bun, and Deno do, and with PBKDF2 on edge runtimes such as Cloudflare Workers.

If someone forgets their password, the owner or an admin can remove them and invite them again. If the owner forgets theirs, give the account a new one from a script that uses your Runlight:

```ts
import { Accounts } from "@runlight/sdk";
import { rl } from "./lib/runlight";

const accounts = new Accounts(rl.store, process.env.RUNLIGHT_SECRET ?? process.env.RUNLIGHT_TOKEN!);
const user = await accounts.setPassword("you@example.com", "a new long password", Date.now());
await accounts.disableTwoFactor(user.id);
```

## Environment variables

| Variable | Used for |
| --- | --- |
| `RUNLIGHT_TOKEN` | The dashboard and API token. |
| `RUNLIGHT_SECRET` | Encrypting stored keys for mail, the AI Assistant, and connected installs (falls back to the token). |
| `CRON_SECRET` | Calling the scheduled check. |
| `RUNLIGHT_OBSERVE_KEY` | CMS plugins reporting AI agent fetches. |
