---
title: Install
description: Mount Runlight in Next.js, Nuxt, SvelteKit, Astro, Remix, Express, NestJS, Fastify, Koa, Hono, Bun, Deno, or Cloudflare Workers, or find the guide for your language.
group: Start
order: 2
---

Every install needs an instance (see [Getting started](/docs/#2-create-the-instance)), its routes mounted under `/runlight`, and the script tag on your pages. Only the routes change between frameworks.

`rl.routes()` returns a Fetch handler, `handler(request)`, plus the same function under each method name, so any framework built on web `Request` and `Response` can use it directly. Change the path with `rl.routes({ basePath: "/stats" })`, and the script tag becomes `/stats/s.js`.

## Next.js

In the App Router, add a catch-all route.

```ts file=app/runlight/[[...path]]/route.ts
import { rl } from "@/lib/runlight";

export const { GET, POST, PUT, PATCH, DELETE, OPTIONS } = rl.routes();
```

Add the script to your root layout.

```tsx file=app/layout.tsx
<head>
  <script defer src="/runlight/s.js"></script>
</head>
```

Runlight needs the Node runtime (it uses SQLite, Postgres, or MySQL), which is the default for route handlers.

## Express and plain Node

`@runlight/sdk/node` adapts the handler to Node’s `http` module, and so to Express, Connect, and Koa (through `ctx.req` and `ctx.res`).

```ts file=server.ts
import express from "express";
import { toNodeHandler, observer, shortLinks } from "@runlight/sdk/node";
import { rl } from "./runlight.js";

const app = express();
app.use(shortLinks(rl)); // short links at /go and on custom domains
app.use(observer(rl)); // AI agents reading your pages; optional
app.use(toNodeHandler(rl.routes().handler));
```

It can go before or after any body parser, because the adapter also reads a body that Express has already parsed, and it leaves the bodies of your app’s own requests unread. `shortLinks` goes before your own routes, so a [link domain](/docs/links/#custom-domains) reaches Runlight first.

## NestJS

Nest runs on Express by default, so the same middleware goes in `main.ts`, before `listen`.

```ts file=src/main.ts
import { NestFactory } from "@nestjs/core";
import { toNodeHandler } from "@runlight/sdk/node";
import { AppModule } from "./app.module";
import { rl } from "./runlight";

const app = await NestFactory.create(AppModule);
app.use(toNodeHandler(rl.routes().handler));
await app.listen(3000);
```

Add `app.use(shortLinks(rl))` before it for [short links](/docs/links/#custom-domains).

## Fastify

Fastify reads request bodies itself, so give Runlight its own plugin scope with no body parsers, and hand it the raw request.

```ts
import Fastify from "fastify";
import { toNodeHandler } from "@runlight/sdk/node";
import { rl } from "./runlight.js";

const app = Fastify();
const runlight = toNodeHandler(rl.routes().handler);

app.register(async (scope) => {
  scope.removeAllContentTypeParsers();
  scope.addContentTypeParser("*", (_req, _payload, done) => done(null));
  scope.all("/runlight", (req, reply) => { reply.hijack(); return runlight(req.raw, reply.raw); });
  scope.all("/runlight/*", (req, reply) => { reply.hijack(); return runlight(req.raw, reply.raw); });
});
```

Short links go in an `onRequest` hook, as [Short links](/docs/links/#fastify) shows.

## Koa

```ts
import Koa from "koa";
import { toNodeHandler } from "@runlight/sdk/node";
import { rl } from "./runlight.js";

const app = new Koa();
const runlight = toNodeHandler(rl.routes().handler);

app.use(async (ctx, next) => {
  if (ctx.path !== "/runlight" && !ctx.path.startsWith("/runlight/")) return next();
  ctx.respond = false;
  await runlight(ctx.req, ctx.res);
});
```

For short links, add the middleware under [Short links](/docs/links/#koa) before this one.

## Hono

```ts
import { Hono } from "hono";
import { rl } from "./runlight";

const app = new Hono();
const runlight = rl.routes().handler;
app.all("/runlight/*", (c) => runlight(c.req.raw));
app.all("/runlight", (c) => runlight(c.req.raw));
```

## Nuxt and Nitro

Put the instance in `server/utils/runlight.ts` (Nitro imports everything there for you), then add this route.

```ts file=server/routes/runlight/[...path].ts
export default defineEventHandler((event) => rl.routes().handler(toWebRequest(event)));
```

Add the same file as `server/routes/runlight.ts` so `/runlight` itself answers too. The script tag goes in `app.head` in `nuxt.config.ts`.

```ts file=nuxt.config.ts
export default defineNuxtConfig({
  app: { head: { script: [{ src: "/runlight/s.js", defer: true }] } },
});
```

## SvelteKit

```ts file=src/routes/runlight/[...path]/+server.ts
import { rl } from "$lib/runlight";

const { handler } = rl.routes();
export const GET = ({ request }) => handler(request);
export const POST = GET;
export const PUT = GET;
export const PATCH = GET;
export const DELETE = GET;
export const OPTIONS = GET;
```

## Astro

Astro needs an adapter for server output.

```ts file=src/pages/runlight/[...path].ts
import { rl } from "../../lib/runlight";

export const prerender = false;
export const ALL = ({ request }) => rl.routes().handler(request);
```

## Remix and React Router

```ts file=app/routes/runlight.$.ts
import { rl } from "~/runlight.server";

const { handler } = rl.routes();
export const loader = ({ request }) => handler(request);
export const action = ({ request }) => handler(request);
```

## Bun

Bun cannot load `better-sqlite3`, so use its built-in SQLite through `@runlight/sdk/bun`.

```ts file=server.ts
import { runlight } from "@runlight/sdk";
import { bunSqlite } from "@runlight/sdk/bun";

const rl = runlight({ store: bunSqlite({ path: "./data/runlight.db" }), site: { hostnames: ["example.com"] } });
const runlightRoutes = rl.routes().handler;

Bun.serve({
  port: 3000,
  fetch(request) {
    const { pathname } = new URL(request.url);
    if (pathname === "/runlight" || pathname.startsWith("/runlight/")) return runlightRoutes(request);
    return new Response("Your app");
  },
});
```

Elysia and other Bun frameworks pass `request` the same way.

## Deno

Deno serves web Requests directly. Use [libSQL](/docs/configuration/#libsql-and-turso) (a local file or Turso) or Postgres for the store.

```ts file=main.ts
import { runlight } from "npm:@runlight/sdk";
import { libsql } from "npm:@runlight/sdk/libsql";
import { createClient } from "npm:@libsql/client";

const rl = runlight({ store: libsql({ client: createClient({ url: "file:runlight.db" }) }), site: { hostnames: ["example.com"] } });
const runlightRoutes = rl.routes().handler;

Deno.serve((request) => {
  const { pathname } = new URL(request.url);
  if (pathname === "/runlight" || pathname.startsWith("/runlight/")) return runlightRoutes(request);
  return new Response("Your app");
});
```

## Cloudflare Workers

Workers have no disk, so keep the numbers in [D1](/docs/configuration/#cloudflare-d1). Location comes from Cloudflare’s own headers with no setup.

```ts file=src/index.ts
import { runlight } from "@runlight/sdk";
import { d1 } from "@runlight/sdk/d1";

let routes: ReturnType<ReturnType<typeof runlight>["routes"]> | undefined;

export default {
  fetch(request: Request, env: { DB: D1Database; RUNLIGHT_TOKEN: string }) {
    // Made once per Worker instance, so the tables are checked when the instance starts.
    routes ??= runlight({ store: d1({ database: env.DB }), site: { hostnames: ["example.com"] } }).routes({ token: env.RUNLIGHT_TOKEN });
    return routes.handler(request);
  },
};
```

A Worker keeps its secrets in `env`, which Runlight cannot read by itself, so pass the token to `routes()` as above. Set it with `wrangler secret put RUNLIGHT_TOKEN`.

Route only `/runlight/*` to this Worker (or check the path first, as in the Bun example), and schedule the [hourly check](/docs/cron/) with a Cron Trigger that calls `rl.check()`.

## Anything else

If your server gives you a web `Request`, pass it to `rl.routes().handler` and return the `Response`. If it gives you Node’s `req` and `res`, use `toNodeHandler` from `@runlight/sdk/node`.

## Other languages

Runlight is written again for each of these languages, with the same dashboard and the same tables. Each page has the install, the routes for its frameworks, the scheduled check, and what differs from the TypeScript library.

| Language | Install | Runs in |
| --- | --- | --- |
| [PHP](/docs/php/) | `composer require runlight/runlight` | Laravel, Symfony, plain PHP, and a drop-in for a domain of its own |
| [Python](/docs/python/) | `pip install runlight` | Django, Flask, FastAPI, and any WSGI or ASGI app |
| [Rails](/docs/rails/) | `bundle add runlight` | Rails 7.2, 8.0, and 8.1, through an engine and a generator |
| [Ruby](/docs/ruby/) | `bundle add runlight sqlite3` | Sinatra, Hanami, Roda, and any other Rack app |
| [Go](/docs/go/) | `go get runlight.sh/go` | net/http, chi, Echo, and any router that takes an `http.Handler` |
| [Java](/docs/java/) | `sh.runlight:runlight` from Maven Central | The JDK’s own server, servlet containers, and Spring Boot |
| [.NET](/docs/dotnet/) | `dotnet add package Runlight.AspNetCore` | ASP.NET Core and any other .NET app |
| [Elixir](/docs/elixir/) | `{:runlight, "~> 0.0"}` in `mix.exs` | Phoenix and any Plug app |
| [Rust](/docs/rust/) | `cargo add runlight runlight-sqlx` | axum, hyper, and any server that takes a tower service |

Every language except Elixir and Rust also has a standalone server of its own, and the [standalone server](/docs/server/) page covers the Node one.

## Behind a proxy

Runlight reads the visitor’s address from the last entry in `X-Forwarded-For`, the one your proxy adds, then from `X-Real-IP` or `CF-Connecting-IP`. That is right behind Vercel, Netlify, Cloudflare, and most load balancers. When a request passes through two proxies, such as Cloudflare in front of nginx, name the header that holds the visitor’s own address, like `trustProxy: "cf-connecting-ip"`. The address is used for the [daily visitor hash](/docs/privacy/) and the location lookup, and the rate limit counts it hashed. It is never stored. If your app is exposed directly with no proxy, set `trustProxy: false`.
