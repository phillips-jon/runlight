# Runlight

Runlight is privacy friendly web analytics that you run yourself. It counts visitors without cookies and without storing anyone’s IP address, so there is no consent banner to show. The numbers stay in your own database, and the dashboard is served from your own domain.

Documentation is at [runlight.sh/docs](https://runlight.sh/docs/).

## Two ways to run it

The library, `@runlight/sdk`, runs inside an app you already have. You mount its routes, add one script tag, and read your stats at `/runlight`. It works with Next.js, Nuxt, SvelteKit, Astro, Remix, Express, NestJS, Fastify, Koa, Hono, and anything else that handles a web `Request`, on Node 22 or later, Bun, Deno, or Cloudflare Workers. It stores its data in SQLite, Postgres, MySQL, MariaDB, Turso, or Cloudflare D1.

```bash
npm install @runlight/sdk better-sqlite3
```

The standalone server, `runlight.sh`, is the same code packaged as an app of its own. It suits sites that are not Node apps, and it gives any number of sites one dashboard with sign-in for the people you invite.

```bash
npx runlight.sh
```

It also runs in Docker.

```bash
docker run -d --name runlight -p 3000:3000 -v runlight:/data ghcr.io/phillips-jon/runlight
```

## Plugins

Plugins for WordPress, Drupal, and Craft add the script to a CMS site and report AI agents that read its pages to a Runlight you run elsewhere. Each one has its own folder under `plugins/`.

## What it does

Beyond visitors and pages, Runlight counts goals and the revenue they bring, funnels, and the paths visits take through a site. It makes short links on your own domains and counts their clicks. It emails weekly or monthly reports and shares a read-only dashboard by link. An assistant in the dashboard, or an MCP server for AI apps, answers questions about your numbers.

## This repository

| Folder | What is in it |
| --- | --- |
| `packages/sdk` | The library, published as `@runlight/sdk`. |
| `packages/server` | The standalone server, published as `runlight.sh`. |
| `packages/dashboard` | The dashboard, built into the library. |
| `packages/tracker` | The browser script, built into the library. |
| `plugins` | The WordPress, Drupal, and Craft plugins. |
| `site` | runlight.sh and its documentation. |

Use Node 24 to work on it, and run `npm run check` before committing.

Runlight is MIT licensed.
