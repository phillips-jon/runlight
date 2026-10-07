---
title: The dashboard
description: What each number means, and how to filter, compare, share, and watch it live.
group: Features
order: 4
---

The dashboard lives at `/runlight` on your own site. It is one page: a headline sentence, six metric cards over a chart, and a board of boxes below.

## The six numbers

| Metric | What it counts |
| --- | --- |
| Visitors | Different people, each counted once a day. See [Privacy](/docs/privacy/) for how a person is told apart without being identified. |
| Visits | Sessions. A visit ends after 30 minutes with nothing happening. |
| Pageviews | Pages loaded, including page changes in single page apps. |
| Views per visit | Pageviews divided by visits. |
| Bounce rate | Visits with one pageview, no event, and under 10 seconds of engaged time, as a share of all visits. |
| Visit duration | The average engaged time per visit: only while the tab was visible and focused. |

Click a card to put it on the chart; several can share it, each scaled to its own peak so their shapes can be compared. Hover the chart for the exact numbers.

## The boxes

- **Pages**: top pages with time on page, entry pages with bounce rate, and exit pages.
- **Sources**: channels (Organic Search, Social, Direct, AI, Email, Referral, Campaign, Paid Search), named sources, and referring hosts.
- **Locations**: countries, regions, and cities, as a list or a map.
- **When people visit**: visits by weekday and hour, in the site’s timezone.
- **AI agents**: AI agents that fetched your pages, and which pages. See [AI sources and agents](/docs/ai/).
- **Devices**: device type, browser, operating system, screen size, and language.
- **Events**: your own events and the automatic ones.
- **Campaigns**: your UTM tags, by source, medium, campaign, term, and content.
- **Conversions**: your [goals](/docs/goals/).
- **Links**: your [short links](/docs/links/).

**Show more** opens the full list with every column and a search box.

## Filters

Click any row to filter the whole dashboard by it, or use **Filter** for anything: page, entry or exit page, source, channel, referrer, each UTM tag, country, region, city, browser, operating system, device, screen, language, hostname, and event. Filters can be **is**, **is not**, or **contains**, and they combine.

## Dates and comparison

Pick a range from the calendar or a preset (Last 30 days is the default). Compare it to the period before, the same days last year, or any dates you choose; the cards show the change and the chart draws the comparison dashed. **All time** has nothing before it, so it turns comparison off.

**Reset** puts everything back to Last 30 days with no filters or comparison. The browser’s back button undoes it. Every view is in the URL, so you can bookmark or send it.

## Right now

Click **here now** under the site name for the last 30 minutes: pageviews per minute, the pages, sources, and countries active now, and a feed of what happened, such as “Someone in Toronto, Canada viewed /pricing from Google”. It refreshes every 10 seconds. It never says who.

## Sharing

Settings, Sharing makes a read-only link to one site’s dashboard, for a client or your team. Anyone with the link sees the reports and conversions, never your short links, settings, or the site’s address. Delete the link and it stops working at once. A shared dashboard uses the same page, served from `/runlight/share/<id>`, and the id is 128 random bits.

## Settings

The gear beside the site name opens Settings: the site’s name, timezone, and language; install steps; goals; email reports; sharing; custom domains for short links; and importing links. The theme switch is in the footer, or press Shift+Cmd+D (Shift+Ctrl+D).
