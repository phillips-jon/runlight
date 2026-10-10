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

- **Pages** shows top pages with time on page, entry pages with bounce rate, and exit pages. Time on page is the average over every view of the page, and a view shorter than a second counts as none.
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

A filter picks visits, and the numbers then describe those whole visits, counted in the range each one started in. Filtering by the event Signup shows the people who signed up, with all their pages, time, and bounce rate, and **is not** picks the visits that never had one. A page filter counts that page’s views as pageviews, so “page is /pricing” shows how often /pricing was seen. With two page filters the views of either page count, and a hostname filter beside them keeps only the views on that host. Conversions, funnels, and event properties count the same visits, so a visit that starts before midnight and converts after it counts on the day it started. **Contains** ignores case, and up to six filters apply at once.

## Dates and comparison

Pick a range from the calendar or a preset (Last 30 days is the default). Compare it to the period before, the same days last year, or any dates you choose; the cards show the change and the chart draws the comparison dashed. **All time** has nothing before it, so it turns comparison off.

**Reset** puts everything back to Last 30 days with no filters or comparison, and the browser’s back button undoes it. Every view is in the URL, so you can bookmark or send it.

## Right now

Click **here now** under the site name to see what is happening on the site. The view shows pageviews for each of the last 30 minutes and a feed of what happened in them, such as “Someone in Toronto, Canada viewed /pricing from Google”. The count of people, and the pages, sources, and countries beside it, cover the last five minutes. It refreshes every 10 seconds and never shows who anyone is.

## Sharing

Settings, Sharing makes a read-only link to one site’s dashboard for a client or your team. Anyone with the link sees the reports and conversions, and the link hides your short links, settings, and the site’s address. Delete the link and it stops working at once. A shared dashboard uses the same page, served from `/runlight/share/<id>` (or `/share/<id>` on the standalone server), and the id is 128 random bits.

## Exporting

**Export** in the footer downloads everything the dashboard shows for the current dates and filters as a ZIP of CSV files. It holds the six numbers, the numbers for each day, every breakdown up to 1,000 rows, and your goals. Dates are the site’s own, rates are percents, and times are in seconds, so a spreadsheet reads them as they are. Every full list also has **Download CSV** for that one table. A share link can export its own site, and the same files come from the API at `/api/export` and from `/api/breakdown` with `format=csv`.

## Bringing history over from Umami

In **Settings**, **Import**, **Visits**, sign in to your Umami with an API key (or a username and password on a stock self-hosted Umami) and pick the Umami website that matches this site. Runlight reads its pageviews and custom events a few days at a time, oldest first, and writes them as visits with their sources, campaigns, places, and devices. A gap of thirty minutes starts a new visit, as it does for live visits.

The import stops where Runlight’s own visits begin, so no day is counted twice. If you stop it or close the page, running it again carries on from the last day it finished. Umami records no engaged time, so an imported visit’s length runs from its first pageview to its last. Your key or password is only used while the import runs and is never saved.

## Bringing history over from a CSV file

In **Settings**, **Import**, **Visits**, choose **A CSV file** and pick the file. Runlight takes two kinds of file and tells them apart by their header row. The first is the CSV from Umami’s data export, with one row for each pageview or event, which suits an Umami you can no longer reach. The second is Runlight’s own visit format, for history from anywhere else, as long as it has a row for each pageview. A script or an AI assistant can turn most raw logs into it.

| Column | What it holds |
| --- | --- |
| `time` | When it happened, as ISO 8601 (`2024-05-01T12:34:56Z`), `2024-05-01 12:34:56` in UTC, or a Unix time in seconds or milliseconds. Required. |
| `url` or `path` | The full address, or the path with its query string. Required. |
| `hostname` | The host, when `path` is used. Defaults to the site’s first domain. |
| `visitor` | Any id that stays the same for one person, such as a session id. Rows with the same visitor less than thirty minutes apart make one visit. Without it, every row is its own visit. |
| `event` | A custom event’s name. A row with one is an event on that page, and a row without one is a pageview. |
| `referrer` | Where the visit came from, as an address or a domain. |
| `title` | The page title. |
| `country`, `region`, `city` | A two-letter country code, a region code such as `CA-ON`, and a city name. |
| `browser`, `os`, `device` | Names such as `Chrome`, `macOS`, and `mobile`, `tablet`, or `desktop`. |
| `screen`, `language` | Such as `1440x900` and `en-CA`. |

```csv
time,url,visitor,referrer,country,device
2024-05-01T12:34:56Z,https://example.com/?utm_source=newsletter,3f9a,news.ycombinator.com,CA,mobile
2024-05-01T12:36:10Z,https://example.com/pricing,3f9a,,CA,mobile
```

As with Umami, only rows from before Runlight’s own first visit come across, and campaigns are read from the `utm_` parameters in each address. The file is read in your browser and sent 2,000 rows at a time. Importing the same file again replaces the rows it brought in before, so nothing is counted twice.

## Journeys

The arrows button in the **Pages** box opens Journeys, the paths visits take through the site a page at a time. Each column is a step, with its most common pages and how many visits went no further, and the lines between columns show where visits went next, thicker for more. A page seen twice in a row, as a refresh makes, counts once. Pick how many steps to show, start from a page such as your pricing page, or end at one such as a thank-you page. Click any page to follow only the visits that passed through it at that step. The same answer comes from `/api/journeys` and the MCP tool `get_journeys`.

## The AI Assistant

The robot button beside **Filter** opens an assistant you can ask about your stats in plain words, such as where visitors came from last month or which pages keep people reading. It reads the numbers with the same read-only tools as the [MCP server](/docs/mcp/), for the site and dates on screen unless you ask about others, and it can never change anything.

The owner or an admin sets it up once in **Settings**, **AI Assistant**. Choose Anthropic, OpenAI, Google Gemini, OpenRouter, Ollama, LM Studio, or any service with an OpenAI-compatible API, then a model and a key. Ollama and LM Studio run a model on your own machine with no key, as long as the server running Runlight can reach it. The key is kept on the server, encrypted with `RUNLIGHT_SECRET` (or the token when there is no secret), and never sent back to a browser.

Each question goes to the service you chose, along with the numbers the assistant reads to answer it. Runlight keeps nothing about individual visitors, so nothing personal is sent. Everyone signed in to the dashboard can ask it, though API tokens and share links cannot. Each question spends your AI credit, so each person can ask thirty an hour, and each viewer 50 a day, a number the owner or an admin can change under **AI Assistant** or set to 0 to keep the assistant from viewers. The conversation lives in the browser tab and is gone when the tab closes.

## Keeping data

Each site keeps every visit unless you choose otherwise. In **Settings**, **Data**, **Keep visits for** offers 6 months or 1, 2, 3, or 5 years. Saving a shorter time deletes older visits and events for good, and the dashboard says from which date before you save. After that the scheduled check deletes whatever passes the limit each day. Goals, links, and settings stay. The same section has **Export everything**, a ZIP of every report since the site’s first visit, worth downloading before you shorten the time.

## Settings

The gear beside the site name opens Settings. **General** holds the site’s name and timezone, along with the dashboard’s language and theme, which each browser keeps for itself. The other sections are **Install**, **Goals**, **Funnels**, **Email service**, **Email reports**, **Sharing**, **API and AI**, **Custom domains**, **Import**, **Data**, and **AI Assistant**, and the owner and admins also see **People** when accounts are on, as they always are on the standalone server. The theme switch is also in the footer, and Shift+Cmd+D (Shift+Ctrl+D) toggles it from anywhere.
