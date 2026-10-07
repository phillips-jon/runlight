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

For scripts, make a read-only token in **Settings**, **API and AI**, and keep `RUNLIGHT_TOKEN` to yourself. A read-only token can read every report below and list short links. You can limit it to one site, and it stops working the moment you delete it. Endpoints that change something, along with the token, share, and mail endpoints, need `RUNLIGHT_TOKEN` itself (or your `authorize` check). The same tokens connect AI assistants, as [Ask your AI](/docs/mcp/) explains.

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
| `filter` | `dimension:op:value`, where op is `is`, `not`, or `contains`. Repeat it to apply several. |
| `interval` | `hour`, `day`, `week`, or `month` for series, chosen from the range by default. |

| Endpoint | Returns |
| --- | --- |
| `GET /api/sites` | Every site, with when it last had a visit. |
| `GET /api/stats` | Visitors, visits, pageviews, views per visit, bounce rate, and visit duration, with the comparison period’s. |
| `GET /api/series` | The same numbers for each hour, day, week, or month of the range. |
| `GET /api/breakdown?dimension=` | Rows for one dimension, with `limit` (up to 1000) and `page`. |
| `GET /api/rhythm` | Visits by weekday and hour. |
| `GET /api/realtime` | People on the site in the last 5 minutes, pages, sources, countries, pageviews per minute, and recent activity. |
| `GET /api/goals` | Every goal with its conversions, converted visitors, rate, and revenue. |
| `GET /api/goals/:id` | One goal with a series and its conversions by channel, source, and page. |
| `GET /api/links` | Short links with their clicks. |
| `GET /api/links/:id` | One link’s clicks over time, sources, countries, devices, and browsers. |

`breakdown` and `filter` accept the dimensions `page`, `entry`, `exit`, `hostname`, `event`, `referrer`, `source`, `channel`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `country`, `region`, `city`, `browser`, `browser_version`, `os`, `os_version`, `device`, `screen`, and `language`. `breakdown` also takes `ai_agent` and `ai_page`.

## Changing things

| Endpoint | Does |
| --- | --- |
| `PATCH /api/sites/:id` | Change a site’s `name` or `timezone`. |
| `POST /api/goals`, `PATCH /api/goals/:id`, `DELETE /api/goals/:id` | Add, change, or remove a goal. |
| `POST /api/links`, `PATCH /api/links/:id`, `DELETE /api/links/:id` | Add, change, or remove a short link. |
| `GET`, `POST /api/link-domains`, `DELETE /api/link-domains/:domain` | List, add, or remove custom link domains. |
| `GET`, `POST /api/shares`, `PATCH`, `DELETE /api/shares/:id` | List, add, rename, or remove share links. |
| `GET`, `PUT`, `DELETE /api/mail`, `POST /api/mail/test` | Read, set, remove, or test the mail service. Keys are never returned. |
| `GET`, `POST /api/reports`, `DELETE /api/reports/:id`, `POST /api/reports/:id/send` | List, add, or remove report recipients, or send a sample. |
| `GET` or `POST /api/check` | Runs the [scheduled check](/docs/cron/). |
| `POST /api/observe` | Records a page served to an AI agent, sent as `{ "url", "userAgent" }`. It accepts the token or the observe key, and the CMS plugins call it. |
| `GET /api/tokens` | Lists API tokens with each one's name, site, last four characters, and when it was last used. The tokens themselves are never returned. |
| `POST /api/tokens` | Makes a read-only token from `{ "name", "site" }` and returns it once as `secret`. Leave `site` empty for every site. |
| `DELETE /api/tokens/:id` | Deletes a token, which stops it working at once. |
| `POST /mcp` | The MCP server for AI assistants, described in [Ask your AI](/docs/mcp/). |

## Errors

Errors are JSON, `{ "error": "..." }`, in plain words, with 400 for something wrong in the request, 401 without the token, 404 for something that is not there, and 503 when no token is set in production.
