---
title: Drupal
description: Count a Drupal site with Runlight, and see when AI agents read it.
group: Platforms
order: 16
---

The Runlight module connects a Drupal 10.3 or 11 site to a Runlight you run elsewhere, either in an app with Runlight mounted or on the standalone server. The numbers live in your Runlight, and Drupal stores only the module’s settings.

## What it does

- It adds Runlight’s script to every page outside the admin theme. On a page Drupal answers with a 404, the script also records an event named 404 with the missing page’s path, so the properties of 404 in the Events box list the broken addresses people reached and how often.
- It leaves out the visits of people who can administer Runlight unless you turn that off.
- It reports AI agents such as ChatGPT and Claude when they fetch your pages, including pages that Drupal’s page cache answers. The report goes out after the response has been sent, so the page is never slowed down.
- It adds a Runlight item under Reports that shows this site’s dashboard in the admin.

## Set it up

1. Install the module (`composer require drupal/runlight`, or place it in `modules/custom/runlight`) and enable it with `drush pm:install runlight`.
2. In your Runlight, make sure the site is counted. On the standalone server, add it from the site menu, and in an app, add its hostname to `hostnames` (see [Configuration](/docs/configuration/#sites)).
3. Go to Configuration, System, Runlight, and enter the address Runlight answers at, such as `https://example.com/runlight` for an app with Runlight mounted, or `https://stats.example.com` for the standalone server. The page checks that the address answers.
4. To count AI agents, copy this site’s key from **Settings**, **Install**, **Key for CMS plugins** in Runlight and enter it here. The key can only report agent fetches for this one site.

The module’s settings are Drupal configuration, so `drush config:export` exports them. To keep the keys out of exported config, set them in `settings.php` instead.

```php
$config['runlight.settings']['observe_key'] = getenv('RUNLIGHT_OBSERVE_KEY');
$config['runlight.settings']['dashboard_key'] = getenv('RUNLIGHT_DASHBOARD_KEY');
```

## The dashboard in the admin

With a dashboard key, the Reports, Runlight page shows this site’s dashboard in the admin. It is the same read-only view a share link shows, with its reports and date ranges and none of Runlight’s settings, short links, people, or other sites. The **Open in Runlight** button opens the full dashboard in your own Runlight.

1. In Runlight, open **Settings**, **Install** for this site and choose **Make a key** under **Key for the dashboard in your CMS**. Copy the key, which Runlight shows only once.
2. Enter it as the dashboard key on Configuration, System, Runlight.
3. Make sure the address the admin is served from is among the site’s domains in Runlight, since only an admin page on one of them may show the dashboard. A leading `www.` makes no difference.

The key never reaches the browser. Each time an admin opens the page, the module’s server sends the key and the admin’s origin to Runlight and gets back a ticket that opens the dashboard once, within five minutes. The page loads the dashboard from your Runlight in a frame that only this admin may show. The frame keeps its session in the page for an hour, without cookies, so browsers that block cookies in frames still show it. Once the hour is up, the frame says so and reloads the page when asked. Deleting the key in Runlight’s **Settings**, **API and AI** stops it and every open session at once. Only people who have the Administer Runlight permission see the page. Your Runlight must be served over HTTPS when the admin is, or the browser refuses the frame.

When Gin is the admin theme, the frame follows its dark mode setting. With Claro it stays light.
