---
title: Rust
description: Runlight runs inside a Rust service on tokio, behind axum, hyper, or any server that takes a tower service, with its tables in the app's own database through sqlx.
group: Platforms
order: 17.8
---

The Rust crate is Runlight written again in Rust. It serves the same dashboard and API, and it gives every request the answer the TypeScript library gives. Its numbers go in the same tables, so either one can read a database the other wrote. It needs Rust 1.88 or later and runs on tokio. The store comes from a second crate, `runlight-sqlx`, which needs Rust 1.94 for sqlx 0.9.

## Install

Add both crates, with the database you use and the framework adapter you want.

```toml
[dependencies]
runlight = { version = "0.0", features = ["axum"] }
runlight-sqlx = { version = "0.0", features = ["sqlite"] }
```

The `runlight` crate's `transport` feature is on by default and gives it a client for the mail services, connected installs, site icons, and the AI Assistant. The `tower` feature makes the routes a tower service, and `axum` adds the routers below. The `runlight-sqlx` features are `sqlite`, `postgres`, and `mysql`.

## Create the instance

Make one Runlight when your service starts and keep it in your state. It is cheap to clone.

```rust
use runlight::{Runlight, RunlightOptions, SiteOptions};

let store = runlight_sqlx::connect("sqlite:data/runlight.db").await?;
let mut options = RunlightOptions::new(store);
options.site = Some(SiteOptions {
    name: Some("example.com".into()),
    hostnames: Some(vec!["example.com".into()]),
    timezone: Some("Europe/London".into()),
    ..SiteOptions::default()
});
let rl = Runlight::new(options)?;
```

The options have the same names as in [Configuration](/docs/configuration/#runlight-options), in snake case, so `sites`, `trust_proxy`, `rate_limit`, `mail`, and `managed_sites` all work as they do there. The tables are created on the first request.

## Stores

`runlight_sqlx::connect` opens a pool of its own from a URL. To use the pool your app already has, pass it in, and Runlight keeps its tables beside yours.

### SQLite

```rust
let store = runlight_sqlx::sqlite(pool); // a sqlx::SqlitePool
```

The store holds one connection of the pool for its statements, in turn, in WAL mode with a busy timeout of five seconds. The `sqlite` feature builds SQLite from source, so your build needs a C compiler.

### MySQL and MariaDB

```rust
let store = runlight_sqlx::mysql(pool); // a sqlx::MySqlPool
```

This store works with MySQL 8.4 or later and MariaDB 11.4 or later, and the pool needs at least two connections. MySQL 8's default sign-in over a connection without TLS needs sqlx's `mysql-rsa` feature, so turn it on in your own `Cargo.toml` or connect over TLS.

### Postgres

```rust
let store = runlight_sqlx::postgres(pool); // a sqlx::PgPool
```

The pool needs at least two connections. Each statement runs on its own, so Runlight's writes never join a transaction your app has open.

## axum

Merge the routers into your app. The dashboard and API answer at `/runlight`, and short links at `/go/{slug}`.

```rust
use runlight::{RoutesOptions, TokenOption};

let routes = rl.routes(RoutesOptions {
    token: TokenOption::Given(std::env::var("RUNLIGHT_TOKEN")?),
    ..RoutesOptions::default()
})?;
let app = axum::Router::new()
    .merge(routes.router())
    .merge(rl.link_router())
    .layer(axum::middleware::from_fn_with_state(rl.clone(), runlight::adapters::axum_support::middleware));
```

The middleware sends requests for a link domain to its short links and records AI agent fetches of your pages. Serve the app with `into_make_service_with_connect_info::<SocketAddr>()` so Runlight sees the connection's address when no proxy header names the visitor. Then add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes. `RoutesOptions` takes the settings `routes()` takes in [Configuration](/docs/configuration/#routes-options), in snake case, so `base_path`, `accounts`, and `origin` work as they do there.

## Other servers

`Routes` is a `tower::Service` for any `http::Request`, so hyper and anything else built on tower can serve it as it is. Without the `tower` feature, build a `runlight::http::Request` yourself and call `routes.handle(request).await`, which answers with a `runlight::http::Response`.

## The scheduled check

The [scheduled check](/docs/cron/) rotates the daily salts, sends email reports that are due, applies how long each site keeps its visits, and builds the rollups that keep long ranges quick. Call `rl.check().await` every few minutes from a task of your own. When nothing in the service runs on a timer, set `CRON_SECRET` and have a scheduler call `/runlight/api/check` with it, as [Scheduled check](/docs/cron/#anywhere-else) shows.

```rust
let checker = rl.clone();
tokio::spawn(async move {
    loop {
        if let Err(error) = checker.check().await {
            eprintln!("Runlight check failed: {error}");
        }
        tokio::time::sleep(std::time::Duration::from_secs(300)).await;
    }
});
```

## Location

Runlight reads the country, region, and city from the headers Vercel, Cloudflare, and Netlify add. Behind anything else, give it a MaxMind or DB-IP city database through `runlight::mmdb::Mmdb`, which reads the file a page at a time as lookups need it.

```rust
options.geo = Some(std::sync::Arc::new(runlight::mmdb::Mmdb::open("data/dbip-city-lite.mmdb")?));
```

## How it differs from the TypeScript library

The Rust crate passes the conformance tests the TypeScript library is held to, on SQLite, Postgres, MySQL, and MariaDB. The differences come from how Rust runs.

- The crate takes its outgoing requests, for mail services, connected installs, site icons, and the AI Assistant, through a `Fetcher` you can replace, so tests and locked-down networks can pass their own.
- It reads time zones from the system's database, so a zone whose rules changed after the TypeScript library's copy follows the newer rules.
- There is no standalone server in Rust. For one dashboard over several sites, run the [Node server](/docs/server/) or the server of another language, and [connect](/docs/server/#connect-sites-that-count-themselves) this service's site to it.
