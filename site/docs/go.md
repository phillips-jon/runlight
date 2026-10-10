---
title: Go
description: Runlight runs in Go 1.25 or later, inside any net/http app, chi, or Echo, or as a server of its own.
group: Platforms
order: 17.4
---

The Go module is Runlight written again in Go. It serves the same dashboard and API, and it gives every request the answer the TypeScript library gives. Its numbers go in the same tables, so either one can read a database the other wrote. It needs Go 1.25 or later, and the module itself requires no other module.

## Install

Add the module with `go get`, along with the driver for your database.

```bash
go get runlight.sh/go
go get modernc.org/sqlite
```

Runlight talks to its database through `database/sql`, so any driver works. The tests run with `modernc.org/sqlite` for SQLite, `github.com/jackc/pgx/v5/stdlib` for Postgres, and `github.com/go-sql-driver/mysql` for MySQL and MariaDB.

## Create the instance

Open the database, wrap it in a store, and make one instance for the whole app.

```go file=analytics.go
package main

import (
	"database/sql"

	_ "modernc.org/sqlite"
	runlight "runlight.sh/go"
)

func newRunlight() (*runlight.Runlight, error) {
	db, err := sql.Open("sqlite", "data/runlight.db")
	if err != nil {
		return nil, err
	}
	return runlight.New(runlight.Options{
		Store: runlight.NewStore(runlight.SQLite(db).Owned(0)),
		Site:  &runlight.SiteOptions{Name: "example.com", Hostnames: []string{"example.com"}, Timezone: "Europe/London"},
	})
}
```

The options have the same names as in [Configuration](/docs/configuration/#runlight-options), written as Go fields, such as `Sites`, `IgnoreProxy`, `RateLimit`, `Mail`, and `ManagedSites`. Every method that reads or writes takes a `context.Context` first, and the tables are created on the first request.

## Stores

`Owned` hands the connection to Runlight, which closes it when the store is closed. Leave it off to share a `*sql.DB` your app already has, which Runlight then never closes.

### SQLite

```go
db, err := sql.Open("sqlite", "data/runlight.db")
store := runlight.NewStore(runlight.SQLite(db).Owned(0))
```

Runlight keeps one SQLite connection and puts it in WAL mode with a busy timeout. Keep the file outside any folder your web server serves, in a folder the app can write to, since SQLite writes a journal beside it.

### Postgres

```go
db, err := sql.Open("pgx", "postgres://runlight:password@127.0.0.1:5432/runlight?statement_timeout=120000")
store := runlight.NewStore(runlight.Postgres(db).Owned(0))
```

Import `github.com/jackc/pgx/v5/stdlib` for the `pgx` driver. The `statement_timeout` parameter stops any one statement after that many milliseconds, as the TypeScript library does after 120000. To keep the tables in a schema of their own, add `search_path=analytics` to the URL. The pool needs at least two connections.

### MySQL and MariaDB

```go
db, err := sql.Open("mysql", "runlight:password@tcp(127.0.0.1:3306)/runlight?charset=utf8mb4&loc=UTC")
store := runlight.NewStore(runlight.MySQL(db).Owned(120000))
```

This store works with MySQL 8.4 or later and MariaDB 11.4 or later. The number given to `Owned` is each session’s statement timeout in milliseconds, and 0 turns it off. The pool needs at least two connections.

## net/http

The routes are an `http.Handler`. Mount them at their base path, `/runlight` by default, and add the short links at `/go/{slug}`.

```go file=main.go
rl, err := newRunlight()
if err != nil {
	log.Fatal(err)
}
routes, err := rl.Routes(runlight.RoutesOptions{})
if err != nil {
	log.Fatal(err)
}

mux := http.NewServeMux()
mux.Handle("/runlight", routes)
mux.Handle("/runlight/", routes)
mux.Handle("GET /go/{slug}", rl.LinksHTTP())
mux.Handle("/", yourApp)

log.Fatal(http.ListenAndServe(":8080", rl.LinkDomains(rl.Observer(mux))))
```

`rl.Observer` records the fetches of [AI agents](/docs/ai/#agents-that-read-your-pages) as your app serves its pages, and passes every request on. `rl.LinkDomains` answers short links on your [link domains](/docs/links/#custom-domains), the names of their own that you point at the app, before the mux sees the request. It passes every other host on untouched, so your own pages are unaffected. In an app that sends every request through one handler, `routes.Middleware(next)` answers link domains and Runlight’s own paths, and passes the rest to `next` without reading their bodies. It also answers the OAuth documents that [MCP](/docs/mcp/) clients look for at the root of the site.

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes. `RoutesOptions` takes the same settings as `routes()` in [Configuration](/docs/configuration/#routes-options), so `Token`, `Authorize`, `BasePath`, and `Origin` work as they do there. With `Accounts: true` and a `RUNLIGHT_SECRET`, people sign in with their own email and password, as in [Accounts](/docs/configuration/#accounts).

## chi

The chi adapter is a module of its own, so chi is never a requirement of the core module.

```bash
go get runlight.sh/go/chi
```

```go
r := chi.NewRouter()
r.Use(rl.Observer)
runlightchi.Mount(r, rl, routes)
```

`Mount` adds the routes under their base path, the OAuth documents, and the short links, and it answers link domains ahead of your own routes. Call it on the top router before your own routes, since the routes read the full path of each request and chi takes middleware only until the first route.

## Echo

The Echo adapter is a module of its own too, and it works with Echo v5.

```bash
go get runlight.sh/go/echo
```

```go
e := echo.New()
e.Use(runlightecho.Observer(rl))
runlightecho.Register(e, rl, routes)
```

`Register` adds the routes, the OAuth documents, and the short links, as `Mount` does for chi. It answers link domains before Echo routes each request, wherever in the app it is called.

## Other routers

Any router that takes an `http.Handler` can serve Runlight the same way as `http.ServeMux` does, wrapped in `rl.LinkDomains` for link domains. To answer a request yourself, turn it into Runlight’s with `runlight.FromHTTP`, pass it to `routes.Handle`, and send the answer back with `runlight.WriteHTTP`. `FromHTTP` reads the body with the limits the Node adapter uses, 16 KB for the tracker and 10 MB for anything else, and keeps the address the connection came from. Runlight reads forwarded headers itself unless `IgnoreProxy` is set.

## The scheduled check

The [scheduled check](/docs/cron/) rotates the daily salts, sends email reports that are due, applies how long each site keeps its visits, and builds the rollups that keep long ranges quick. Call `rl.Check(ctx)` every few minutes from a goroutine with a `time.Ticker`. When nothing in the app runs on a timer, set `CRON_SECRET` and have a scheduler call `/runlight/api/check` with it, as [Scheduled check](/docs/cron/#anywhere-else) shows.

## The standalone server

The `runlight` command is the [standalone server](/docs/server/) in Go. It runs Runlight on a domain of its own, such as `stats.example.com`, with the dashboard at the root, sites added in the dashboard, sign-in accounts, and short links on any domain you point at it. Install it and run it.

```bash
go install runlight.sh/go/cmd/runlight@latest
runlight
```

The server listens on port 3000 and keeps its data in a folder called `runlight-data` in the directory you start it from. On its first start it prints a setup link with a one-time code. Open that link and make your account, as [Make your account](/docs/server/#make-your-account) describes. The server runs the scheduled check itself every five minutes, and it downloads the month’s location data as the Node server does. Put it behind a proxy that adds HTTPS, as in [Put it on the internet](/docs/server/#put-it-on-the-internet).

To run the server inside a program of your own, `runlight.sh/go/server` has it as an `http.Handler`, with `server.New` taking the same settings as fields.

### Settings

The server reads its settings from environment variables.

| Variable | What it does |
| --- | --- |
| `PORT` | The port to listen on. The default is 3000. |
| `HOST` | The address to listen on. The default is `0.0.0.0`. |
| `DATA_DIR` | The folder for the SQLite file, the secret, and the location data. The default is `./runlight-data`. |
| `DATABASE_URL` | A `postgres://` address keeps the data in Postgres instead of SQLite, and a `mysql://` or `mariadb://` address keeps it in MySQL or MariaDB. |
| `RUNLIGHT_SECRET` | The key that signs sign-ins and encrypts saved keys. Without it, the server makes one and keeps it in `DATA_DIR`, readable only by the user that runs it. |
| `RUNLIGHT_URL` | The server’s public address, such as `https://stats.example.com`, which can never become a link domain. Invite and report emails link to it. |
| `RUNLIGHT_TOKEN` | A token that scripts can send as a bearer, in addition to the [API tokens](/docs/mcp/) made in the dashboard. |
| `RUNLIGHT_OBSERVE_KEY` | One key for every site’s AI agent reports. Each site’s own key from **Settings**, **Install** is the better choice. |
| `TRUST_PROXY` | Set to `false` when no proxy sits in front of the server, or to `x-real-ip` or `cf-connecting-ip` when that header holds the visitor’s address. |
| `RUNLIGHT_GEO` | Where locations come from when no header gives them, as in [Locations](/docs/server/#locations). It is `city` by default, and can be `country`, `off`, or a path to an MMDB file. |

The tables update themselves when the server starts, so an upgrade needs only a new build and a restart. Back up the data folder, since saved keys cannot be read without the secret in it.

### Forgotten passwords

Run the `password` command where the server runs to give an account a new password, which it prints. It also turns off two-factor sign-in for that account, and it makes the account when there is none, as the owner on a server with nobody yet and as an admin otherwise.

```bash
runlight password someone@example.com
```

### AI agents from a log

AI agents such as GPTBot and ClaudeBot fetch pages without running JavaScript, so the script tag never sees them. A Go app with Runlight inside counts them where the page is served, with `rl.Observer`. For any other site you host yourself, the web server’s access log has them, and the `agents` command reads it.

```bash
runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_... --site https://example.com --follow
```

The key is the site’s own, from **Settings**, **Install**, **Key for CMS plugins**, and it can only report fetches for that site. When `--to` or `--key` is left out, the command reads `RUNLIGHT_URL` or `RUNLIGHT_OBSERVE_KEY` from the environment. The command works as it does on the [standalone server](/docs/server/#ai-agents-from-a-log), with `--follow` to keep running and `--state` to pick up where the last run stopped. Only successful page fetches from known AI agents leave the machine, and visitors’ addresses stay where they are.

## How it differs from the TypeScript library

The Go module passes the conformance tests the TypeScript library is held to, on SQLite, Postgres, MySQL, and MariaDB. The differences come from how Go runs.

- Requests run in goroutines, and the instance is safe for many at once. SQLite keeps one connection, which every request shares under a lock, and Postgres and MySQL use the pool `database/sql` keeps.
- What the TypeScript library does in the background, such as deleting visits after a shorter retention is chosen, runs in a goroutine beside the answer. `rl.Idle()` waits for it, which a program can call before it exits.
- Time zones come from Go’s own time zone database. A program built for a system without one imports `time/tzdata`.
- Text is changed to upper or lower case with tables made from Node’s, so names match the same way in both. Sites are listed by name with the main rules of Unicode’s default order, so now and then a name in a rarer script sorts a place away from where Node puts it.
- The tracker’s rate limit and the cached lists of link domains and site icons are kept in memory, so each process keeps its own. Wrong-password limits are kept in the database, so every process shares them.
- Passwords are hashed with scrypt in Go. The hashes match the TypeScript library’s, so accounts carry over.
