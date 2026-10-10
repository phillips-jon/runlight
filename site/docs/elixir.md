---
title: Elixir
description: Runlight runs in Elixir 1.18 or later on Erlang/OTP 27 or later, inside a Phoenix or Plug app, with its tables in your own Ecto repo.
group: Platforms
order: 17.7
---

The Elixir package is Runlight written again in Elixir. It serves the same dashboard and API, and it gives every request the answer the TypeScript library gives. Its numbers go in the same tables, so either one can read a database the other wrote. It needs Elixir 1.18 or later on Erlang/OTP 27 or later.

## Install

Add the package to `mix.exs`, with the Ecto adapter for your database if your app has none yet.

```elixir file=mix.exs
def deps do
  [
    {:runlight, "~> 0.0"},
    {:ecto_sqlite3, "~> 0.17"}
  ]
end
```

Runlight keeps its tables in your app's own Ecto repo, through `ecto_sqlite3`, `postgrex`, or `myxql`. Its dashboard is a Plug, which every Phoenix app already has. Time zones come from the `tz` package, which is compiled in, so a release works on any image.

## Start the instance

Runlight is a child of your application's supervision tree, started after your repo.

```elixir file=lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Runlight,
   store: {Runlight.Store, repo: MyApp.Repo},
   site: [name: "example.com", hostnames: ["example.com"], timezone: "Europe/London"],
   check_every: :timer.hours(1)}
]
```

The options have the same names as in [Configuration](/docs/configuration/#runlight-options), written in snake case, so `sites`, `trust_proxy`, `rate_limit`, `mail`, and `managed_sites` all work as they do there. The tables are created when the instance starts, and a store that cannot be reached stops the app from booting. `check_every` runs the [scheduled check](/docs/cron/) on an interval, which rotates the daily salts, sends email reports that are due, applies how long each site keeps its visits, and builds the rollups that keep long ranges quick. Leave it out when a scheduler calls `/runlight/api/check` with `CRON_SECRET` instead, as [Scheduled check](/docs/cron/#anywhere-else) shows, or call `Runlight.check(Runlight.instance())` from a job of your own.

## Stores

The store is your repo, and its adapter picks the SQL Runlight writes. Runlight's tables all start with `rl_`, so they sit beside your own.

On SQLite keep ecto_sqlite3's write-ahead journal and give the repo a `busy_timeout` of at least 5000. An in-memory database is one per connection, so a repo with `database: ":memory:"` needs `pool_size: 1`.

Postgres works as it is. Runlight builds its indexes concurrently, so a large table keeps taking writes while an upgrade runs.

MySQL needs 8.4 or later, and MariaDB 11.4 or later, since the tables use the binary collation `utf8mb4_0900_bin` so text sorts the same way on every database.

## Phoenix

Forward `/runlight` to the Plug outside the `:browser` pipeline. That pipeline asks every POST for a CSRF token, which the tracker cannot send, and Runlight checks requests its own way.

```elixir file=lib/my_app_web/router.ex
scope "/" do
  forward "/runlight", Runlight.Plug, token: System.get_env("RUNLIGHT_TOKEN", "")
  forward "/go", Runlight.Plug.Links
end
```

The token is read once, when the router compiles. In a release, leave the option out and set `RUNLIGHT_TOKEN` where the app runs, since Runlight reads it on the first request. An empty token keeps the dashboard closed, and `token: false` leaves it open for an app that checks people itself.

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes. With `accounts: true` and a `RUNLIGHT_SECRET`, people sign in with their own email and password, as in [Accounts](/docs/configuration/#accounts).

To count the [AI agents](/docs/ai/#agents-that-read-your-pages) that read your pages, add the observer to the `:browser` pipeline. It records their fetches and returns at once for everyone else.

```elixir file=lib/my_app_web/router.ex
pipeline :browser do
  plug :accepts, ["html"]
  plug Runlight.Plug.Observer
end
```

A [link domain](/docs/links/#custom-domains) answers short links on a name of its own. Each of Runlight's Plugs answers a request on a link domain before anything else and passes every other request on untouched. A Phoenix router only runs them for paths it matches, so put the link domain Plug in your endpoint, before the router, and every request on that name is answered there.

```elixir file=lib/my_app_web/endpoint.ex
plug Runlight.Plug.LinkDomains
plug MyAppWeb.Router
```

## Plug.Router

A `Plug.Router` forwards the same way. The link domain Plug goes before `:match`, so it sees every request.

```elixir file=lib/my_app/router.ex
defmodule MyApp.Router do
  use Plug.Router

  plug Runlight.Plug.LinkDomains
  plug :match
  plug :dispatch

  forward "/runlight", to: Runlight.Plug
  forward "/go", to: Runlight.Plug.Links
end
```

## Behind a proxy

Runlight reads the visitor's address from the last `X-Forwarded-For` entry, which the nearest proxy wrote, so a visitor counts once a day. With nothing in front of the app, set `trust_proxy: false` and it reads the connection's own address. Behind Cloudflare and another proxy, `trust_proxy: "cf-connecting-ip"` reads only that header.

## Several instances

Give each one a name and pass it to the Plugs.

```elixir
{Runlight, name: MyApp.Stats, store: {Runlight.Store, repo: MyApp.Repo}, site: [name: "Docs"]}

forward "/stats", Runlight.Plug, instance: MyApp.Stats
```

## How it differs from the TypeScript library

The Elixir package passes the conformance tests the TypeScript library is held to, on SQLite, Postgres, MySQL, and MariaDB. The differences come from how Elixir runs.

- Each request runs in its own process, and the instance lives in your supervision tree. Its state, such as the tracker's rate limit and the cached lists of link domains, sits in an ETS table, so every process on a node shares it and each node keeps its own.
- What the TypeScript library does in the background, such as deleting visits after a shorter retention is chosen, runs in a task of its own once the answer is sent.
- New passwords are hashed with PBKDF2-SHA-256, which Erlang's crypto computes natively. Hashes the TypeScript library made with scrypt still sign in, so accounts carry over.
- There is no standalone server in Elixir. For one dashboard over several sites, run the [Node server](/docs/server/) or the server of another language, and [connect](/docs/server/#connect-sites-that-count-themselves) this app's site to it.
