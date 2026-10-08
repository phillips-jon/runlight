---
title: Drupal
description: Count a Drupal site with Runlight, and see when AI agents read it.
group: Platforms
order: 15
---

The Runlight module connects a Drupal 10.3 or 11 site to a Runlight you run elsewhere, either in an app with Runlight mounted or on the standalone server. The numbers live in your Runlight, and Drupal stores only the module’s settings.

## What it does

- It adds Runlight’s script to every page outside the admin theme and marks 404 pages.
- It leaves out the visits of people who can administer Runlight unless you turn that off.
- It reports AI agents such as ChatGPT and Claude when they fetch your pages, including pages that Drupal’s page cache answers. The report goes out after the response has been sent, so the page is never slowed down.
- It adds a Runlight item under Reports that opens your dashboard.

## Set it up

1. Install the module (`composer require runlight/drupal`, or place it in `modules/custom/runlight`) and enable it with `drush pm:install runlight`.
2. In your Runlight, make sure the site’s hostname is counted (see [Configuration](/docs/configuration/#sites)).
3. Go to Configuration, System, Runlight, and enter the address Runlight is mounted at, such as `https://stats.example.com/runlight`. The page checks that the address answers.
4. To count AI agents, copy this site’s key from **Settings**, **Install**, **Key for CMS plugins** in Runlight and enter it here. The key can only report agent fetches for this one site.

The module’s settings are Drupal configuration, so `drush config:export` exports them. To keep the observe key out of exported config, set it in `settings.php` instead.

```php
$config['runlight.settings']['observe_key'] = getenv('RUNLIGHT_OBSERVE_KEY');
```
