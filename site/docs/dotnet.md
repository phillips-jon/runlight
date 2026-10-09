---
title: .NET
description: Runlight runs in .NET 10 or later, inside an ASP.NET Core app, or on a domain of its own as a standalone server.
group: Platforms
order: 14.95
---

The .NET package is Runlight written again in C#. It serves the same dashboard and API, and it gives every request the answer the TypeScript library gives. Its numbers go in the same tables, so either one can read a database the other wrote. It needs .NET 10 or later and the ADO.NET driver for your database, which your app already has if it uses that database.

## Install

Add the ASP.NET Core package and the driver for your database. The package brings the core `Runlight` package with it.

```bash
dotnet add package Runlight.AspNetCore
dotnet add package Microsoft.Data.Sqlite
```

The core package has no dependencies of its own. It reaches the database through the driver you hand it, and it shares that driver's connection pool.

## Create the instance

Make one instance when the app starts and register it as a singleton.

```csharp file=Program.cs
using Microsoft.Data.Sqlite;
using Runlight;
using Runlight.Store;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSingleton(new Runlight.Runlight(new RunlightOptions
{
    Store = Stores.Sqlite(SqliteFactory.Instance, "data/runlight.db"),
    Site = new SiteOptions { Name = "example.com", Hostnames = ["example.com"], Timezone = "Europe/London" },
}));
```

The options have the names in [Configuration](/docs/configuration/#runlight-options), written in PascalCase, so `Sites`, `TrustProxy`, `RateLimit`, `Mail`, and `ManagedSites` all work as they do there. The tables are created on the first request.

## Stores

### SQLite

```csharp
Stores.Sqlite(SqliteFactory.Instance, "data/runlight.db");
```

SQLite needs `Microsoft.Data.Sqlite`. Keep the file in a folder the app can write to, since SQLite writes a journal beside it. The folder is made when it is missing.

### Postgres

```csharp
Stores.Postgres(NpgsqlDataSource.Create("Host=127.0.0.1;Username=runlight;Password=password;Database=runlight"));
```

This store needs `Npgsql`. Pass the app's own `NpgsqlDataSource` to share its pool. A second argument such as `30000` stops any one query after that many milliseconds, and `Search Path=analytics` in the connection string keeps the tables in a schema of their own.

### MySQL and MariaDB

```csharp
Stores.MySql(new MySqlDataSource("Server=127.0.0.1;User ID=runlight;Password=password;Database=runlight"));
```

This store needs `MySqlConnector` and works with MySQL 8.4 or later and MariaDB 11.4 or later. It takes the same second argument as the Postgres store.

## ASP.NET Core

Map Runlight after the app is built.

```csharp file=Program.cs
var app = builder.Build();

app.MapRunlight();

app.Run();
```

`MapRunlight()` serves the dashboard, the API, and the script under `/runlight`, and the short links at `/go`. It also answers any [link domain](/docs/links/) you add in **Settings**, and it records the fetches of [AI agents](/docs/ai/#agents-that-read-your-pages) as your pages are served, which takes no time for anyone else. Runlight checks its own requests, so its endpoints skip ASP.NET Core’s antiforgery check, which would refuse the tracker. They allow anonymous requests, so an app whose fallback policy needs a signed-in user still counts its visitors. Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes. The options for the routes go in a `RoutesOptions`, with the names in [Configuration](/docs/configuration/#routes-options).

```csharp
app.MapRunlight(new RoutesOptions { BasePath = "/stats", Accounts = true, Origin = "https://example.com" });
```

With `Accounts = true` and a `RUNLIGHT_SECRET`, people sign in with their own email and password, as in [Accounts](/docs/configuration/#accounts). With `Token = null` the routes have no sign-in of their own, and their endpoints then follow the app’s authorization policy.

`app.UseRunlight()` does the same work as middleware, for an app that wants Runlight ahead of its other middleware or has no endpoint routing. Requests that are not Runlight’s go on to the app. Middleware carries no endpoint authorization, so call `UseAuthentication()` and `UseAuthorization()` before it when the dashboard relies on the app’s sign-in.

A link domain is a host of its own, so add it to `AllowedHosts` when the app sets that list, or ASP.NET Core turns the request away first.

## Other .NET apps

Any .NET app can hand Runlight a request and send back its answer. Build a `Runlight.Http.Request` from the absolute URL, the method, the headers, the body, and the connection’s address, then pass it to `FrontController.AnswerAsync()`.

```csharp
using Runlight.Http;
using Runlight.Server;

var request = new Request(url, method, headers, body, remoteAddress);
Response answer = await FrontController.AnswerAsync(rl, routes, request);
await rl.IdleAsync();
```

`answer.Status`, `answer.HeaderLines()`, and `answer.WriteToAsync()` give what to send. `IdleAsync()` runs the work the TypeScript library does after answering, so call it once the answer is out. In an ASP.NET Core endpoint or middleware of your own, `RunlightHttp.ServeAsync(context, rl, routes)` does all of this for an `HttpContext`.

## The scheduled check

The [scheduled check](/docs/cron/) can run inside the app as a hosted service.

```csharp file=RunlightCheck.cs
public sealed class RunlightCheck(Runlight.Runlight rl) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        do
        {
            await rl.CheckAsync(stoppingToken);
            await rl.IdleAsync();
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
```

Register it with `builder.Services.AddHostedService<RunlightCheck>()`. An app that runs as several copies can leave this out and set `CRON_SECRET`, then have one scheduler call `/runlight/api/check` instead.

## The standalone server

The `runlight` tool runs Runlight on a domain of its own, such as `stats.example.com`, as the [standalone server](/docs/server/) does. It serves the dashboard at the root, keeps the sites in the dashboard, and has sign-in accounts and short links on any domain you point at it.

```bash
dotnet tool install --global Runlight.Server
mkdir stats && cd stats
runlight serve
```

The server listens on port 3000, or on `PORT`, on Kestrel. The data lives in `runlight-data` in the folder you start it from. On its first start it prints a link with a one-time code that makes the first account and writes the link to `setup.txt` in the data folder, and `runlight setup` prints it again. The link works only while there is no account. Roles, invites, two-factor sign-in, and adding sites work as they do on the [standalone server](/docs/server/#make-your-account).

### Settings

Settings come from environment variables, or from a `config.json` in the folder you start the server from that holds the same names. Environment variables win when both are set.

```json file=config.json
{
  "RUNLIGHT_URL": "https://stats.example.com",
  "DATABASE_URL": "postgres://runlight:password@localhost:5432/runlight"
}
```

| Setting | What it does |
| --- | --- |
| `PORT` | The port the server listens on, 3000 by default. |
| `HOST` | The address it listens on, `0.0.0.0` by default. |
| `RUNLIGHT_URL` | The dashboard’s public address, such as `https://stats.example.com`. It can never become a link domain, and invite and report emails link to it. |
| `DATABASE_URL` | A `postgres://`, `mysql://`, or `mariadb://` address keeps the data in that database instead of SQLite. |
| `DATA_DIR` | The data folder, `runlight-data` by default. A relative path is read from the folder the server starts in. |
| `RUNLIGHT_SECRET` | The key that signs sign-ins and encrypts saved keys. Without it, the server makes one and keeps it in the data folder. |
| `RUNLIGHT_TOKEN` | A bearer token for scripts, which also makes the first account in place of the setup link. |
| `TRUST_PROXY` | Set to `false` when nothing sits in front of the server, or to `x-real-ip` or `cf-connecting-ip` when that header holds the visitor’s address. |
| `RUNLIGHT_GEO` | Where locations come from, as on the [standalone server](/docs/server/#locations). It is `city` by default, and can be `country`, `off`, or the path to an MMDB file. |
| `CRON_SECRET` | Lets a scheduler run the check at `POST /api/check`. |
| `RUNLIGHT_OBSERVE_KEY` | One key for every site’s AI agent reports. Each site’s own key from **Settings**, **Install** is the better choice. |
| `RUNLIGHT_CONFIG` | The path of a config file somewhere other than the folder the server starts in. |

The server runs the [scheduled check](/docs/cron/) every five minutes and downloads the new location data once a month. For a server that is not always running, `runlight cron` does the same work once. It prints nothing when all is well, apart from one line when a new month’s location data is ready.

```bash
*/5 * * * * cd /srv/stats && runlight cron
```

A systemd service or any process manager keeps the server running. It stops on `SIGTERM` and gives the answers it has started five seconds to finish.

### Forgotten passwords

Run the `password` command in the server’s folder to give an account a new password, which it prints. It also turns off two-factor sign-in for that account, and it makes the account when there is none.

```bash
runlight password someone@example.com
```

### Upgrades and backups

Run `dotnet tool update --global Runlight.Server` and restart the server. The tables update themselves on the next start, or run `runlight migrate` to update them at once. Back up the data folder and `config.json`, since saved keys cannot be read without the secret.

### AI agents from a log

AI agents such as GPTBot and ClaudeBot fetch pages without running JavaScript, so the script tag never sees them. An ASP.NET Core app with Runlight inside counts them as it serves its pages. For any other site you host yourself, the web server’s access log has them, and the `agents` command reads it.

```bash
runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_... --site https://example.com --follow
```

The key is the site’s own, from **Settings**, **Install**, **Key for CMS plugins**, and it can only report fetches for that site. When `--to` or `--key` is left out, the command reads `RUNLIGHT_URL` or `RUNLIGHT_OBSERVE_KEY` from the environment or `config.json`. `--site` is the site’s address, for logs in nginx or Apache’s usual format, which leave the host out. Caddy’s JSON logs carry the host, so it is not needed there.

With `--follow` the command keeps running, sends fetches as they happen, and carries on when the log is rotated. Add `--state agents.json` so a restart picks up where it stopped. Without `--follow` it reads the log once and stops, and with `--state` the next run starts where the last one finished, which suits cron. Only one run at a time can use a state file, and a lock left by a run that crashed is taken over. Only successful page fetches from known AI agents leave the machine, each with the page’s address, the agent’s user agent, and when it was served.

## How it differs from the TypeScript library

The .NET package passes the conformance tests the TypeScript library is held to, on SQLite, Postgres, MySQL, and MariaDB. The differences come from how .NET apps run.

- The connection pool is the driver’s. Postgres and MySQL take a connection from the data source’s pool for each query, and SQLite keeps one connection open and runs one statement at a time.
- What the TypeScript library does in the background, such as deleting visits after a shorter retention is chosen, runs once ASP.NET Core has sent the answer.
- Passwords are hashed with scrypt written in C#, since .NET has none built in. The hashes match the TypeScript library’s, so accounts carry over.
- The tracker’s rate limit is kept in memory, so each copy of the app counts on its own. Wrong-password limits are kept in the database, so every copy shares them.
- Email reports format numbers, dates, money, and country names from a copy of the ICU data Node uses, so they read the same on every system.
