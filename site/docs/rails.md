---
title: Rails
description: Runlight runs inside a Rails 7.2, 8.0, or 8.1 app, with its tables in the app's own database and its dashboard at /runlight.
group: Platforms
order: 17.2
---

The `runlight` gem brings a Rails engine that serves Runlight from your app, with its tables in the app's own database. It is the [Ruby gem](/docs/ruby/), which gives every request the answer the TypeScript library gives, so either one can read a database the other wrote. It works with Rails 7.2, 8.0, and 8.1 on Ruby 3.2 or later, and with SQLite, Postgres, MySQL, or MariaDB.

## Install

Add the gem and run its generator.

```bash
bundle add runlight
bin/rails generate runlight:install
bin/rails db:migrate
```

The generator writes `config/initializers/runlight.rb` and a migration that creates Runlight's tables. Each of their names starts with `rl_`, so they sit beside the app's own. After a gem upgrade Runlight brings them up to date by itself on the first request, and `bin/rails runlight:migrate` does it at once.

## Configure it

The initializer sets up the one Runlight the app shares.

```ruby file=config/initializers/runlight.rb
Runlight.configure(
  store: Runlight::Stores.active_record,
  site: { name: "example.com", hostnames: ["example.com"], timezone: "Europe/London" },
  routes: { base_path: "/runlight", token: ENV.fetch("RUNLIGHT_TOKEN", "") },
)
```

The options have the names in [Configuration](/docs/configuration/#runlight-options), written in snake case, so `sites`, `trust_proxy`, `rate_limit`, `mail`, and `managed_sites` all work as they do there. The ones under `routes` are the dashboard's, such as `accounts: true`, which lets people sign in with their own email and password once `RUNLIGHT_SECRET` is set, as in [Accounts](/docs/configuration/#accounts). An empty token keeps the dashboard closed, and `nil` would leave it open to everyone. To keep the token in the app's credentials, read it with `Rails.application.credentials.runlight_token` there.

`Runlight::Stores.active_record` keeps the tables in the database `ApplicationRecord` connects to. In an app with several databases, pass the abstract class of the one to use, such as `Runlight::Stores.active_record(AnalyticsRecord)`, and run the migration against that database.

## Add the script

Add the script to the layout, just before `</head>`.

```erb file=app/views/layouts/application.html.erb
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes.

## How requests reach it

The engine adds a middleware to the app. It answers the paths under `/runlight`, the short links at `/go`, and any [link domain](/docs/links/) you add in Settings before the router sees them, and passes every other request on to the app. Rails' CSRF check would refuse the tracker, which cannot send a token, and Runlight checks its requests its own way, so nothing goes in `config/routes.rb`. The middleware also records the fetches of [AI agents](/docs/ai/#agents-that-read-your-pages) as your pages are served, which takes no time for anyone else.

A link domain is a host of its own, so add it to `config.hosts` when the app sets that list, or Rails turns the request away first.

## The scheduled check

The [scheduled check](/docs/cron/) sends email reports and keeps the data tidy. Run it every few minutes, once for the whole app rather than in each process. With Solid Queue, add it to `config/recurring.yml`.

```yaml file=config/recurring.yml
production:
  runlight_check:
    command: "Runlight.instance.check"
    schedule: every 5 minutes
```

With cron, or any scheduler that runs a command, use the rake task.

```bash
*/5 * * * * cd /var/www/app && bin/rails runlight:check
```

## In tests

Runlight records nothing until a request reaches it, so tests that never load `/runlight` see no difference. A test of the dashboard itself can call `Runlight.configure` again with a store of its own, such as `Runlight::Stores.sqlite(":memory:")`, and the engine uses the new one from the next request on.

## How it differs from the TypeScript library

The engine is the [Ruby gem](/docs/ruby/) inside Rails, so what [the Ruby guide](/docs/ruby/#how-it-differs-from-the-typescript-library) lists applies here too. The same gem has a [standalone server](/docs/ruby/#the-standalone-server) for running Runlight on a domain of its own, with one dashboard for several sites.
