---
title: Craft CMS
description: Count a Craft CMS site with Runlight, and see when AI agents read it.
group: Platforms
order: 16
---

The Runlight plugin connects a Craft 5 site to a Runlight you run elsewhere, either in an app with Runlight mounted or on the standalone server. The numbers live in your Runlight, and Craft stores only the plugin’s settings.

## What it does

- It adds Runlight’s script to every front-end page and marks 404 pages.
- It leaves out Control Panel users’ own visits unless you turn that off.
- It reports AI agents such as ChatGPT and Claude when they fetch your pages, after the response has been sent.
- It adds a Runlight item to the Control Panel that opens your dashboard.

## Set it up

1. Install the plugin by running `composer require runlight/craft` and then `php craft plugin/install runlight`.
2. In your Runlight, make sure the site’s hostname is counted (see [Configuration](/docs/configuration/#sites)).
3. Go to Settings, Plugins, Runlight, and enter the address Runlight is mounted at, such as `https://stats.example.com/runlight`. The page checks that the address answers.
4. To count AI agents, set `RUNLIGHT_OBSERVE_KEY` on your Runlight and put the same key in Craft’s `.env`. Then enter `$RUNLIGHT_OBSERVE_KEY` as the observe key, which keeps the key itself out of project config.

As with any Craft plugin, every setting can also come from `config/runlight.php`, and values there override the Control Panel.

```php
<?php
return [
    'address' => 'https://stats.example.com/runlight',
    'observeKey' => '$RUNLIGHT_OBSERVE_KEY',
];
```

## Static caching

Static caches such as Blitz with server rewrites serve pages without running Craft. Those pages still include the script, so visits are counted. AI agent fetches of the cached pages are not reported, because Craft never runs for them.
