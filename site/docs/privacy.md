---
title: Privacy
description: Exactly what Runlight stores, what it never stores, and why that keeps you clear of cookie banners.
group: Trust
order: 12
---

Runlight is built so that it never needs to know who anyone is.

## How visitors are counted

Each day Runlight makes a new random salt. A visitor is the SHA-256 hash of that salt, your site, the visitor’s IP address, and their browser’s user agent, cut to 64 bits. The same person on the same day gets the same value, which is how visitors and visits are counted. Tomorrow they get a different one.

Salts older than yesterday are deleted. Without the salt the hash cannot be recomputed or reversed, so after a day nobody, you included, can tell whether two visits came from the same person.

## What is stored

For each visit: the hashed visitor, when it started and ended, the pages viewed, engaged time and scroll depth, the referring site and source, UTM tags, country, region and city, browser and version, operating system and version, device type, screen size, and language. For each event: its name and the properties you chose to send.

## What is never stored

- IP addresses. They are used to make the daily hash and, where needed, to look up a country, then dropped.
- User agents. They are read for the browser, operating system, and device, then dropped.
- Cookies or anything in the visitor’s browser. The script stores nothing, except an opt-out flag you can set for your own browser.
- Any identifier that lasts longer than a day.

## The law

Runlight is designed so that a site using it needs no cookie consent: it stores nothing on the visitor’s device, and what it keeps cannot be tied back to a person, which is what keeps it outside the GDPR’s idea of personal data. Being self-hosted, it also never sends your visitors’ data to anyone else: it stays in your database, on your servers.

This is how Runlight works, not legal advice. If you add properties to your events, keep personal details such as email addresses out of them.

## Your own data

You own the database. Back it up, query it, or delete it like any other. Short link clicks and email report recipients live there too; a report recipient can unsubscribe from any email.
