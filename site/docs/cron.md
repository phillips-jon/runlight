---
title: Scheduled check
description: One request an hour keeps salts, reports, retention, and daily totals up to date.
group: Features
order: 9
---

Once an hour, Runlight makes the day’s new salt for [counting visitors](/docs/privacy/) and deletes the old ones. The same run sends any [email reports](/docs/reports/) that are due and deletes visits older than a site keeps. It also adds up each finished day, so long ranges load quickly. This upkeep happens when something calls the check.

```bash
curl -X POST https://example.com/runlight/api/check -H "Authorization: Bearer $CRON_SECRET"
```

The check accepts GET or POST, with `CRON_SECRET` (or the dashboard token) as a bearer token. Calling it more often does no harm.

Visits are counted correctly without the check, because the first visit of the day also makes the salt. Without it, no reports go out and visits past a site’s retention are kept. Long ranges also stay slower, since they read every visit.

## Vercel

Set `CRON_SECRET` in the project’s environment, then add the cron to `vercel.json`.

```json file=vercel.json
{
  "crons": [{ "path": "/runlight/api/check", "schedule": "0 * * * *" }]
}
```

Vercel calls it with GET and the secret as a bearer token, which is what Runlight expects.

## Anywhere else

Any scheduler that can make an HTTPS request will work, including a crontab line, GitHub Actions, Cloudflare Cron Triggers, or your platform’s scheduler.

```bash
0 * * * * curl -fsS -X POST https://example.com/runlight/api/check -H "Authorization: Bearer YOUR_CRON_SECRET" > /dev/null
```

You can also call `await rl.check()` from code you already run on a timer. Each language’s page shows its own way to run the check, such as `bin/rails runlight:check` in Rails or a hosted service in .NET. The standalone servers run it themselves every five minutes.
