---
title: HTTP API
description: Everything the dashboard shows is JSON at /runlight/api, for your own scripts and tools.
group: Reference
order: 12
---

The dashboard is built on this API, so anything it shows you can fetch yourself. Send a token as a bearer.

```bash
curl https://example.com/runlight/api/stats?period=30d -H "Authorization: Bearer $RUNLIGHT_TOKEN"
```

For scripts, make a read-only token in **Settings**, **API and AI**, and keep `RUNLIGHT_TOKEN` to yourself. A read-only token can read every report below, short links and each one's clicks included. You can limit it to one site, and it stops working the moment you delete it. Endpoints that change something, along with the token, share, and mail endpoints, need `RUNLIGHT_TOKEN` itself (or your `authorize` check). The same tokens connect AI assistants, as [Ask your AI](/docs/mcp/) explains.

A `manage` token belongs to a [standalone server](/docs/server/#connect-sites-that-count-themselves) that shows this site. It reads like a read-only token and can also change one site's goals, funnels, short links, link domains, email reports, and share links, along with its name, timezone, and retention. It can never touch other sites, people, tokens, imports, or the mail service, and it cannot change where the site lives. It sees which mail service sends reports and from which address, and the service's keys and account details stay hidden from it. The standalone server gets one through OAuth when you connect the site, so you rarely make one by hand.

Requests that change something must send `content-type: application/json`.

## Reading reports

Every report takes the same query parameters.

| Parameter | Values |
| --- | --- |
| `site` | The site id, defaulting to the first site. |
| `period` | `today`, `yesterday`, `7d`, `30d`, `90d`, `month`, `last_month`, `year`, `12mo`, or `all`. |
| `from`, `to` | Dates as `YYYY-MM-DD`, both inclusive, instead of a period. |
| `compare` | `previous` (the default), `year`, `custom`, or `off`. |
| `compare_from`, `compare_to` | The dates to compare with, for `compare=custom`. |
| `filter` | `dimension:op:value`, where op is `is`, `not`, or `contains`. Repeat it to apply up to six. |
| `interval` | `hour`, `day`, `week`, or `month` for series, chosen from the range by default. |

| Endpoint | Returns |
| --- | --- |
| `GET /api` | The name, version, and API version of the install, with no token needed. |
| `GET /api/sites` | Every site, with when it last had a visit. |
| `GET /api/stats` | Visitors, visits, pageviews, views per visit, bounce rate, and visit duration, with the comparison period’s. |
| `GET /api/series` | The same numbers for each hour, day, week, or month of the range. |
| `GET /api/breakdown?dimension=` | Rows for one dimension, with `limit` (up to 1000) and `page`. |
| `GET /api/rhythm` | Visits by weekday and hour. |
| `GET /api/realtime` | People on the site in the last 5 minutes, pages, sources, countries, pageviews per minute, and recent activity. |
| `GET /api/goals` | Every goal with its conversions, converted visitors, rate, and revenue. |
| `GET /api/goals/:id` | One goal with a series and its conversions by channel, source, and page. |
| `GET /api/funnels` | Every funnel with how many visits reached each step, in order, within one visit. |
| `GET /api/event-props?event=` | The property names sent with an event, and the values of one of them, chosen with `key` (the first by default) and `limit` (up to 1000). |
| `GET /api/export` | A ZIP of CSV files for the view, with the numbers, the series, and every breakdown, taking the same parameters as the reports. |
| `GET /api/journeys` | The paths visits take: the top pages at each step, the flows between steps, and the commonest paths. It takes `steps` (2 to 8), `start` and `end` pages, and `through` as `step:page` to follow one page. |
| `GET /api/links` | Short links with their clicks. |
| `GET /api/links/:id` | One link’s clicks over time, sources, countries, devices, and browsers. |
| `GET /api/icon` | The site’s icon as an image, fetched from the site’s own domain, or a 404 when it has none. Share links can read it too. |

`breakdown` and `filter` accept the dimensions `page`, `entry`, `exit`, `hostname`, `event`, `referrer`, `source`, `channel`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `country`, `region`, `city`, `browser`, `browser_version`, `os`, `os_version`, `device`, `screen`, and `language`. `breakdown` also takes `ai_agent` and `ai_page`.

## Changing things

| Endpoint | Does |
| --- | --- |
| `PATCH /api/sites/:id` | Change a site’s `name`, `timezone`, or `retentionMonths` (6, 12, 24, 36, or 60, or `null` to keep everything). On the standalone server, `hostnames` too. |
| `POST /api/sites` | Add a site, when sites are managed in the dashboard as on the standalone server, from `{ "name", "hostnames", "timezone" }`. To connect another install instead, send `{ "remote": { "url", "token" } }`. |
| `DELETE /api/sites/:id` | Delete a managed site and everything recorded for it, or disconnect a connected one. |
| `POST /api/sites/connect` | Start connecting another install through its consent page, from `{ "url" }`. It answers with `authorize`, the address to send the owner to. Add `site` with the install's id for a site to offer that one first. |
| `GET /api/sites/connect/done` | Where the consent page sends the owner back. It finishes connecting and opens the dashboard on the site. |
| `POST /api/goals`, `PATCH /api/goals/:id`, `DELETE /api/goals/:id` | Add, change, or remove a goal. |
| `POST /api/pick` | Makes a ticket for the element picker from `{ "origin" }`, the dashboard's own origin, which the picker sends its choice to and nowhere else. A ticket works for half an hour. |
| `POST /api/funnels`, `PATCH /api/funnels/:id`, `DELETE /api/funnels/:id` | Add, change, or remove a funnel, sent as `{ "name", "steps" }` with two to eight steps of `{ "kind", "match" }`, where kind is `page` or `event`. |
| `POST /api/links`, `PATCH /api/links/:id`, `DELETE /api/links/:id` | Add, change, or remove a short link. |
| `POST /api/links/import` | Add many short links at once from `{ "rows" }`, up to 5,000 objects with `url` and, if you like, `slug`, `name`, and `domain`. It answers with how many it made and which rows failed. |
| `POST /api/links/import/:source` | One step of an import from `umami`, `dub`, `bitly`, `shortio`, or `rebrandly`, sent as `{ "credentials", "cursor", "done" }`. Send the `cursor` it answers with until it comes back `null`. Credentials are used and never kept. |
| `POST /api/import/umami/websites` | List the websites in an Umami account, from `{ "credentials" }`. |
| `POST /api/import/umami/visits` | One step of bringing an Umami website’s visit history in, from `{ "credentials", "website", "cursor" }`, repeated until `cursor` is `null`. |
| `GET`, `POST /api/link-domains`, `DELETE /api/link-domains/:domain` | List, add, or remove custom link domains. A link domain must be a public name, and never the dashboard’s own or a site’s. |
| `GET /api/link-domains/:domain/check` | Whether requests to a link domain reach Runlight, as `{ "domain", "working", "reason" }`, where `reason` says what answered instead. |
| `GET`, `POST /api/shares`, `PATCH`, `DELETE /api/shares/:id` | List, add, rename, or remove share links. |
| `GET`, `PUT`, `DELETE /api/mail`, `POST /api/mail/test` | Read, set, remove, or test the mail service. Keys are never returned. |
| `GET`, `POST /api/reports`, `DELETE /api/reports/:id`, `POST /api/reports/:id/send` | List, add, or remove report recipients, or send a sample. |
| `GET` or `POST /api/check` | Runs the [scheduled check](/docs/cron/). |
| `POST /api/observe` | Records a page served to an AI agent, sent as `{ "url", "userAgent", "at" }`, where `at` is when it was served (within the last week, as epoch milliseconds or an ISO date) and can be left out. Send up to 500 at once as `{ "fetches": [...] }`. It accepts the token or an observe key, and the CMS plugins and the [log reader](/docs/server/#ai-agents-from-a-log) call it. |
| `GET /api/tokens` | Lists API tokens with each one's name, site, scope, last four characters, and when it was last used. The tokens themselves are never returned. |
| `POST /api/tokens` | Makes a token from `{ "name", "site", "scope" }` and returns it once as `secret`. Leave `site` empty for every site. `scope` is `read` (the default) or `manage`, which needs a `site`. |
| `GET /api/observe-key`, `POST /api/observe-key/new` | Read a site's key for CMS plugins, made the first time it is asked for, or replace it with a new one, which stops the old one at once. |
| `GET /api/token` | Says what the token sent with it may do, as `{ "scope", "site" }`. A hub asks this before it offers to change anything. |
| `DELETE /api/token` | Deletes the token sent with it. A hub does this when it disconnects a site or is given a new token. |
| `DELETE /api/tokens/:id` | Deletes a token, which stops it working at once. |
| `GET`, `PUT`, `DELETE /api/assistant` | Read, set, or remove the dashboard assistant's `{ "provider", "model", "baseUrl", "key" }`. The key is never returned. Owners only, though anyone at the dashboard can ask whether it is set up. |
| `POST /api/assistant/models` | The models a provider offers, from `{ "provider", "baseUrl", "key" }`, for the settings form. Leave `key` out to use the saved one, which works only for the same provider and address. Owners only. |
| `POST /api/assistant/chat` | Ask the assistant, sending `{ "site", "messages", "view", "language" }`, where messages are `{ "role", "content" }` pairs ending with a question. It answers `{ "reply", "tools" }`. People at the dashboard only, never API tokens or share links. |
| `POST /mcp` | The MCP server for AI assistants, described in [Ask your AI](/docs/mcp/). |

## Errors

Errors are JSON, `{ "error": "..." }`, in plain words, with 400 for something wrong in the request, 401 without the token, 403 when someone signed in as a viewer tries to change something, 404 for something that is not there, and 503 when no token is set in production.

Some errors also carry a `code`, such as `link_taken` or `report_exists`, and `params` to fill it, such as `{ "slug": "launch" }`. The dashboard uses them to show the message in its own language. The English `error` is always there too.
