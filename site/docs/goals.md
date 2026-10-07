---
title: Goals
description: Count signups, purchases, and clicks as conversions, with their value, worked out from data you already have.
group: Features
order: 5
---

A goal turns something people do into a conversion. Add goals in Settings, Goals; the Conversions box on the dashboard shows each one’s conversions, conversion rate, and revenue. Click a goal for a chart and its conversions by channel, source, and the page where they happened.

Goals are worked out when you read them, not when visits come in. A goal you add today counts last month as well, and changing a goal changes the past with it.

## Event goals

Count an event you already send, by name:

```js
runlight("Newsletter signup");
```

The form suggests the event names Runlight has seen in the last 90 days.

## Page goals

Count visits to a page. Use `*` for anything:

| Page | Counts |
| --- | --- |
| `/thanks` | exactly /thanks |
| `/thanks*` | /thanks, /thanks/pro, /thanks?plan=team |
| `/blog/*` | every post under /blog/ |

Pasting a full URL works; only its path is kept.

## Click goals

Count clicks on something with no code. Either:

- **An element**, by CSS selector, such as `#signup` or `.pricing .buy-button`, or
- **Links to an address**, such as `https://buy.stripe.com/*` for every Stripe checkout link, or `/pricing` for links to your own page.

**Pick on my site** opens your site in a picking mode: hover to see what you would choose, click it, and press **Use this**. The selector comes back to the form, along with how many elements on the page it matches. Picking counts nothing and makes no request of its own.

Click goals ship inside the tracker script, so there is no extra request on your pages. The script is cached for five minutes, so a new click goal starts counting within about five minutes. Unlike event and page goals, a click goal only counts from when it was added.

## Value and revenue

Each goal can be worth:

- **Nothing**: conversions only.
- **A fixed amount**, such as 2 for a newsletter signup.
- **An amount sent with the event** (event goals only), from a property, `revenue` by default:

```js
runlight("Purchase", { revenue: 49.99 });
```

Numbers and numeric strings count; anything else counts as nothing. Each goal has one currency. Revenue in different currencies is shown side by side, never converted.

## Conversion rate

The share of the period’s visitors who converted at least once. Like everything else on the dashboard, it follows the date range and any filters.
