---
title: Email reports
description: Weekly or monthly summaries by email, sent through your own email service, in each reader's language.
group: Features
order: 8
---

Runlight can email a summary of a site every week or month: the headline sentence, the six numbers against the period before, top pages, sources, and countries, and conversions with their revenue. It is sent from your own address, through an email service you already use.

## 1. Set up the mail service

In Settings, Email reports, pick a service, enter its keys, and the address reports come from. **Send test** checks it works. One mail service serves every site in the install.

| Service | What it needs |
| --- | --- |
| Amazon SES | Region, access key ID, and secret access key (an IAM user allowed `ses:SendEmail`) |
| Resend | API key |
| Postmark | Server API token, and optionally the message stream |
| SendGrid | API key |
| Mailgun | Sending domain, API key, and region (US or EU) |
| Brevo | API key |
| Mailjet | API key and secret key |
| MailerSend | API token |
| SparkPost | API key and region (US or EU) |
| SMTP | Host, port, security (STARTTLS, TLS, or none), and optionally a username and password |
| Webhook | A URL Runlight posts each email to as JSON, and optionally a signing secret |

The from address has to be one your service lets you send from, usually on a domain you have verified with it.

Keys are stored encrypted with a key derived from `RUNLIGHT_SECRET` (or, without it, `RUNLIGHT_TOKEN`), and never sent back to the browser: to keep a saved key, leave its field blank. If neither variable is set, keys are stored as typed and Settings tells you so.

To set the service in code instead, pass `mail`; Settings then shows it and cannot change it:

```ts
runlight({
  store,
  mail: { service: "resend", apiKey: process.env.RESEND_API_KEY!, from: "reports@example.com", fromName: "Runlight" },
});
```

### The webhook

The webhook gets a POST with JSON: `to`, `from`, `fromName`, `subject`, `html`, `text`, and `headers`. With a signing secret, the `x-runlight-signature` header is `sha256=` and the HMAC-SHA256 of the raw body, in hex. The URL must use https (or be localhost).

## 2. Add who gets reports

Under **Who gets reports**, add an address, weekly or monthly, and the language the email should be in. **Send a sample now** sends the latest report straight away.

- Weekly reports cover Monday to Sunday and go out from 8am on Monday.
- Monthly reports cover the calendar month and go out from 8am on the 1st.

Both use the site’s timezone, and each period is sent once. If sending fails, the next check tries again.

## 3. Schedule the check

Reports are sent by the [hourly check](/docs/cron/). Without it, nothing goes out.

## Unsubscribing

Every email has an unsubscribe link and the `List-Unsubscribe` headers mail apps use for their own unsubscribe button. The link opens a page with a button, so a mail scanner opening links cannot unsubscribe anyone by accident.
