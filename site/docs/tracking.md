---
title: Tracking
description: What the script counts on its own, how to send your own events, and the settings on the script tag.
group: Start
order: 3
---

## What it counts by itself

With just the script tag, Runlight records:

- **Pageviews**, including page changes in single page apps (it follows `history.pushState`, `replaceState`, and the back button).
- **Engaged time and scroll depth** for each pageview. Time only counts while the tab is visible and focused.
- **Outbound links**: a click on a link to another site is an `Outbound link` event with the `url`.
- **File downloads**: a click on a link to a PDF, zip, disk image, document, audio, or video file is a `File download` event.
- **404s**, when the page says so (see below).

Visits from browsers driven by automation (Playwright, Selenium, Puppeteer) and from known bots are not counted.

## Your own events

Call `runlight` with a name, and optionally some properties:

```js
runlight("Newsletter signup", { source: "footer" });
runlight("Purchase", { plan: "pro", revenue: 49 });
```

Properties are strings, numbers, or booleans: up to 30 per event, names up to 60 characters, values up to 500. Events count toward visits and can be [goals](/docs/goals/).

If your code may run before the script has loaded, queue the calls:

```html
<script>
  window.runlight = window.runlight || function () { (window.runlight.q = window.runlight.q || []).push(arguments); };
</script>
```

## Clicks with no JavaScript

Give any element a `data-runlight` attribute and a click on it sends that event. Extra `data-runlight-*` attributes become properties:

```html
<button data-runlight="Signup" data-runlight-plan="pro">Sign up</button>
```

To count clicks on something you cannot edit, add a [click goal](/docs/goals/#click-goals) in the dashboard instead: no code at all.

## Settings on the script tag

| Attribute | What it does |
| --- | --- |
| `data-site="id"` | Which site, when one install counts several and hostnames are not enough. |
| `data-hash` | Count changes to `location.hash` as pageviews (for hash routers). |
| `data-404` | This page is a 404: record a `404` event with its path. |
| `data-dnt` | Respect Do Not Track. Off by default, since Runlight keeps nothing personal. |
| `data-outbound="false"` | Do not record outbound link clicks. |
| `data-downloads="false"` | Do not record file downloads. |

## Leaving yourself out

In the dashboard, Settings, Install has an **Ignore this browser** switch. If your dashboard is on a different domain from the site, open any page of the site with `?runlight=ignore` once in each browser you use; `?runlight=track` undoes it. This is the only thing the script ever stores, and it is your choice, not a visitor id.
