---
title: WordPress
description: Count a WordPress site with Runlight, and see when AI agents read it.
group: Platforms
order: 14
---

The Runlight plugin connects a WordPress site to a Runlight you run elsewhere, either in an app with Runlight mounted or on the standalone server. The numbers live in your Runlight, and WordPress stores only the plugin’s one setting.

## What it does

- It adds Runlight’s script to every page and marks 404 pages so broken links show up in Events.
- It leaves out administrators’ own visits unless you turn that off.
- It reports AI agents such as ChatGPT and Claude when they fetch your pages. Agents run no JavaScript, so the script cannot see them, and the plugin reports them from the server without waiting for a reply.
- It adds a Runlight item to the admin menu that opens your dashboard.

## Set it up

1. Install the plugin and activate it.
2. In your Runlight, add the site’s hostname to `hostnames` so it is counted (see [Configuration](/docs/configuration/#sites)).
3. In WordPress, go to Settings, Runlight, and enter the address Runlight is mounted at, such as `https://stats.example.com/runlight`. When you save, the plugin checks that the address answers and tells you the result.
4. To count AI agents, copy this site's key from **Settings**, **Install**, **Key for CMS plugins** in Runlight and enter it in the plugin. The key can only report agent fetches for this one site, so it cannot read your stats or write into another site.

## Page caches

Some caching plugins serve pages straight from the web server without running PHP, such as WP Super Cache in its expert mode. Those pages still include the script, so visits are counted. WordPress never runs for those requests, so AI agent fetches of cached pages are not reported. Caches that run through PHP, such as WP Rocket and most host-level caches, report agent fetches as usual.
