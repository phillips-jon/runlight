---
title: Ruby
description: Runlight runs in Ruby 3.2 or later, inside a Rack app such as Sinatra, Hanami, or Roda, or on a domain of its own as a standalone server.
group: Platforms
order: 17.3
---

The Ruby gem is Runlight written again in Ruby. It serves the same dashboard and API, and it gives every request the answer the TypeScript library gives. Its numbers go in the same tables, so either one can read a database the other wrote. It needs Ruby 3.2 or later, and it keeps its data through ActiveRecord, which it brings with it. For a Rails app, the [Rails guide](/docs/rails/) has an engine and a generator that do the setup for you.

## Install

Add the gem with the driver for your database.

```bash
bundle add runlight sqlite3
```

Use `pg` for Postgres, or `trilogy` or `mysql2` for MySQL and MariaDB, in place of `sqlite3`.

## Create the instance

Make one instance when the app starts and share it.

```ruby file=runlight.rb
require "runlight"

RL = Runlight.new(
  store: Runlight::Stores.sqlite("data/runlight.db"),
  site: { name: "example.com", hostnames: ["example.com"], timezone: "Europe/London" },
)
```

The options have the names in [Configuration](/docs/configuration/#runlight-options), written in snake case, so `sites`, `trust_proxy`, `rate_limit`, `mail`, and `managed_sites` all work as they do there. The tables are created on the first request.

## Stores

### SQLite

```ruby
Runlight::Stores.sqlite("data/runlight.db")
```

Keep the file outside any folder the web server serves. The folder is made when it is missing, and the database runs in WAL mode, so several processes can share it.

### MySQL and MariaDB

```ruby
Runlight::Stores.mysql("mysql://runlight:password@127.0.0.1:3306/runlight")
```

This store works with MySQL 8.4 or later and MariaDB 11.4 or later, through the `trilogy` gem when it is installed and `mysql2` otherwise. A `mariadb://` URL works too. `statement_timeout: 30_000` stops any one query after that many milliseconds, and the default is 120000, as in [Configuration](/docs/configuration/#mysql-and-mariadb).

### Postgres

```ruby
Runlight::Stores.postgres("postgres://runlight:password@127.0.0.1:5432/runlight")
```

This store needs the `pg` gem. It takes `statement_timeout:` too, and `schema: "analytics"` keeps the tables in a schema of their own. `Runlight::Stores.url` picks the store from a `DATABASE_URL` that starts with `postgres://`, `mysql://`, `mariadb://`, or `sqlite:`.

### An app's own ActiveRecord database

```ruby
Runlight::Stores.active_record
```

This store keeps Runlight's tables in the database the app's ActiveRecord already connects to, next to the app's own tables. Pass an abstract model class, such as `Runlight::Stores.active_record(AnalyticsRecord)`, to use another of the app's databases. Its writes join a transaction the app has open.

## Rack apps

Put Runlight in front of the app in `config.ru`.

```ruby file=config.ru
require_relative "runlight"
require_relative "app"

use Runlight::RackApp, runlight: RL, base_path: "/runlight"
run App
```

Runlight answers the paths under `/runlight`, the short links at `/go`, and any [link domain](/docs/links/) you add in Settings, and passes every other request to the app. It also records the fetches of [AI agents](/docs/ai/#agents-that-read-your-pages) on the way past, which takes no time for anyone else. Runlight checks its own requests, so it goes before any CSRF middleware. Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes. With `accounts: true` in the options and a `RUNLIGHT_SECRET`, people sign in with their own email and password, as in [Accounts](/docs/configuration/#accounts). Pass `token:` to set the token in code, where an empty string keeps the dashboard closed and `nil` leaves it open to everyone.

`RL.rack_app(base_path: "/runlight")` is the same app with nothing behind it, for a `config.ru` that mounts it at a path of its own with `map`.

## The scheduled check

The [scheduled check](/docs/cron/) sends email reports and keeps the data tidy. Call it every few minutes from cron, a job scheduler, or a thread of your own.

```ruby
RL.check
```

When nothing in the app can run it on a timer, set `CRON_SECRET` and have an outside scheduler call `/runlight/api/check` with it, as [Scheduled check](/docs/cron/#anywhere-else) shows.

## The standalone server

The gem's `runlight` command runs Runlight on a domain of its own, such as `stats.example.com`, as the [standalone server](/docs/server/) does. It serves the dashboard at the root, keeps the sites in the dashboard, and has sign-in accounts and short links on any domain you point at it.

```bash
mkdir stats && cd stats
bundle init && bundle add runlight sqlite3 puma
bundle exec runlight serve
```

The server listens on port 3000, or on `PORT`. It runs under Puma when the gem is there and WEBrick otherwise, and the folder's `config.ru` runs it under any other Rack server. The data lives in `runlight-data` in the folder you start it from. On its first start it prints a link with a one-time code that makes the first account, and `bundle exec runlight setup` prints the link again. Roles, invites, two-factor sign-in, and adding sites work as they do on the [standalone server](/docs/server/#make-your-account).

Settings come from the environment variables the [PHP drop-in](/docs/php/#settings) reads, such as `RUNLIGHT_URL`, `DATABASE_URL`, `DATA_DIR`, `RUNLIGHT_SECRET`, `TRUST_PROXY`, and `RUNLIGHT_GEO`, or from a `config.rb` in the folder that returns a Hash with the same names. Environment variables win when both are set. The server runs the scheduled check every five minutes, and `bundle exec runlight cron` runs it from cron for a server that is not always up.

The command's other work is in `bundle exec runlight --help`. `password` gives an account a new password and prints it, `migrate` updates the tables at once, and `agents` reads AI agents from a web server's access log, as the [PHP drop-in's](/docs/php/#ai-agents-from-a-log) does.

## How it differs from the TypeScript library

The Ruby gem passes the conformance tests the TypeScript library is held to, on SQLite, Postgres, MySQL, and MariaDB. The differences come from how Ruby apps run.

- The connection pool is ActiveRecord's. Each store that opens its own database has a pool of five connections a process, and the app's own ActiveRecord pool serves `Runlight::Stores.active_record`.
- What the TypeScript library does in the background, such as deleting visits after a shorter retention is chosen, runs once the answer is sent, when the Rack server closes the answer's body.
- Wrong-password limits are kept in the database, so every process shares them. The tracker's rate limit lives in small files in the system's temporary folder, which every process on one machine shares.
- Email reports format numbers, dates, money, and country names from a copy of the ICU data Node uses, since Ruby carries none.
