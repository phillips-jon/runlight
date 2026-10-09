# Runlight

Runlight is privacy friendly web analytics that you run yourself. It counts visitors without cookies and without storing anyone’s IP address, so there is no consent banner to show. The numbers stay in your own database, and the dashboard is served from your own domain.

Documentation is at [runlight.sh/docs](https://runlight.sh/docs/).

## Two ways to run it

The library, `@runlight/sdk`, runs inside an app you already have. You mount its routes, add one script tag, and read your stats at `/runlight`. It works with Next.js, Nuxt, SvelteKit, Astro, Remix, Express, NestJS, Fastify, Koa, Hono, and anything else that handles a web `Request`, on Node 22 or later, Bun, Deno, or Cloudflare Workers. It stores its data in SQLite, Postgres, MySQL, MariaDB, Turso, or Cloudflare D1.

```bash
npm install @runlight/sdk better-sqlite3
```

The standalone server, `runlight.sh`, is the same code packaged as an app of its own. It suits sites that are not Node apps, and it gives any number of sites one dashboard with sign-in for the people you invite.

```bash
npx runlight.sh
```

It also runs in Docker.

```bash
docker run -d --name runlight -p 3000:3000 -v runlight:/data ghcr.io/phillips-jon/runlight
```

## Plugins

Plugins for WordPress, Drupal, and Craft add the script to a CMS site and report AI agents that read its pages to a Runlight you run elsewhere. Each one has its own folder under `plugins/`.

## What it does

Beyond visitors and pages, Runlight counts goals and the revenue they bring, funnels, and the paths visits take through a site. It makes short links on your own domains and counts their clicks. It emails weekly or monthly reports and shares a read-only dashboard by link. An assistant in the dashboard, or an MCP server for AI apps, answers questions about your numbers.

## This repository

| Folder | What is in it |
| --- | --- |
| `packages/sdk` | The library, published as `@runlight/sdk`. |
| `packages/server` | The standalone server, published as `runlight.sh`. |
| `packages/dashboard` | The dashboard, built into the library. |
| `packages/tracker` | The browser script, built into the library. |
| `plugins` | The WordPress, Drupal, and Craft plugins. |
| `site` | runlight.sh and its documentation. |

Use Node 24 to work on it, and run `npm run check` before committing.

## Releasing

The library, the server, the PHP package, and the WordPress plugin share one version. The Drupal and Craft plugins take theirs from the release tag. Write the release's notes under `## Unreleased` in `CHANGELOG.md` (and in the Craft plugin's `CHANGELOG.md` and the WordPress readme's `= Unreleased =` section when they changed), then release from a clean `main`.

```bash
npm run release -- X.Y.Z --dry-run   # show every change and command, write nothing
npm run release -- X.Y.Z             # bump, check, commit "Release X.Y.Z", tag vX.Y.Z
```

The script bumps every file listed in `VERSIONED` at the top of `scripts/release.mjs`, dates the changelogs' Unreleased sections, and lists any other tracked file that still names the old version. It refreshes `package-lock.json` and `packages/php/assets`, runs `npm run check` and the build, builds the WordPress zip, and installs the packed npm packages in a scratch project to load every entry point and run `runlight.sh --version`. Set `RUNLIGHT_TEST_PG` and `RUNLIGHT_TEST_MYSQL` first so the check covers both databases. A new folder under `packages/` or `plugins/` needs a row in the script's tables, or the script refuses to run.

It never pushes or publishes. It prints what to run next, which is `git push origin main vX.Y.Z` and then `npm publish` for `@runlight/sdk` and `runlight.sh`, in that order, once CI has passed. The tag starts the workflows below, and each one waits for CI to pass on the tagged commit (`ci-passed.yml`) and does nothing until its switch is set.

| Workflow | What it does | Switch |
| --- | --- | --- |
| `docker.yml` | Builds the server's image for amd64 and arm64 and pushes it to `ghcr.io/phillips-jon/runlight` | `DOCKER_ENABLED` variable |
| `release.yml` | Makes the GitHub release from the changelog and attaches the WordPress zip as `runlight.zip` | `RELEASE_ENABLED` variable |
| `php-split.yml` | Pushes `packages/php` and the tag to `phillips-jon/runlight-php` for Packagist | `PHP_SPLIT_DEPLOY_KEY` secret |
| `php-plugins-split.yml` | Pushes the Drupal module to drupal.org and the Craft plugin to `phillips-jon/runlight-craft` | `DRUPAL_SPLIT_ENABLED` and `CRAFT_SPLIT_ENABLED` variables |

After the Drupal split, make the release on drupal.org from the pushed tag.

Runlight is MIT licensed.
