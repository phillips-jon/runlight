---
title: Install
description: Mount Runlight in Next.js, Express, Hono, SvelteKit, Astro, Remix, or any server that speaks Request and Response.
group: Start
order: 2
---

Every install has the same three parts: an instance (see [Getting started](/docs/#2-create-the-instance)), its routes mounted under `/runlight`, and the script tag on your pages. Only the middle part changes between frameworks.

`rl.routes()` returns a Fetch handler, `handler(request)`, plus the same function under each method name, so any framework built on web `Request` and `Response` can use it directly. Change the path with `rl.routes({ basePath: "/stats" })`, and the script tag becomes `/stats/s.js`.

## Next.js

App Router, with a catch-all route:

```ts file=app/runlight/[[...path]]/route.ts
import { rl } from "@/lib/runlight";

export const { GET, POST, PUT, PATCH, DELETE, OPTIONS } = rl.routes();
```

Add the script to your root layout:

```tsx file=app/layout.tsx
<head>
  <script defer src="/runlight/s.js"></script>
</head>
```

Runlight needs the Node runtime (it uses SQLite or Postgres), which is the default for route handlers.

## Express and plain Node

`@runlight/sdk/node` adapts the handler to Node's `http` module, and so to Express, Connect, and Koa (through `ctx.req` and `ctx.res`):

```ts file=server.ts
import express from "express";
import { toNodeHandler, observer } from "@runlight/sdk/node";
import { rl } from "./runlight.js";

const app = express();
app.use(observer(rl)); // AI agents reading your pages; optional
app.use(toNodeHandler(rl.routes().handler));
```

Mount it before any body parser that would consume the request, or after: the adapter reads a body Express has already parsed.

## Hono

```ts
import { Hono } from "hono";
import { rl } from "./runlight";

const app = new Hono();
const runlight = rl.routes().handler;
app.all("/runlight/*", (c) => runlight(c.req.raw));
app.all("/runlight", (c) => runlight(c.req.raw));
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

With an adapter for server output:

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

## Anything else

If your server gives you a web `Request`, pass it to `rl.routes().handler` and return the `Response`. If it gives you Node's `req` and `res`, use `toNodeHandler` from `@runlight/sdk/node`.

## Behind a proxy

Runlight reads the visitor's address from `CF-Connecting-IP`, `X-Real-IP`, then the first `X-Forwarded-For`, which is right behind Vercel, Cloudflare, Netlify, and most load balancers. The address is only used for the [daily visitor hash](/docs/privacy/) and is never stored. If your app is exposed directly with no proxy, set `trustProxy: false`.
