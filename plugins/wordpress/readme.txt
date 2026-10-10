=== Runlight ===
Contributors: joncphillips
Tags: analytics, privacy, statistics, ai, cookieless
Requires at least: 6.3
Tested up to: 7.1
Requires PHP: 8.1
Stable tag: 0.0.0
License: GPLv2 or later
License URI: https://www.gnu.org/licenses/gpl-2.0.html

Privacy friendly analytics with no cookies, kept in your own database. Adds Runlight to every page and reports AI agents that read your site.

== Description ==

[Runlight](https://runlight.sh/) is open source web analytics that runs in your own app or on your own server and keeps every number in your own database. It counts visitors, pages, sources, places, devices, campaigns, and conversions without cookies and without keeping anything that could say who a visitor was, so there is no cookie banner to add.

This plugin connects a WordPress site to your Runlight:

* It adds Runlight's script (under 2 KB) to every page, and marks 404 pages so broken links show up.
* It leaves out administrators' own visits, if you want.
* It reports AI agents such as ChatGPT, Claude, and Perplexity when they fetch your pages to answer someone's question. They run no JavaScript, so no script can see them; the plugin tells Runlight from the server, without slowing the page down.
* It adds a Runlight item to the admin menu that shows this site's dashboard right in wp-admin, read-only, with a link to open it in your Runlight.

The numbers live in your Runlight, not in WordPress, so the plugin adds no tables and nothing to your database but its one setting.

= What you need =

A Runlight to send to: an app with Runlight mounted, or the standalone server. See [runlight.sh/docs/wordpress](https://runlight.sh/docs/wordpress/).

= Privacy =

The script sets no cookies and stores nothing in the visitor's browser. Runlight counts a visitor with a hash of a daily salt, your site, their IP address, and their user agent; the address and the user agent are never stored, and the salt is deleted after a day. When an AI agent fetches a page, the plugin sends that page's address and the agent's user agent to your Runlight, and nothing else.

== Installation ==

1. Install and activate the plugin.
2. Go to Settings, Runlight, and enter the address your Runlight answers at, such as `https://example.com/runlight` for an app with Runlight mounted, or `https://stats.example.com` for the standalone server. The page checks that it answers.
3. Make sure that Runlight counts this site's hostname.
4. To count AI agents, copy this site's key from Settings, Install, Key for CMS plugins in your Runlight and enter it here. The key can only report AI agent fetches for this one site.
5. To see the numbers in wp-admin, make a key under Settings, Install, Key for the dashboard in your CMS in your Runlight and enter it as the dashboard key. That Runlight must list this site's hostname among the site's domains, since only an admin on one of them may show its dashboard.

== Frequently Asked Questions ==

= Does this send my visitors' data to a third party? =

No. It sends to your own Runlight, wherever you run it, and nowhere else.

= Do I need a cookie banner? =

Not for Runlight: it sets no cookies and stores nothing on the visitor's device.

= Where are the numbers? =

In your Runlight. With a dashboard key, the Runlight item in the admin menu shows them in wp-admin, and its Open in Runlight button opens the full dashboard.

== External services ==

The plugin talks to one service, the Runlight whose address you enter under Settings, Runlight. You run that Runlight yourself, in your own app or on your own server, and nothing is sent until you enter its address. Runlight is open source software under the MIT licence, and its terms of use and privacy policy are at https://runlight.sh/terms/ and https://runlight.sh/privacy/.

* Every page loads Runlight's script from that address. In the visitor's browser, the script sends the page's address, the referring page, the screen size, the browser's language, the page's title, how long it was read, and how far down it was scrolled, with any events you set up. Runlight uses the visitor's IP address and user agent to work out a daily visitor count and never stores them.
* When an AI agent such as ChatGPT or Claude fetches a page and you have entered a key, the plugin sends that page's address and the agent's user agent to the same Runlight, from your server.
* When you save the settings, the plugin asks that address whether it answers as Runlight, to tell you whether it is connected.
* When an administrator opens the Runlight page in wp-admin and you have entered a dashboard key, the plugin sends that key and the address wp-admin is served from (its scheme, host, and port) to the same Runlight, from your server, and gets back a ticket that opens the dashboard once. The page then loads the dashboard from that Runlight in a frame, in the administrator's browser. The frame reads this site's numbers from that Runlight and keeps its session in the page, with no cookies.

== Changelog ==

= Unreleased =
* First release: the script, administrators left out, 404s marked, AI agents reported, and the dashboard in wp-admin.
