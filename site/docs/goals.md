---
title: Goals
description: Goals count events, page visits, and clicks as conversions with their value, worked out from data you already have.
group: Features
order: 5
---

A goal turns something people do into a conversion. Add goals in Settings, Goals, and the Conversions box on the dashboard shows conversions, conversion rate, and revenue for each one. Clicking a goal opens its chart and breaks its conversions down by channel, source, and the page where they happened.

Runlight works goals out at the moment you read them, so a goal you add today counts last month as well, and changing a goal changes the past with it.

## Event goals

An event goal counts an event you already send, by its name.

```js
runlight("Newsletter signup");
```

The form suggests the event names Runlight has seen in the last 90 days.

## Page goals

A page goal counts visits to a page, and `*` matches anything.

| Page | Counts |
| --- | --- |
| `/thanks` | /thanks, with or without a query such as ?plan=team |
| `/thanks*` | /thanks, /thanks/pro, and /thanks-team |
| `/blog/*` | every post under /blog/ |
| `/#/thanks` | the /thanks route of a site that uses hash routing |

You can paste a full URL, and Runlight keeps its path and any hash route. Paths are matched as browsers send them, so `/café` counts visits to /café.

## Click goals

A click goal counts clicks with no code, on either of two kinds of target.

- **An element**, by CSS selector, such as `#signup` or `.pricing .buy-button`, or
- **Links to an address**, such as `https://buy.stripe.com/*` for every Stripe checkout link, or `/pricing` for links to your own page.

**Pick on my site** opens your site in a picking mode where hovering shows what you would choose. Click the element and press **Use this**, and the selector comes back to the form along with how many elements on the page it matches. Picking counts nothing and makes no request of its own. The selector goes back only to the dashboard that opened the page, which Runlight names in a ticket that works for half an hour, so another page that opens your site in picking mode gets nothing.

Click goals ship inside the tracker script, so there is no extra request on your pages. The script is cached for five minutes, so a new click goal starts counting within about five minutes. Click goals are the exception to counting the past, because a click goal counts only from when it was added.

## Value and revenue

Each goal can have one of these values.

- **Nothing**, which counts conversions only.
- **A fixed amount**, such as 2 for a newsletter signup.
- **An amount sent with the event** (event goals only), taken from a property that is `revenue` by default.

```js
runlight("Purchase", { revenue: 49.99 });
```

Numbers and numeric strings count, and anything else counts as nothing. Each goal has one currency, and revenue in different currencies is shown side by side without conversion.

## Conversion rate

Conversion rate is the share of the period’s visitors who converted at least once. Like everything else on the dashboard, it follows the date range and any filters.

## Funnels

A funnel follows the steps you expect a visit to take, such as the pricing page and then signup, and shows how many visits made it through each step in order. Add one in **Settings**, **Goals**, under **Funnels**, with two to eight steps. A step is a page, where `*` matches anything (`/blog/*`), or an event by name.

Each step counts a visit only when it happens after the step before it, in the same visit. The Conversions box shows every funnel under **Funnels**, with the visits at each step and the share that went on from the step before. Filters choose which visits enter, so a funnel filtered to Organic Search counts only visits from search. Funnels are worked out from the data you already have, so a new funnel covers past visits too. They are also at `GET /api/funnels` and in the MCP server’s `list_funnels` tool.
