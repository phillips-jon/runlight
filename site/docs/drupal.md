---
title: Drupal
description: Count a Drupal site with Runlight, and see when AI agents read it.
group: Platforms
order: 15
---

The Runlight module connects a Drupal 10.3 or 11 site to a Runlight you run elsewhere: an app with Runlight mounted, or the standalone server. Drupal keeps nothing but the module’s settings; the numbers live in your Runlight.

## What it does

- Adds Runlight’s script to every page outside the admin theme, and marks 404 pages.
- Leaves out the visits of people who can administer Runlight (you can turn that off).
- Reports AI agents such as ChatGPT, Claude, and Perplexity when they fetch your pages, including pages Drupal’s page cache answers. The report is sent after the response has gone out, so the page is never slowed down.
- Adds Reports, Runlight, which opens your dashboard.

## Set it up

1. Install the module (`composer require runlight/drupal`, or place it in `modules/custom/runlight`) and enable it: `drush pm:install runlight`.
2. In your Runlight, make sure the site’s hostname is counted (see [Configuration](/docs/configuration/#sites)).
3. Go to Configuration, System, Runlight, and enter the address Runlight is mounted at, such as `https://stats.example.com/runlight`. The page checks that it answers.
4. To count AI agents, set `RUNLIGHT_OBSERVE_KEY` on your Runlight and enter the same key here. The key can report agent fetches and nothing else.

Settings are configuration, so they export with `drush config:export`. To keep the observe key out of exported config, set it in `settings.php` instead:

```php
$config['runlight.settings']['observe_key'] = getenv('RUNLIGHT_OBSERVE_KEY');
```
