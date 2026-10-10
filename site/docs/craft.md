---
title: Craft CMS
description: Count a Craft CMS site with Runlight, and see when AI agents read it.
group: Platforms
order: 17
---

The Runlight plugin connects a Craft 5 site to a Runlight you run elsewhere, either in an app with Runlight mounted or on the standalone server. The numbers live in your Runlight, and Craft stores only the plugin’s settings.

## What it does

- It adds Runlight’s script to every front-end page. On a page Craft answers with a 404, the script also records an event named 404 with the missing page’s path, so the properties of 404 in the Events box list the broken addresses people reached and how often.
- It leaves out Control Panel users’ own visits unless you turn that off.
- It reports AI agents such as ChatGPT and Claude when they fetch your pages, after the response has been sent.
- It adds a Runlight item to the Control Panel that shows this site’s dashboard there.

## Set it up

1. Install the plugin by running `composer require runlight/craft` and then `php craft plugin/install runlight`.
2. In your Runlight, make sure the site is counted. On the standalone server, add it from the site menu, and in an app, add its hostname to `hostnames` (see [Configuration](/docs/configuration/#sites)).
3. Go to Settings, Plugins, Runlight, and enter the address Runlight answers at, such as `https://example.com/runlight` for an app with Runlight mounted, or `https://stats.example.com` for the standalone server. The page checks that the address answers.
4. To count AI agents, copy this site’s key from **Settings**, **Install**, **Key for CMS plugins** in Runlight and put it in Craft’s `.env` as `RUNLIGHT_OBSERVE_KEY`. Then enter `$RUNLIGHT_OBSERVE_KEY` as the observe key, which keeps the key itself out of project config. The key can only report agent fetches for this one site.

As with any Craft plugin, every setting can also come from `config/runlight.php`, and values there override the Control Panel.

```php
<?php
return [
    'address' => 'https://stats.example.com',
    'observeKey' => '$RUNLIGHT_OBSERVE_KEY',
    'dashboardKey' => '$RUNLIGHT_DASHBOARD_KEY',
];
```

## The dashboard in the Control Panel

With a dashboard key, the Runlight item shows this site’s dashboard in the Control Panel. It is the same read-only view a share link shows, with its reports and date ranges and none of Runlight’s settings, short links, people, or other sites. The **Open in Runlight** button opens the full dashboard in your own Runlight.

1. In Runlight, open **Settings**, **Install** for this site and choose **Make a key** under **Key for the dashboard in your CMS**. Copy the key, which Runlight shows only once.
2. Put it in Craft’s `.env` as `RUNLIGHT_DASHBOARD_KEY`, and enter `$RUNLIGHT_DASHBOARD_KEY` as the dashboard key under Settings, Plugins, Runlight, which keeps the key itself out of project config.
3. Make sure the address the Control Panel is served from is among the site’s domains in Runlight, since only an admin page on one of them may show the dashboard. A leading `www.` makes no difference.

The key never reaches the browser. Each time an admin opens the page, the plugin’s server sends the key and the admin’s origin to Runlight and gets back a ticket that opens the dashboard once, within five minutes. The page loads the dashboard from your Runlight in a frame that only this admin may show. The frame keeps its session in the page for an hour, without cookies, so browsers that block cookies in frames still show it. Once the hour is up, the frame says so and reloads the page when asked. Deleting the key in Runlight’s **Settings**, **API and AI** stops it and every open session at once. Only people who can access the Runlight plugin, admins included, see the page. Your Runlight must be served over HTTPS when the Control Panel is, or the browser refuses the frame.

## Static caching

Static caches such as Blitz with server rewrites serve pages without running Craft. Those pages still include the script, so visits are counted. AI agent fetches of the cached pages are not reported, because Craft never runs for them.
