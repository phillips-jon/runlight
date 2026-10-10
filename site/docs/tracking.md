---
title: Tracking
description: The script counts some things on its own, and this page shows how to send your own events and change the settings on the script tag.
group: Start
order: 3
---

## What it counts by itself

With just the script tag, Runlight records these on its own.

- **Pageviews**, including page changes in single page apps (it follows `history.pushState`, `replaceState`, and the back button).
- **Engaged time and scroll depth** for each pageview. Time only counts while the tab is visible and focused.
- **Outbound links**, recorded as an `Outbound link` event with the `url` when someone clicks a link to another site.
- **File downloads**, recorded as a `File download` event when someone clicks a link to a PDF, zip, disk image, document, audio, or video file.
- **404s**, on a page whose script tag has `data-404` (see below). Each one is an event named `404` whose `path` property is the address that was not found, so the properties of `404` in the Events box list the broken addresses people reached and how often.

Runlight skips visits from known bots and from browsers driven by automation, such as Playwright, Selenium, and Puppeteer.

## Your own events

Call `runlight` with a name, and optionally some properties.

```js
runlight("Newsletter signup", { source: "footer" });
runlight("Purchase", { plan: "pro", revenue: 49 });
```

Properties can be strings, numbers, or booleans. Each event takes up to 30 of them, with names up to 60 characters and values up to 500. Events count toward visits and can be [goals](/docs/goals/).

If your code may run before the script has loaded, queue the calls.

```html
<script>
  window.runlight = window.runlight || function () { (window.runlight.q = window.runlight.q || []).push(arguments); };
</script>
```

## Clicks with no JavaScript

Give any element a `data-runlight` attribute and a click on it sends that event. Extra `data-runlight-*` attributes become properties.

```html
<button data-runlight="Signup" data-runlight-plan="pro">Sign up</button>
```

To count clicks on something you cannot edit, add a [click goal](/docs/goals/#click-goals) in the dashboard, which needs no code at all.

## Settings on the script tag

| Attribute | What it does |
| --- | --- |
| `data-site="id"` | Which site, when one install counts several and hostnames are not enough. |
| `data-hash` | Count changes to `location.hash` as pageviews (for hash routers). |
| `data-404` | Mark this page as a 404, so the pageview also records a `404` event with the page’s path. Put it on your not-found page, as the WordPress, Drupal, and Craft plugins do for you. |
| `data-dnt` | Respect Do Not Track. It is off by default, since Runlight keeps nothing personal. |
| `data-outbound="false"` | Do not record outbound link clicks. |
| `data-downloads="false"` | Do not record file downloads. |
| `data-exclude="/admin/*,/preview"` | Record nothing on these pages, neither pageviews nor events. Separate patterns with commas, and use `*` to match anything. |
| `data-manual` | Send no pageviews by yourself. Call `runlight.pageview()` when a page is shown, or `runlight.pageview("/checkout/step-2")` to name the page. |

## Leaving yourself out

In the dashboard, Settings, Install has an **Ignore this browser** switch. If your dashboard is on a different domain from the site, open any page of the site with `?runlight=ignore` once in each browser you use; `?runlight=track` undoes it. This flag is the only thing the script ever stores, and it exists only in browsers where you chose to set it.
