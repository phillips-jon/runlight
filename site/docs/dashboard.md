---
title: The dashboard
description: This page covers what each number means and how to filter, compare, share, and watch it live.
group: Features
order: 4
---

The dashboard lives at `/runlight` on your own site. Its single page starts with a headline sentence and six metric cards over a chart, with a board of boxes below.

## The six numbers

| Metric | What it counts |
| --- | --- |
| Visitors | Different people, each counted once a day (see [Privacy](/docs/privacy/) for how a person is told apart without being identified). |
| Visits | Sessions, each ending after 30 minutes with nothing happening. |
| Pageviews | Pages loaded, including page changes in single page apps. |
| Views per visit | Pageviews divided by visits. |
| Bounce rate | Visits with one pageview, no event, and under 10 seconds of engaged time, as a share of all visits. |
| Visit duration | The average engaged time per visit, counting only time while the tab was visible and focused. |

Click a card to put it on the chart; several can share it, each scaled to its own peak so their shapes can be compared. Hover the chart for the exact numbers.

## The boxes

- **Pages** shows top pages with time on page, entry pages with bounce rate, and exit pages.
- **Sources** breaks traffic down by channel (Organic Search, Social, Direct, AI, Email, Referral, Campaign, Paid Search), named source, and referring host.
- **Locations** shows countries, regions, and cities, as a list or a map.
- **When people visit** shows visits by weekday and hour, in the site’s timezone.
- **AI agents** lists the AI agents that fetched your pages and which pages they fetched. See [AI sources and agents](/docs/ai/).
- **Devices** breaks visits down by device type, browser, operating system, screen size, and language.
- **Events** shows your own events and the automatic ones. The list button on each row opens its properties, such as the address of every outbound link and download or the path of every 404, with how often each came up.
- **Campaigns** shows your UTM tags by source, medium, campaign, term, and content.
- **Conversions** shows your [goals](/docs/goals/).
- **Links** shows your [short links](/docs/links/).

**Show more** opens the full list with every column and a search box.

## Filters

Click any row to filter the whole dashboard by it. The **Filter** button can filter by page, entry or exit page, source, channel, referrer, each UTM tag, country, region, city, browser, operating system, device, screen, language, hostname, and event. Each filter uses **is**, **is not**, or **contains**, and filters combine.

## Dates and comparison

Pick a range from the calendar or a preset (Last 30 days is the default). Compare it to the period before, the same days last year, or any dates you choose; the cards show the change and the chart draws the comparison dashed. **All time** has nothing before it, so it turns comparison off.

**Reset** puts everything back to Last 30 days with no filters or comparison, and the browser’s back button undoes it. Every view is in the URL, so you can bookmark or send it.

## Right now

Click **here now** under the site name to see the last 30 minutes. The view shows pageviews per minute, the pages, sources, and countries active now, and a feed of what happened, such as “Someone in Toronto, Canada viewed /pricing from Google”. It refreshes every 10 seconds and never shows who anyone is.

## Sharing

Settings, Sharing makes a read-only link to one site’s dashboard for a client or your team. Anyone with the link sees the reports and conversions, and the link hides your short links, settings, and the site’s address. Delete the link and it stops working at once. A shared dashboard uses the same page, served from `/runlight/share/<id>` (or `/share/<id>` on the standalone server), and the id is 128 random bits.

## Exporting

**Export** in the footer downloads everything the dashboard shows for the current dates and filters as a ZIP of CSV files. It holds the six numbers, the numbers for each day, every breakdown up to 1,000 rows, and your goals. Every full list also has **Download CSV** for that one table. A share link can export its own site, and the same files come from the API at `/api/export` and from `/api/breakdown` with `format=csv`.

## Bringing history over from Umami

In **Settings**, **Import**, **Visits**, sign in to your Umami with an API key (or a username and password on a stock self-hosted Umami) and pick the Umami website that matches this site. Runlight reads its pageviews and custom events a few days at a time, oldest first, and writes them as visits with their sources, campaigns, places, and devices. A gap of thirty minutes starts a new visit, as it does for live visits.

The import stops where Runlight's own visits begin, so no day is counted twice. If you stop it or close the page, running it again carries on from the last day it finished. Umami records no engaged time, so an imported visit's length runs from its first pageview to its last. Your key or password is only used while the import runs and is never saved.

## Journeys

The arrows button in the **Pages** box opens Journeys, the paths visits take through the site a page at a time. Each column is a step, with its most common pages and how many visits went no further, and the lines between columns show where visits went next, thicker for more. A page seen twice in a row, as a refresh makes, counts once. Pick how many steps to show, start from a page such as your pricing page, or end at one such as a thank-you page. Click any page to follow only the visits that passed through it at that step. The same answer comes from `/api/journeys` and the MCP tool `get_journeys`.

## The AI Assistant

The robot button beside **Filter** opens an assistant you can ask about your stats in plain words, such as where visitors came from last month or which pages keep people reading. It reads the numbers with the same read-only tools as the [MCP server](/docs/mcp/), for the site and dates on screen unless you ask about others, and it can never change anything.

An owner sets it up once in **Settings**, **AI Assistant**. Choose Anthropic, OpenAI, Google Gemini, OpenRouter, Ollama, LM Studio, or any service with an OpenAI-compatible API, then a model and a key. Ollama and LM Studio run a model on your own machine with no key, as long as the server running Runlight can reach it. The key is kept on the server, encrypted with `RUNLIGHT_SECRET` (or the token when there is no secret), and never sent back to a browser.

Each question goes to the service you chose, along with the numbers the assistant reads to answer it. Runlight keeps nothing about individual visitors, so nothing personal is sent. Owners and viewers can ask it; API tokens and share links cannot. The conversation lives in the browser tab and is gone when the tab closes.

## Keeping data

Each site keeps every visit unless you choose otherwise. In **Settings**, **Data**, **Keep visits for** takes anything from 6 months to 5 years. Saving a shorter time deletes older visits and events for good, and the dashboard says from which date before you save. After that the scheduled check deletes whatever passes the limit each day. Goals, links, and settings stay. The same section has **Export everything**, a ZIP of every report since the site’s first visit, worth downloading before you shorten the time.

## Settings

The gear beside the site name opens Settings, which holds the site’s name and timezone; install steps; goals; email reports; sharing; custom domains for short links; importing links and visits; API tokens; the AI Assistant; and the site’s data. On the standalone server it also holds People. The dashboard’s language is in General too, and it is kept for each browser. The theme switch is in the footer, and Shift+Cmd+D (Shift+Ctrl+D) toggles the theme too.
