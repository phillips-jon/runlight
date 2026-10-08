---
title: Getting started
description: Runlight is web analytics that installs into your app. It takes five minutes to get from npm install to your first visit.
group: Start
order: 1
---

Runlight is a library that runs inside an app you already have. It stores what it counts in your database and serves its dashboard from your own domain at `/runlight`, so there is no Runlight account to create and your data never passes through a server of ours.

If your site is not a Node app, or you want one dashboard for several sites, run the [standalone server](/docs/server/) instead.

Runlight needs an app that can serve routes, such as Next.js, Nuxt, SvelteKit, Astro, Remix, Express, NestJS, Fastify, Koa, Hono, or anything else that handles a web `Request`. It runs on Node 22 or later, Bun, Deno, or Cloudflare Workers.

## 1. Install

```bash
npm install @runlight/sdk better-sqlite3
```

`better-sqlite3` is the SQLite driver. For Postgres, Turso, Cloudflare D1, or Bun’s own SQLite, see [Configuration](/docs/configuration/#stores).

## 2. Create the instance

Create one file and import it wherever you need Runlight.

```ts file=lib/runlight.ts
import { runlight } from "@runlight/sdk";
import { sqlite } from "@runlight/sdk/sqlite";

export const rl = runlight({
  store: sqlite({ path: "./data/runlight.db" }),
  site: { name: "example.com", hostnames: ["example.com"], timezone: "Europe/London" },
});
```

The tables are created on first use. The database file is yours, so back it up like any other.

## 3. Mount the routes

In Next.js (App Router), one catch-all route serves the tracker and the dashboard and receives each visit.

```ts file=app/runlight/[[...path]]/route.ts
import { rl } from "@/lib/runlight";

export const { GET, POST, PUT, PATCH, DELETE, OPTIONS } = rl.routes();
```

Other frameworks take one or two lines too, as [Install](/docs/install/) shows.

## 4. Add the script

Put this on every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

The script is under 2 KB gzipped and posts to your own domain without setting any cookies.

## 5. Sign in

The dashboard is private, so set a long random token in your environment.

```bash
RUNLIGHT_TOKEN=a-long-random-string
```

Then open `/runlight/?token=a-long-random-string` once. Runlight sets a cookie holding a digest of the token (never the token itself) and sends you on to the dashboard. With no token set, the dashboard is open only while `NODE_ENV` is `development`, as it is under `next dev`. Everywhere else it answers 503 until you set one.

Visit any page of your site and you will see yourself under “here now” within seconds.

## 6. Schedule the hourly check

A check you call once an hour rotates the daily salt and sends [email reports](/docs/reports/). It also deletes visits a site no longer keeps and adds up finished days, and [Scheduled check](/docs/cron/) shows how to set it up. On Vercel it is four lines of `vercel.json`.

## Next

- [Tracking](/docs/tracking/) covers custom events, single page apps, clicks with no code, and the settings on the script tag.
- [Goals](/docs/goals/) covers conversions and revenue.
- [Short links](/docs/links/) puts links on your own domain and counts them like visits.
- [Privacy](/docs/privacy/) lists exactly what Runlight stores and what it leaves out.
