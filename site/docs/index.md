---
title: Getting started
description: Runlight is web analytics that installs into your app. Five minutes from npm install to your first visit.
group: Start
order: 1
---

Runlight is a library. It runs inside an app you already have, stores what it counts in your database, and serves its dashboard from your own domain at `/runlight`. There is no Runlight account and no server of ours in between.

You need an app that can serve routes: Next.js, Nuxt, SvelteKit, Astro, Remix, Express, NestJS, Fastify, Koa, Hono, or anything that handles a web `Request`, on Node 22 or later, Bun, Deno, or Cloudflare Workers.

## 1. Install

```bash
npm install @runlight/sdk better-sqlite3
```

`better-sqlite3` is the SQLite driver. For Postgres, Turso, Cloudflare D1, or Bun’s own SQLite, see [Configuration](/docs/configuration/#stores).

## 2. Create the instance

One file, imported wherever you need Runlight.

```ts file=lib/runlight.ts
import { runlight } from "@runlight/sdk";
import { sqlite } from "@runlight/sdk/sqlite";

export const rl = runlight({
  store: sqlite({ path: "./data/runlight.db" }),
  site: { name: "example.com", hostnames: ["example.com"], timezone: "Europe/London" },
});
```

The tables are created on first use. The database file is yours: back it up like any other.

## 3. Mount the routes

In Next.js (App Router), one catch-all route serves the tracker, takes the visits, and shows the dashboard:

```ts file=app/runlight/[[...path]]/route.ts
import { rl } from "@/lib/runlight";

export const { GET, POST, PUT, PATCH, DELETE, OPTIONS } = rl.routes();
```

Other frameworks are one or two lines too; see [Install](/docs/install/).

## 4. Add the script

Put this on every page, just before `</head>`:

```html
<script defer src="/runlight/s.js"></script>
```

It is under 2 KB, sets no cookies, and posts to your own domain.

## 5. Sign in

The dashboard is private. Set a long random token in your environment:

```bash
RUNLIGHT_TOKEN=a-long-random-string
```

Then open `/runlight/?token=a-long-random-string` once. Runlight sets a cookie holding a digest of the token (never the token itself) and sends you on to the dashboard. In development, with no token set, the dashboard is open; in production it answers 503 until you set one.

Visit any page of your site and you will see yourself under “here now” within seconds.

## 6. Schedule the hourly check

Runlight rotates its daily salt and sends [email reports](/docs/reports/) from a check you call once an hour. See [Scheduled check](/docs/cron/). On Vercel it is four lines of `vercel.json`.

## Next

- [Tracking](/docs/tracking/): custom events, clicks with no code, single page apps.
- [Goals](/docs/goals/): conversions and revenue.
- [Short links](/docs/links/): links on your own domain, counted like visits.
- [Privacy](/docs/privacy/): exactly what is stored, and what is not.
