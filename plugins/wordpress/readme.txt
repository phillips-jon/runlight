=== Runlight ===
Contributors: joncphillips
Tags: analytics, privacy, statistics, ai, cookieless
Requires at least: 6.3
Tested up to: 7.1
Requires PHP: 8.1
Stable tag: 0.1.0
License: GPLv2 or later
License URI: https://www.gnu.org/licenses/gpl-2.0.html

Privacy friendly analytics with no cookies, kept in your own database. Adds Runlight to every page and reports AI agents that read your site.

== Description ==

[Runlight](https://runlight.sh/) is open source web analytics that runs in your own app or on your own server and keeps every number in your own database. It counts visitors, pages, sources, places, devices, campaigns, and conversions without cookies and without keeping anything that could say who a visitor was, so there is no cookie banner to add.

This plugin connects a WordPress site to your Runlight:

* It adds Runlight's script (under 2 KB) to every page, and marks 404 pages so broken links show up.
* It leaves out administrators' own visits, if you want.
* It reports AI agents such as ChatGPT, Claude, and Perplexity when they fetch your pages to answer someone's question. They run no JavaScript, so no script can see them; the plugin tells Runlight from the server, without slowing the page down.
* It adds a Runlight item to the admin menu that opens your dashboard.

The numbers live in your Runlight, not in WordPress, so the plugin adds no tables and nothing to your database but its one setting.

= What you need =

A Runlight to send to: an app with Runlight mounted, or the standalone server. See [runlight.sh/docs/wordpress](https://runlight.sh/docs/wordpress/).

= Privacy =

The script sets no cookies and stores nothing in the visitor's browser. Runlight counts a visitor with a hash of a daily salt, your site, their IP address, and their user agent; the address and the user agent are never stored, and the salt is deleted after a day. When an AI agent fetches a page, the plugin sends that page's address and the agent's user agent to your Runlight, and nothing else.

== Installation ==

1. Install and activate the plugin.
2. Go to Settings, Runlight, and enter your Runlight's address, such as `https://stats.example.com/runlight`. The page checks that it answers.
3. Make sure that Runlight counts this site's hostname.
4. To count AI agents, set `RUNLIGHT_OBSERVE_KEY` on your Runlight and enter the same key here.

== Frequently Asked Questions ==

= Does this send my visitors' data to a third party? =

No. It sends to your own Runlight, wherever you run it, and nowhere else.

= Do I need a cookie banner? =

Not for Runlight: it sets no cookies and stores nothing on the visitor's device.

= Where are the numbers? =

In your Runlight's dashboard. The Runlight item in the admin menu opens it.

== Changelog ==

= 0.1.0 =
* First release: the script, administrators left out, 404s marked, AI agents reported, and a link to the dashboard.
