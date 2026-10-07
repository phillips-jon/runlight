---
title: Scheduled check
description: One request an hour rotates the daily salt and sends email reports.
group: Features
order: 9
---

Runlight does a little upkeep once an hour: it makes the day’s new salt for [counting visitors](/docs/privacy/), deletes old ones, and sends any [email reports](/docs/reports/) that are due. It happens when something calls the check:

```bash
curl -X POST https://example.com/runlight/api/check -H "Authorization: Bearer $CRON_SECRET"
```

The check accepts `CRON_SECRET` (or the dashboard token) as a bearer token, and both GET and POST. Calling it more often is harmless.

Visits are counted correctly without it (the salt is also made on the first visit of the day), but reports are only sent by the check.

## Vercel

Set `CRON_SECRET` in the project’s environment, then:

```json file=vercel.json
{
  "crons": [{ "path": "/runlight/api/check", "schedule": "0 * * * *" }]
}
```

Vercel calls it with GET and the secret as a bearer token, which is what Runlight expects.

## Anywhere else

Any scheduler that can make an HTTPS request will do: a crontab line, GitHub Actions, Cloudflare Cron Triggers, or your platform’s scheduler.

```bash
0 * * * * curl -fsS -X POST https://example.com/runlight/api/check -H "Authorization: Bearer YOUR_CRON_SECRET" > /dev/null
```

Or call it from code you already run on a timer: `await rl.check()`.
