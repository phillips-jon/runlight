# @runlight/sdk

Runlight is privacy friendly web analytics that runs inside your own app. It counts visitors without cookies and without storing anyone’s IP address. The numbers stay in your database, and the dashboard is served from your domain at `/runlight`.

It works with Next.js, Nuxt, SvelteKit, Astro, Remix, Express, NestJS, Fastify, Koa, Hono, and anything else that handles a web `Request`, on Node 22 or later, Bun, Deno, or Cloudflare Workers.

## Get started

Install the library with a database driver. This one uses SQLite.

```bash
npm install @runlight/sdk better-sqlite3
```

Create one instance for your app.

```ts
import { runlight } from "@runlight/sdk";
import { sqlite } from "@runlight/sdk/sqlite";

export const rl = runlight({
  store: sqlite({ path: "./data/runlight.db" }),
  site: { name: "example.com", hostnames: ["example.com"], timezone: "Europe/London" },
});
```

Mount its routes. In the Next.js App Router that is one catch-all route at `app/runlight/[[...path]]/route.ts`.

```ts
import { rl } from "@/lib/runlight";

export const { GET, POST, PUT, PATCH, DELETE, OPTIONS } = rl.routes();
```

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in.

The [documentation](https://runlight.sh/docs/) covers every framework and every database, Postgres, Turso, and Cloudflare D1 among them. It also covers goals, short links, email reports, and the API.

## License

Runlight is MIT licensed.
