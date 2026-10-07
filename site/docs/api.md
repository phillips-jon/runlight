---
title: HTTP API
description: Everything the dashboard shows is JSON at /runlight/api, for your own scripts and tools.
group: Reference
order: 11
---

The dashboard is built on this API, so anything it shows you can fetch yourself. Send the token as a bearer:

```bash
curl https://example.com/runlight/api/stats?period=30d -H "Authorization: Bearer $RUNLIGHT_TOKEN"
```

Requests that change something must send `content-type: application/json`.

## Reading reports

Every report takes the same query parameters:

| Parameter | Values |
| --- | --- |
| `site` | The site id. Defaults to the first site. |
| `period` | `today`, `yesterday`, `7d`, `30d`, `90d`, `month`, `last_month`, `year`, `12mo`, or `all`. |
| `from`, `to` | Dates as `YYYY-MM-DD`, both inclusive, instead of a period. |
| `compare` | `previous` (the default), `year`, `custom`, or `off`. |
| `compare_from`, `compare_to` | The dates to compare with, for `compare=custom`. |
| `filter` | `dimension:op:value`, where op is `is`, `not`, or `contains`. Repeat for several. |
| `interval` | `hour`, `day`, `week`, or `month` for series. Chosen from the range by default. |

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

Dimensions for `breakdown` and `filter`: `page`, `entry`, `exit`, `hostname`, `event`, `referrer`, `source`, `channel`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `country`, `region`, `city`, `browser`, `browser_version`, `os`, `os_version`, `device`, `screen`, and `language`. `breakdown` also takes `ai_agent` and `ai_page`.

## Changing things

| Endpoint | Does |
| --- | --- |
| `PATCH /api/sites/:id` | Change a site’s `name` or `timezone`. |
| `POST /api/goals`, `PATCH /api/goals/:id`, `DELETE /api/goals/:id` | Add, change, or remove a goal. |
| `POST /api/links`, `PATCH /api/links/:id`, `DELETE /api/links/:id` | Add, change, or remove a short link. |
| `GET`, `POST /api/link-domains`, `DELETE /api/link-domains/:domain` | List, add, or remove custom link domains. |
| `GET`, `POST /api/shares`, `PATCH`, `DELETE /api/shares/:id` | List, add, rename, or remove share links. |
| `GET`, `PUT`, `DELETE /api/mail`, `POST /api/mail/test` | The mail service. Keys are never returned. |
| `GET`, `POST /api/reports`, `DELETE /api/reports/:id`, `POST /api/reports/:id/send` | Report recipients, and sending a sample. |
| `GET` or `POST /api/check` | The [scheduled check](/docs/cron/). |

## Errors

Errors are JSON, `{ "error": "..." }`, in plain words, with 400 for something wrong in the request, 401 without the token, 404 for something that is not there, and 503 when no token is set in production.
