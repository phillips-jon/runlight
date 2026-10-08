---
title: Short links
description: Short links on your own domain are counted like visits and can be imported from Umami, Dub, Bitly, Short.io, Rebrandly, or CSV.
group: Features
order: 6
---

Runlight makes short links that redirect to anywhere you like. Each click is counted like a visit (source, country, device, browser, and any UTM tags on the short link) and kept apart from your visitor and pageview numbers. Bots are redirected without being counted.

## Links on your app’s domain

Out of the box, links live under `/go` on your app, as in `example.com/go/sale`. Serve them with one more route, shown here for Next.js.

```ts file=app/go/[slug]/route.ts
import { rl } from "@/lib/runlight";

export const GET = rl.linkHandler();
```

Change the path with `runlight({ linkPath: "/l" })`.

## Making links

**New link** in the Links box takes the destination and either keeps the random slug or uses one you type. **Manage** lists every link so you can search, sort by newest, clicks, or name, and edit, copy, or delete each one. Slugs are unique across all your domains, and thousands of links work fine.

Click a link for its clicks over time and where they came from.

## Custom domains

Links can also live on a domain of their own, like `t.example.com/sale`. Set one up in Settings, Custom domains.

1. Point the domain at your app with a CNAME record for a subdomain, or an A or ALIAS record for a bare domain.
2. Make your host accept the domain and serve HTTPS for it (on Vercel or Netlify, add it to the project’s domains).
3. Add the domain in Settings. Runlight checks that it reaches your app and says so.

A link domain answers every path on it, so it can never be your app's own domain or one of your sites. It must also be a public name, so names kept for private networks, such as `.internal` or `.local`, are refused. Pass `origin` to `routes()` with your app's address, and the first rule holds whatever Host header a request names. A connected hub can add link domains only once `origin` is set, since it cannot know which names your app answers on. Paths under the dashboard, such as `/runlight`, always reach your app, so you can open the dashboard on any of its names to remove a domain.

Requests on that domain have to reach Runlight, which in Next.js happens in middleware (named `proxy.ts` from Next.js 16).

```ts file=proxy.ts
import { rl } from "@/lib/runlight";

export async function proxy(request: Request) {
  return (await rl.linkDomainResponse(request)) ?? undefined;
}
```

`linkDomainResponse` answers only for your link domains and returns `null` for everything else, so the rest of your app is untouched.

Removing a domain keeps its links along with their clicks and stats. They move to `/go/<slug>` until you add the domain back, and then they return to it.

## Importing links

Settings, Import, Short links brings links over from another service, with their click history where the service shares it.

| From | What comes across |
| --- | --- |
| Umami | Every link and every click, with country, device, browser, and referrer. Sign in with an API key, or with your username and password for self-hosted Umami. |
| Dub | Every click on Business plans; clicks per day on Pro; links only on Free. |
| Bitly | Clicks per day, as far back as your plan keeps them. |
| Short.io | Clicks per day. Short.io allows 60 statistics requests a minute, so large accounts take a while. |
| Rebrandly | Links only, because its API gives no dated clicks. |
| Any CSV | Columns `name`, `url`, and optionally `slug` and `domain`. |

Your key or password is sent with each step of the import and never saved. Imports run a few links at a time, so they work on serverless hosts, and they are safe to run again because links already here are skipped. Links on the old service’s own domain (bit.ly, dub.sh, rebrand.ly, short.gy) keep their slug and move to your own link path; links on your branded domains keep the domain, which is added under Custom domains.
