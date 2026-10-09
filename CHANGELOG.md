# Changelog

Every notable change to Runlight is listed here, newest first. The library, the standalone server, the PHP package, and the WordPress plugin share one version, so each release is one section here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versions follow [Semantic Versioning](https://semver.org). The WordPress plugin keeps its changelog in its readme, and the Craft plugin keeps one of its own for the Craft Plugin Store.

## Unreleased

This is Runlight's first release.

### Added

- `@runlight/sdk` is privacy friendly web analytics that runs inside an app you already have. It counts visitors without cookies and without storing anyone's IP address, keeps the numbers in your own SQLite, Postgres, MySQL, MariaDB, Turso, or Cloudflare D1 database, and serves its dashboard at `/runlight` on your own domain. It runs on Node 22 or later, Bun, Deno, and Cloudflare Workers.
- `runlight.sh` is the same code as a server of its own, with one dashboard for any number of sites and sign-in for the people you invite. It starts with `npx runlight.sh`, and the Docker image is `ghcr.io/phillips-jon/runlight`.
- `runlight/runlight` is the PHP version of the library, for Laravel, Symfony, or plain PHP on PHP 8.2 or later. It uses the same tables as the TypeScript library, so either one can read the other's database.
- Runlight counts goals and the revenue they bring, funnels, and the paths visits take through a site. It makes short links on your own domains and counts their clicks.
- Runlight emails weekly or monthly reports and shares a read-only dashboard by link.
- An assistant in the dashboard, and an MCP server for AI apps, answer questions about your numbers.
- Plugins for WordPress, Drupal, and Craft CMS add the script to a site and report the AI agents that read its pages to a Runlight you run elsewhere.
