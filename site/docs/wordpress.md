---
title: WordPress
description: Count a WordPress site with Runlight, and see when AI agents read it.
group: Platforms
order: 14
---

The Runlight plugin connects a WordPress site to a Runlight you run elsewhere: an app with Runlight mounted, or the standalone server. WordPress keeps nothing but the plugin’s one setting; the numbers live in your Runlight.

## What it does

- Adds Runlight’s script to every page, and marks 404 pages so broken links show up in Events.
- Leaves out administrators’ own visits (you can turn that off).
- Reports AI agents such as ChatGPT, Claude, and Perplexity when they fetch your pages. They run no JavaScript, so the script cannot see them; the plugin tells Runlight from the server, without waiting for an answer.
- Adds a Runlight item to the admin menu that opens your dashboard.

## Set it up

1. Install the plugin and activate it.
2. In your Runlight, make sure the site’s hostname is counted: add it to `hostnames` (see [Configuration](/docs/configuration/#sites)).
3. In WordPress, go to Settings, Runlight, and enter the address Runlight is mounted at, such as `https://stats.example.com/runlight`. Saving checks that it answers, and says so.
4. To count AI agents, set `RUNLIGHT_OBSERVE_KEY` on your Runlight to a long random string, and enter the same key in the plugin. The key can report agent fetches and nothing else: it cannot read your stats.

## Page caches

Caching plugins that serve pages straight from the web server, without running PHP (WP Super Cache in its expert mode, for instance), still show the script, so visits are counted. But WordPress never runs for those requests, so AI agent fetches of cached pages are not reported. Caches that run through PHP, such as WP Rocket and most host-level caches, are fine.
