---
title: Craft CMS
description: Count a Craft CMS site with Runlight, and see when AI agents read it.
group: Platforms
order: 15
---

The Runlight plugin connects a Craft 5 site to a Runlight you run elsewhere: an app with Runlight mounted, or the standalone server. Craft keeps nothing but the plugin’s settings; the numbers live in your Runlight.

## What it does

- Adds Runlight’s script to every front-end page, and marks 404 pages.
- Leaves out Control Panel users’ own visits (you can turn that off).
- Reports AI agents such as ChatGPT, Claude, and Perplexity when they fetch your pages, once the response has been sent.
- Adds a Runlight item to the Control Panel that opens your dashboard.

## Set it up

1. Install the plugin: `composer require runlight/craft`, then `php craft plugin/install runlight`.
2. In your Runlight, make sure the site’s hostname is counted (see [Configuration](/docs/configuration/#sites)).
3. Go to Settings, Plugins, Runlight, and enter the address Runlight is mounted at, such as `https://stats.example.com/runlight`. The page checks that it answers.
4. To count AI agents, set `RUNLIGHT_OBSERVE_KEY` on your Runlight, put the same key in Craft’s `.env`, and enter `$RUNLIGHT_OBSERVE_KEY` as the observe key, so the key stays out of project config.

Every setting can also come from `config/runlight.php`, which wins over the Control Panel, as with any Craft plugin:

```php
<?php
return [
    'address' => 'https://stats.example.com/runlight',
    'observeKey' => '$RUNLIGHT_OBSERVE_KEY',
];
```

## Static caching

Static caches that serve pages without running Craft (Blitz with server rewrites, for instance) still show the script, so visits are counted, but AI agent fetches of those cached pages are not reported.
