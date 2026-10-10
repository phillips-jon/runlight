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
docker run -d --name runlight -p 3000:3000 -v runlight:/data ghcr.io/runlightsh/runlight
```

## Packages

Runlight is written again for eight more languages. Each one serves the same dashboard and reads and writes the same tables, so any of them can read a database another one wrote.

| Language | Install | Docs |
| --- | --- | --- |
| TypeScript and JavaScript | `npm install @runlight/sdk better-sqlite3` (Node 22 or later, Bun, Deno, or Cloudflare Workers) | [Getting started](https://runlight.sh/docs/), [Install](https://runlight.sh/docs/install/), [its README](packages/sdk/README.md) |
| Standalone server | `npx runlight.sh`, or the Docker image above | [Standalone server](https://runlight.sh/docs/server/), [its README](packages/server/README.md) |
| PHP | `composer require runlight/runlight` (PHP 8.2 or later), with a drop-in for a domain of its own | [PHP](https://runlight.sh/docs/php/), [its README](packages/php/README.md) |
| WordPress | `wp plugin install runlight --activate`, or search for Runlight under Plugins, Add New | [WordPress](https://runlight.sh/docs/wordpress/) |
| Drupal | `composer require drupal/runlight`, then `drush pm:install runlight` (Drupal 10.3 or 11) | [Drupal](https://runlight.sh/docs/drupal/) |
| Craft CMS | `composer require runlight/craft`, then `php craft plugin/install runlight` (Craft 5) | [Craft CMS](https://runlight.sh/docs/craft/) |
| Python | `pip install runlight` (Python 3.11 or later), with the `postgres` or `mysql` extra for those databases | [Python](https://runlight.sh/docs/python/), [its README](packages/python/README.md) |
| Rails | `bundle add runlight`, then `bin/rails generate runlight:install` and `bin/rails db:migrate` (Rails 7.2, 8.0, or 8.1) | [Rails](https://runlight.sh/docs/rails/), [its README](packages/ruby/README.md) |
| Ruby | `bundle add runlight sqlite3` (Ruby 3.2 or later), or `pg`, `trilogy`, or `mysql2` in place of `sqlite3` | [Ruby](https://runlight.sh/docs/ruby/), [its README](packages/ruby/README.md) |
| Go | `go get runlight.sh/go` (Go 1.25 or later) and a `database/sql` driver, with `runlight.sh/go/chi` or `runlight.sh/go/echo` for those routers | [Go](https://runlight.sh/docs/go/), [its README](packages/go/README.md) |
| Java | `sh.runlight:runlight` from Maven Central (Java 21 or later), with `sh.runlight:runlight-servlet` or `sh.runlight:runlight-spring-boot-starter` beside it at the same version and the app's JDBC driver | [Java](https://runlight.sh/docs/java/), [its README](packages/java/README.md) |
| .NET | `dotnet add package Runlight.AspNetCore` (.NET 10 or later) and the app's ADO.NET driver, or `dotnet tool install --global Runlight.Server` for the standalone server | [.NET](https://runlight.sh/docs/dotnet/), [its README](packages/dotnet/README.md) |
| Elixir | `{:runlight, "~> 0.0"}` in `mix.exs` (Elixir 1.18 or later on Erlang/OTP 27 or later), with the app's Ecto adapter | [Elixir](https://runlight.sh/docs/elixir/), [its README](packages/elixir/README.md) |
| Rust | `cargo add runlight --features axum` and `cargo add runlight-sqlx --features sqlite` (or `postgres`, `mysql`), on Rust 1.88 or later and 1.94 for `runlight-sqlx` | [Rust](https://runlight.sh/docs/rust/), [its README](packages/rust/README.md) |

The plugins for WordPress, Drupal, and Craft add the script to a CMS site and report AI agents that read its pages to a Runlight you run elsewhere. Each one has its own folder under `plugins/`.

## What it does

Beyond visitors and pages, Runlight counts goals and the revenue they bring, funnels, and the paths visits take through a site. It makes short links on your own domains and counts their clicks. It emails weekly or monthly reports and shares a read-only dashboard by link. An assistant in the dashboard, or an MCP server for AI apps, answers questions about your numbers.

## This repository

| Folder | What is in it |
| --- | --- |
| `packages/sdk` | The library, published as `@runlight/sdk`. |
| `packages/server` | The standalone server, published as `runlight.sh`. |
| `packages/php`, `packages/python`, `packages/ruby`, `packages/go`, `packages/java`, `packages/dotnet`, `packages/elixir`, `packages/rust` | The library written again in each of those languages, published as the table above shows. |
| `conformance` | The recorded answers every implementation is tested against. |
| `packages/dashboard` | The dashboard, built into the library. |
| `packages/tracker` | The browser script, built into the library. |
| `plugins` | The WordPress, Drupal, and Craft plugins. |
| `site` | runlight.sh and its documentation. |

Use Node 24 to work on it, and run `npm run check` before committing.

## Releasing

The library, the server, every other language's package, and the WordPress plugin share one version. The Drupal and Craft plugins take theirs from the release tag. Write the release's notes under `## Unreleased` in `CHANGELOG.md` (and in the Craft plugin's `CHANGELOG.md` and the WordPress readme's `= Unreleased =` section when they changed), then release from a clean `main`.

```bash
npm run release -- X.Y.Z --dry-run   # show every change and command, write nothing
npm run release -- X.Y.Z             # bump, check, commit "Release X.Y.Z", tag vX.Y.Z
```

The script bumps every file listed in `VERSIONED` at the top of `scripts/release.mjs`, dates the changelogs' Unreleased sections, and lists any other tracked file that still names the old version. It refreshes `package-lock.json` and `packages/php/assets`, runs `npm run check` and the build, builds the WordPress zip, and installs the packed npm packages in a scratch project to load every entry point and run `runlight.sh --version`. Set `RUNLIGHT_TEST_PG` and `RUNLIGHT_TEST_MYSQL` first so the check covers both databases. A new folder under `packages/` or `plugins/` needs a row in the script's tables, or the script refuses to run.

It never pushes or publishes. It prints what to run next, which is `git push origin main vX.Y.Z` and then `npm publish` for `@runlight/sdk` and `runlight.sh`, in that order, once CI has passed. The tag starts the workflows below, and each one waits for CI to pass on the tagged commit (`ci-passed.yml`) and does nothing until its switch is set.

| Workflow | What it does | Switch |
| --- | --- | --- |
| `docker.yml` | Builds the server's image for amd64 and arm64 and pushes it to `ghcr.io/runlightsh/runlight` | `DOCKER_ENABLED` variable |
| `release.yml` | Makes the GitHub release from the changelog and attaches the WordPress zip as `runlight.zip` | `RELEASE_ENABLED` variable |
| `php-split.yml` | Pushes `packages/php` and the tag to `runlightsh/runlight-php` for Packagist | `PHP_SPLIT_DEPLOY_KEY` secret |
| `php-plugins-split.yml` | Pushes the Drupal module to drupal.org and the Craft plugin to `runlightsh/runlight-craft` | `DRUPAL_SPLIT_ENABLED` and `CRAFT_SPLIT_ENABLED` variables |
| `pypi.yml` | Builds `packages/python` and publishes it to PyPI as `runlight` with trusted publishing | `PYPI_ENABLED` variable |
| `hex.yml` | Publishes `packages/elixir` to Hex as `runlight`, with its docs on HexDocs | `HEX_ENABLED` variable and `HEX_API_KEY` secret |
| `maven.yml` | Builds, signs, and publishes `sh.runlight:runlight`, `runlight-servlet`, and `runlight-spring-boot-starter` to Maven Central through the Central Publisher Portal | `MAVEN_ENABLED` variable, with the Portal token and the GPG key as secrets |
| `nuget.yml` | Packs `Runlight`, `Runlight.AspNetCore`, and `Runlight.Server` and publishes them to nuget.org in that order with trusted publishing | `NUGET_ENABLED` variable |
| `crates.yml` | Publishes the `runlight` crate and then `runlight-sqlx` to crates.io with trusted publishing | `CRATES_ENABLED` variable |

The PyPI, NuGet, and crates.io workflows publish from a GitHub environment of the same name, so a required reviewer there makes each publish wait for a click. Each workflow's header says what to set up first. crates.io trusts a workflow only for a crate that already exists, so the first Rust release is published by hand with `cargo publish --workspace` in `packages/rust`.

Two languages ship from the commands the script prints. The Ruby gem is built and pushed by hand with `gem build runlight.gemspec` and `gem push runlight-X.Y.Z.gem` in `packages/ruby`. Go modules are versioned by tags, so the release commit also gets `packages/go/vX.Y.Z` and a tag of the same form for each of the `chi`, `echo`, and `cmd/runlight` modules. Once those are pushed, `go list -m` against `proxy.golang.org` makes the Go proxy fetch them, and `runlight.sh` answers the go command's lookups for `runlight.sh/go`.

After the Drupal split, make the release on drupal.org from the pushed tag.

Runlight is MIT licensed.
