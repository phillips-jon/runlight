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

For scripts, make a read-only token in **Settings**, **API and AI**, and keep `RUNLIGHT_TOKEN` to yourself. A read-only token can read every report below, short links and each one’s clicks included. You can limit it to one site, and it stops working the moment you delete it. Endpoints that change something, along with the token, share, and mail endpoints, need `RUNLIGHT_TOKEN` itself (or your `authorize` check). The same tokens connect AI assistants, as [Ask your AI](/docs/mcp/) explains.

A `manage` token belongs to a [standalone server](/docs/server/#connect-sites-that-count-themselves) that shows this site. It reads like a read-only token and can also change one site’s goals, funnels, short links, link domains, email reports, and share links, along with its name, timezone, and retention, and get tickets for the element picker. It can never touch other sites, people, tokens, imports, or the mail service, and it cannot change where the site lives. It sees which mail service sends reports and from which address, and the service’s keys and account details stay hidden from it. It adds link domains and email reports only when the install knows its own address, through `origin` in `routes()` or `RUNLIGHT_URL` on the standalone server. The standalone server gets one through OAuth when you connect the site, so you rarely make one by hand.

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
| `POST /api/sites/connect` | Start connecting another install through its consent page, from `{ "url" }`. It answers with `authorize`, the address to send the owner to. Add `site` with the install’s id for a site to offer that one first. |
| `GET /api/sites/connect/done` | Where the consent page sends the owner back. It finishes connecting and opens the dashboard on the site. |
| `POST /api/goals`, `PATCH /api/goals/:id`, `DELETE /api/goals/:id` | Add, change, or remove a goal. |
| `POST /api/pick` | Makes a ticket for the element picker from `{ "origin" }`, the dashboard’s own origin, which the picker sends its choice to and nowhere else. The ticket names the site too, and the picker does nothing on another site’s pages. A ticket works for half an hour. Owners only, and a manage token, whose tickets only ever name the hub it connected from. |
| `POST /api/funnels`, `PATCH /api/funnels/:id`, `DELETE /api/funnels/:id` | Add, change, or remove a funnel, sent as `{ "name", "steps" }` with two to eight steps of `{ "kind", "match" }`, where kind is `page` or `event`. |
| `POST /api/links`, `PATCH /api/links/:id`, `DELETE /api/links/:id` | Add, change, or remove a short link. |
| `POST /api/links/import` | Add many short links at once from `{ "rows" }`, up to 5,000 objects with `url` and, if you like, `slug`, `name`, and `domain`. It answers with how many it made and which rows failed. |
| `POST /api/links/import/:source` | One step of an import from `umami`, `dub`, `bitly`, `shortio`, or `rebrandly`, sent as `{ "credentials", "cursor", "done" }`. Send the `cursor` it answers with until it comes back `null`. Credentials are used and never kept. |
| `POST /api/import/umami/websites` | List the websites in an Umami account, from `{ "credentials" }`. |
| `POST /api/import/umami/visits` | One step of bringing an Umami website’s visit history in, from `{ "credentials", "website", "cursor" }`, repeated until `cursor` is `null`. |
| `GET`, `POST /api/link-domains`, `DELETE /api/link-domains/:domain` | List, add, or remove custom link domains. A link domain must be a public name, and never the dashboard’s own or a site’s. |
| `GET /api/link-domains/:domain/check` | Whether requests to a link domain reach Runlight, as `{ "domain", "working", "reason", "code" }`, where `reason` says what answered instead and `code` names it. |
| `GET`, `POST /api/shares`, `PATCH`, `DELETE /api/shares/:id` | List, add, rename, or remove share links. |
| `GET`, `PUT`, `DELETE /api/mail`, `POST /api/mail/test` | Read, set, remove, or test the mail service. Keys are never returned. |
| `GET`, `POST /api/reports`, `DELETE /api/reports/:id`, `POST /api/reports/:id/send` | List, add, or remove report recipients, or send a sample. |
| `GET` or `POST /api/check` | Runs the [scheduled check](/docs/cron/). |
| `POST /api/observe` | Records a page served to an AI agent, sent as `{ "url", "userAgent", "at" }`, where `at` is when it was served (within the last week, as epoch milliseconds or an ISO date) and can be left out. Send up to 500 at once as `{ "fetches": [...] }`. It accepts the token or an observe key, and the CMS plugins and the [log reader](/docs/server/#ai-agents-from-a-log) call it. |
| `GET /api/tokens` | Lists API tokens with each one’s name, site, scope, last four characters, and when it was last used. The tokens themselves are never returned. |
| `POST /api/tokens` | Makes a token from `{ "name", "site", "scope" }` and returns it once as `secret`. Leave `site` empty for every site. `scope` is `read` (the default) or `manage`, which needs a `site`. |
| `GET /api/observe-key`, `POST /api/observe-key/new` | Read a site’s key for CMS plugins, made the first time it is asked for, or replace it with a new one, which stops the old one at once. |
| `GET /api/token` | Says what the token sent with it may do, as `{ "scope", "site" }`. A hub asks this before it offers to change anything. |
| `DELETE /api/token` | Deletes the token sent with it. A hub does this when it disconnects a site or is given a new token. |
| `DELETE /api/tokens/:id` | Deletes a token, which stops it working at once. |
| `GET`, `PUT`, `DELETE /api/assistant` | Read, set, or remove the dashboard assistant’s `{ "provider", "model", "baseUrl", "key" }`. The key is never returned. Owners only, though anyone at the dashboard can ask whether it is set up. |
| `POST /api/assistant/models` | The models a provider offers, from `{ "provider", "baseUrl", "key" }`, for the settings form. Leave `key` out to use the saved one, which works only for the same provider and address. Owners only. |
| `POST /api/assistant/chat` | Ask the assistant, sending `{ "site", "messages", "view", "language" }`, where messages are `{ "role", "content" }` pairs ending with a question. It answers `{ "reply", "tools" }`. People at the dashboard only, never API tokens or share links. Each person can ask thirty questions an hour and two at once, and each viewer the owner’s daily number, with 429 past either. |
| `PUT /api/assistant/limits` | Set how many questions each viewer can ask a day, from `{ "viewerDaily" }`, a whole number from 0 to 1,000. It starts at 50, and `GET /api/assistant` shows it to owners. Owners only. |
| `POST /mcp` | The MCP server for AI assistants, described in [Ask your AI](/docs/mcp/). |

## Errors

Errors are JSON, `{ "error", "code", "params" }`. `error` says what went wrong in plain English, `code` names it, and `params`, when it has any, fill the placeholders in its words. The dashboard shows each code in its own language, and a script can rely on the code where the English may change.

| Status | When |
| --- | --- |
| 400 | Something in the request is wrong or missing. |
| 401 | The token is missing or not one this install knows. |
| 403 | A viewer or an API token tries a change it may not make. |
| 404 | What the request names is not there. |
| 409 | A name is taken, such as a link domain another site has. |
| 413 | More than 500 fetches at once to `POST /api/observe`. |
| 415 | A write that is not `application/json`. |
| 429 | Too many in a short time, such as sign-in tries, samples, questions to the assistant, or OAuth registrations from one address. |
| 500 | Something went wrong on the server. |
| 502 | A connected install could not be reached, answered with a redirect, or refused the token, or the AI service failed. |
| 503 | No token is set outside development. |
| 504 | A connected install took too long to answer. |

These are the codes and the params each one fills. An error a connected install sends on through a hub keeps its code and params, and its `error` starts with the install’s host. A link domain’s check answers its `reason` with a `check_` code in the same way.

| Code | Params | What it says |
| --- | --- | --- |
| `account_exists` | `email` | {email} already has an account. |
| `assistant_address` |  | Enter the service’s address in Settings, AI Assistant. |
| `assistant_address_bad` |  | Enter the service’s address, starting with https:// |
| `assistant_cancelled` |  | The question was cancelled. |
| `assistant_daily` | `limit` | Viewers can ask {limit} questions a day. Ask again tomorrow. |
| `assistant_dashboard` |  | Only the dashboard can use the assistant. |
| `assistant_failed` | `detail` | The AI service did not answer as expected ({detail}). |
| `assistant_invalid` | `detail` | The assistant was not saved ({detail}). |
| `assistant_key` | `provider` | Enter your {provider} key. |
| `assistant_limit` |  | Use a whole number from 0 to 1,000. |
| `assistant_model` |  | Enter a model in Settings, AI Assistant. |
| `assistant_no_models` | `host` | {host} listed no models. Type the model’s name instead. |
| `assistant_provider` |  | Choose an AI service in Settings, AI Assistant. |
| `assistant_refused` | `detail`, `host` | {host} turned the request down ({detail}). |
| `assistant_slow` |  | That question took too long to answer. Try asking something narrower. |
| `assistant_soon` |  | You have asked a lot in a short time. Wait a little and ask again. |
| `assistant_status` | `host`, `status` | {host} answered {status}. |
| `assistant_steps` |  | The assistant needed too many steps for that question. Try asking something narrower. |
| `assistant_timeout` | `host` | {host} took too long to answer. |
| `assistant_unset` |  | The assistant is not set up yet. An owner can set it up in Settings, AI Assistant. |
| `check_https` |  | it could not be reached over HTTPS |
| `check_not_public` |  | it is not a public domain name |
| `check_not_runlight` |  | something answered, but not Runlight |
| `check_private` |  | it points at an address that is not public |
| `check_status` | `status` | it answered {status} |
| `check_timeout` |  | it took too long to answer |
| `code_wrong` |  | That code is not right. Check the time on your phone and try the next one. |
| `compare_bad` | `compare` | "{compare}" is not a comparison Runlight knows. |
| `compare_range_bad` |  | Pick both dates to compare with. |
| `connect_again` |  | Connect this site again to change it from here. |
| `connect_denied` |  | The connection was not allowed. |
| `connect_endpoints` | `url` | {url} named endpoints on another address. |
| `connect_expired` |  | That connection took too long or was already used. Start again. |
| `connect_failed` | `detail` | Connecting did not start ({detail}). |
| `connect_not_runlight` | `url` | {url} did not answer like a Runlight install. |
| `connect_old` | `url` | {url} runs an older Runlight. Update it, or connect it with an API token from its Settings. |
| `connect_refused` |  | The install would not let this server connect. Start again, or connect it with an API token. |
| `connect_register` | `reason`, `url` | {url} would not let this server connect. {reason} |
| `connect_token` |  | The install did not give this server a token. Start again. |
| `connect_url` |  | Enter the install’s address, like https://example.com/runlight |
| `domain_in_use` | `domain` | {domain} is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go.{domain}. |
| `domain_invalid` |  | That is not a domain name. |
| `domain_not_public` | `domain` | {domain} is not a public domain name. Use one that browsers anywhere can reach. |
| `domain_taken` | `domain` | {domain} already belongs to another site. |
| `email_invalid` |  | Enter an email address. |
| `event_needed` |  | Name the event. |
| `filter_bad` | `filter` | The filter "{filter}" is not one Runlight reads. |
| `filters_max` | `max` | Use at most {max} filters at once. |
| `funnel_exists` | `name` | There is already a funnel called "{name}". |
| `funnel_invalid` | `detail` | The funnel was not saved ({detail}). |
| `funnel_long` |  | A funnel has at most eight steps. |
| `funnel_name` |  | Give the funnel a name. |
| `funnel_page_bad` | `match` | "{match}" is not a path or a URL. |
| `funnel_short` |  | A funnel needs at least two steps. |
| `goal_amount` |  | Enter an amount, like 49 or 9.99. |
| `goal_click_taken` | `match` | The click goal "{match}" already sends events with that name. |
| `goal_currency` |  | Use a three-letter currency code, like USD or EUR. |
| `goal_event` |  | Enter the event’s name. |
| `goal_event_taken` | `name` | An event goal already counts events called "{name}", so give this click goal another name. |
| `goal_exists` | `name` | There is already a goal called "{name}". |
| `goal_invalid` | `detail` | The goal was not saved ({detail}). |
| `goal_kind` |  | Pick what the goal counts, an event, a page visit, or a click. |
| `goal_link` |  | Enter the link’s address, like https://buy.stripe.com/* |
| `goal_name` |  | Give the goal a name. |
| `goal_page` |  | Enter a page path, like /thanks or /blog/* |
| `goal_page_bad` |  | That page is not a path or a URL. |
| `goal_prop_kind` |  | Only an event goal can take its amount from the event. Use a fixed amount instead. |
| `goal_prop_name` |  | A property name uses letters, numbers, dots, dashes, and underscores. |
| `goal_selector` |  | Enter a CSS selector, like #signup or .buy-button |
| `hub_domains` |  | A connected hub cannot change a site’s domains. |
| `icon_none` |  | This site has no icon. |
| `import_day_full` | `limit` | One day has more than {limit} events, more than an import step can read. |
| `import_failed` | `detail` | The import stopped ({detail}). |
| `import_key` | `service` | Enter your {service} key. |
| `import_refused` |  | The key or sign-in was refused. |
| `import_slug_bad` | `slug` | /{slug} has characters Runlight slugs cannot use. |
| `import_slug_taken` | `name`, `slug` | /{slug} is already used by "{name}". |
| `import_source` | `source` | Runlight cannot import from {source}. |
| `import_status` | `host`, `status` | {host} answered {status}. |
| `import_umami_address` |  | Enter your Umami address, like https://stats.example.com |
| `import_umami_login` |  | Enter an API key, or a username and password. |
| `import_website` |  | Pick the Umami website to import. |
| `install_refused` |  | That install refused the token. |
| `install_token` |  | Enter an API token from that install. |
| `internal` |  | Something went wrong on the server. Try again. |
| `invite_gone` |  | This invite has expired or was already used. Ask for a new one. |
| `last_owner` |  | Keep at least one owner. |
| `link_domain` | `domain` | Add {domain} as a link domain in Settings first. |
| `link_long` |  | The destination is longer than 2,000 characters. |
| `link_no_slug` |  | Could not find a free slug. Try again. |
| `link_protocol` |  | The destination must start with http:// or https:// |
| `link_slug` |  | A slug is letters, digits, dashes, and underscores, up to 100. |
| `link_taken` | `slug` | /{slug} is already taken. |
| `link_url` |  | The destination must be a full URL, starting with https:// |
| `mail_failed` | `detail` | The email could not be sent ({detail}). |
| `mail_field` | `field` | {field} is needed. |
| `mail_from` |  | Enter the address reports come from, like reports@example.com. |
| `mail_https` |  | The webhook URL must use https. |
| `mail_in_code` |  | The mail service is set in code, so it cannot be changed here. |
| `mail_option` | `field`, `options` | {field} must be one of {options}. |
| `mail_refused` | `detail`, `host` | {host} turned the email down ({detail}). |
| `mail_region` |  | That is not an AWS region, like us-east-1. |
| `mail_service` |  | Pick a mail service. |
| `mail_unreachable` | `host` | Could not reach {host}. |
| `mail_unset` |  | Set up a mail service first. |
| `method_not_allowed` |  | That cannot be done here. |
| `not_found` |  | That is not here. |
| `observe_many` |  | Send at most 500 fetches at a time. |
| `observe_url` |  | Send the page’s address. |
| `origin_needed` |  | Set this Runlight’s own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports. |
| `owner_only` |  | Only an owner can change this. |
| `password_current_wrong` |  | Your current password is not right. |
| `password_short` | `min` | Use a password of at least {min} characters. |
| `password_wrong` |  | Your password is not right. |
| `people_owner` |  | Only an owner can manage people. |
| `pick_hub` |  | This hub’s address is not the one it connected from. Connect the site again from here. |
| `pick_origin` |  | Send the dashboard’s origin, such as https://stats.example.com |
| `property_bad` |  | That is not a property name Runlight can read. |
| `question_needed` |  | Ask a question. |
| `range_bad` |  | Those dates are not a range Runlight can read. |
| `redirected` | `host` | {host} answered with a redirect. |
| `remote_slow` | `host` | {host} took too long to answer. Try a shorter range. |
| `remove_self` |  | You cannot remove yourself. |
| `report_exists` | `email` | {email} already gets this report. |
| `report_limit` |  | A site can send to at most 50 addresses. |
| `retention_bad` | `months` | Keep visits for {months} months, or forever. |
| `role_needed` |  | Pick owner or viewer. |
| `rows_needed` |  | Send the links as a list of rows. |
| `sample_soon` |  | A sample went out a moment ago. Wait a minute and try again. |
| `sample_soon_hub` |  | A connected hub can send one sample every ten minutes. Wait a few minutes and try again. |
| `send_json` |  | Send this as JSON. |
| `send_object` |  | Send a JSON object. |
| `share_gone` |  | This share link no longer works. |
| `share_not_available` |  | That is not available on a shared dashboard. |
| `sign_in` |  | Sign in first. |
| `site_domain_invalid` | `host` | "{host}" is not a domain name. |
| `site_domain_needed` |  | Add the site’s domain, like example.com |
| `site_domain_taken` | `host`, `site` | {host} already belongs to {site}. |
| `site_invalid` | `detail` | The site was not saved ({detail}). |
| `site_name` |  | A site name is 1 to 80 characters. |
| `site_remote` |  | This site is counted by its own Runlight. Connect it again from its settings to change it from here. |
| `sites_in_code` |  | Sites are set in code here, so they are changed there. |
| `smtp_starttls` |  | The SMTP server does not offer STARTTLS. Pick TLS or none for Security. |
| `test_email` |  | Enter an email address to send the test to. |
| `token_manage_only` |  | A manage token changes only its own site’s settings. |
| `token_name` |  | Name the token. |
| `token_read_only` |  | API tokens can only read. |
| `token_refused` | `host` | {host} refused the token. Connect it again from the site’s settings. |
| `token_site` |  | A token that changes settings is for one site. Pick the site. |
| `token_unset` |  | Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development. |
| `too_many_tries` |  | Too many tries. Wait fifteen minutes and try again. |
| `twofactor_off` |  | Turn on two-factor sign-in first. |
| `twofactor_restart` |  | Too many wrong codes. Start turning on two-factor sign-in again. |
| `twofactor_self` |  | Turn off your own two-factor sign-in under Account. |
| `unauthorized` |  | Sign in or send a token to see this. |
| `unknown_account` |  | That account no longer exists. |
| `unknown_dimension` | `dimension` | "{dimension}" is not a breakdown Runlight knows. |
| `unknown_domain` |  | That domain is not one of this site’s. |
| `unknown_funnel` |  | That funnel no longer exists. |
| `unknown_goal` |  | That goal no longer exists. |
| `unknown_invite` |  | That invite no longer exists. |
| `unknown_link` |  | That link no longer exists. |
| `unknown_report` |  | That report no longer exists. |
| `unknown_share` |  | That share link no longer exists. |
| `unknown_site` |  | That site is not here. |
| `unknown_timezone` | `timezone` | "{timezone}" is not a timezone Runlight knows. |
| `unknown_token` |  | That token no longer exists. |
| `unreachable` | `host` | Could not reach {host}. |
