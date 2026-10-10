---
title: WordPress
description: Count a WordPress site with Runlight, and see when AI agents read it.
group: Platforms
order: 15
---

The Runlight plugin connects a WordPress site to a Runlight you run elsewhere, either in an app with Runlight mounted or on the standalone server. The numbers live in your Runlight, and WordPress stores only the plugin’s one setting.

## What it does

- It adds Runlight’s script to every page and marks 404 pages so broken links show up in Events.
- It leaves out administrators’ own visits unless you turn that off.
- It reports AI agents such as ChatGPT and Claude when they fetch your pages. Agents run no JavaScript, so the script cannot see them, and the plugin reports them from the server without waiting for a reply.
- It adds a Runlight item to the admin menu that shows this site’s dashboard in wp-admin.

## Set it up

1. Install the plugin and activate it.
2. In your Runlight, add the site’s hostname to `hostnames` so it is counted (see [Configuration](/docs/configuration/#sites)).
3. In WordPress, go to Settings, Runlight, and enter the address Runlight is mounted at, such as `https://stats.example.com/runlight`. When you save, the plugin checks that the address answers and tells you the result.
4. To count AI agents, copy this site’s key from **Settings**, **Install**, **Key for CMS plugins** in Runlight and enter it in the plugin. The key can only report agent fetches for this one site, so it cannot read your stats or write into another site.

## The dashboard in wp-admin

With a dashboard key, the Runlight item in the admin menu shows this site’s dashboard in wp-admin. It is the same read-only view a share link shows, with its reports and date ranges and none of Runlight’s settings, short links, people, or other sites. The **Open in Runlight** button opens the full dashboard in your own Runlight.

1. In Runlight, open **Settings**, **Install** for this site and choose **Make a key** under **Key for the dashboard in your CMS**. Copy the key, which Runlight shows only once.
2. Enter it as the dashboard key under Settings, Runlight.
3. Make sure the address wp-admin is served from is among the site’s domains in Runlight, since only an admin page on one of them may show the dashboard. A leading `www.` makes no difference.

The key never reaches the browser. Each time an admin opens the page, the plugin’s server sends the key and the admin’s origin to Runlight and gets back a ticket that opens the dashboard once, within five minutes. The page loads the dashboard from your Runlight in a frame that only this admin may show. The frame keeps its session in the page for an hour, without cookies, so browsers that block cookies in frames still show it. Once the hour is up, the frame says so and reloads the page when asked. Deleting the key in Runlight’s **Settings**, **API and AI** stops it and every open session at once. Only people who can manage options, administrators by default see the page. Your Runlight must be served over HTTPS when wp-admin is, or the browser refuses the frame.

## Page caches

Some caching plugins serve pages straight from the web server without running PHP, such as WP Super Cache in its expert mode. Those pages still include the script, so visits are counted. WordPress never runs for those requests, so AI agent fetches of cached pages are not reported. Caches that run through PHP, such as WP Rocket and most host-level caches, report agent fetches as usual.
