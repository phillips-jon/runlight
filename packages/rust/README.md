# runlight

Runlight is privacy friendly web analytics that runs inside your own Rust service. It counts visitors without cookies and without storing anyone's IP address. The numbers stay in your database, and the dashboard is served from your domain at `/runlight`.

This crate is the Rust version of [Runlight](https://runlight.sh). It runs on tokio behind axum, hyper, or any server that takes a tower service. It answers every request the way the TypeScript library does and uses the same tables, so either one can read the other's database. The store is the `runlight-sqlx` crate, which keeps the tables in your own SQLite, Postgres, MySQL, or MariaDB database.

## Get started

Add the crates.

```toml
[dependencies]
runlight = { version = "0.0", features = ["axum"] }
runlight-sqlx = { version = "0.0", features = ["sqlite"] }
```

Create one instance, merge its routers into your app, and add its middleware, which answers your link domains before your own routes.

```rust,no_run
use runlight::{Runlight, RunlightOptions, RoutesOptions, SiteOptions};

# async fn run() -> Result<(), Box<dyn std::error::Error>> {
let store = runlight_sqlx::connect("sqlite:data/runlight.db").await?;
let mut options = RunlightOptions::new(store);
options.site = Some(SiteOptions { hostnames: Some(vec!["example.com".into()]), ..SiteOptions::default() });
let rl = Runlight::new(options)?;
let app: axum::Router = axum::Router::new()
    .merge(rl.routes(RoutesOptions::default())?.router())
    .merge(rl.link_router())
    .layer(axum::middleware::from_fn_with_state(rl.clone(), runlight::adapters::axum_support::middleware));
# Ok(())
# }
```

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Set `RUNLIGHT_TOKEN` to a long random string, then open `/runlight/?token=` followed by that string to sign in.

The [Rust guide](https://runlight.sh/docs/rust/) has the stores, other servers, the scheduled check, and location lookups.

## License

Runlight is MIT licensed.
