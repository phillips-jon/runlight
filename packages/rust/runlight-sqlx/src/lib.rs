//! Runlight's tables in the app's own database, through sqlx and the app's
//! own pool.
//!
//! ```no_run
//! # #[cfg(feature = "sqlite")]
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! use sqlx::sqlite::{SqliteConnectOptions, SqlitePool};
//!
//! let pool = SqlitePool::connect_with(SqliteConnectOptions::new().filename("data/runlight.db").create_if_missing(true)).await?;
//! let store = runlight_sqlx::sqlite(pool);
//! # Ok(())
//! # }
//! ```
//!
//! The tables are the TypeScript SDK's, statement for statement, so a Rust
//! process can share a database with a Node or PHP one. Each database is a
//! feature of the crate: `sqlite`, `postgres`, and `mysql` (MySQL 8.4 or
//! MariaDB 11.4 and later).
//!
//! Values reach the database as the TypeScript drivers send them. SQLite
//! binds them typed, as better-sqlite3 does. Postgres and MySQL get them in
//! the statement's text, as node-postgres's untyped parameters and mysql2's
//! client-side escaping do, so every statement means the same to the server
//! as it does from Node: a value Postgres would infer the type of is written
//! as a literal it infers the type of in the same way.

#![forbid(unsafe_code)]

#[cfg(feature = "mysql")]
mod mysql;
#[cfg(feature = "postgres")]
mod postgres;
mod rows;
#[cfg(feature = "sqlite")]
mod sqlite;

#[cfg(feature = "mysql")]
pub use mysql::MysqlDb;
#[cfg(feature = "postgres")]
pub use postgres::PostgresDb;
#[cfg(feature = "sqlite")]
pub use sqlite::SqliteDb;

use runlight::store::SqlStore;
#[cfg(any(feature = "sqlite", feature = "postgres", feature = "mysql"))]
use std::sync::Arc;

/// Runlight's tables in a SQLite database, on one connection of the app's pool, which the store
/// holds for its statements in turn (an in-memory database is one per connection, and SQLite has one
/// writer at a time anyway). The connection is put in WAL mode with a busy timeout of five seconds.
#[cfg(feature = "sqlite")]
pub fn sqlite(pool: sqlx::SqlitePool) -> SqlStore {
    SqlStore::new(Arc::new(SqliteDb::new(pool)))
}

/// Runlight's tables in Postgres, on the app's pool. The pool needs at least two connections: some
/// work holds one while it reads through another.
#[cfg(feature = "postgres")]
pub fn postgres(pool: sqlx::PgPool) -> SqlStore {
    SqlStore::new(Arc::new(PostgresDb::new(pool)))
}

/// Runlight's tables in MySQL 8.4 or MariaDB 11.4 and later, on the app's pool, which needs at least
/// two connections. Text is utf8mb4 with a binary collation, so it compares and sorts by code point,
/// as SQLite and Postgres do.
#[cfg(feature = "mysql")]
pub fn mysql(pool: sqlx::MySqlPool) -> SqlStore {
    SqlStore::new(Arc::new(MysqlDb::new(pool)))
}

/// A store from a connection URL: `sqlite:` (or a path), `postgres://`, or `mysql://` and `mariadb://`,
/// with a pool of its own, as the standalone server and the CLI open one.
pub async fn connect(url: &str) -> Result<SqlStore, runlight::store::DbError> {
    let fail = |e: &dyn std::fmt::Display| runlight::store::DbError(e.to_string());
    let lower = url.to_ascii_lowercase();
    if lower.starts_with("postgres://") || lower.starts_with("postgresql://") {
        #[cfg(feature = "postgres")]
        {
            let pool = sqlx::postgres::PgPoolOptions::new()
                .max_connections(10)
                .acquire_timeout(std::time::Duration::from_secs(10))
                .connect(url)
                .await
                .map_err(|e| fail(&e))?;
            return Ok(postgres(pool));
        }
        #[cfg(not(feature = "postgres"))]
        return Err(fail(&"Runlight: built without the postgres feature"));
    }
    if lower.starts_with("mysql://") || lower.starts_with("mariadb://") {
        #[cfg(feature = "mysql")]
        {
            let url = format!("mysql://{}", &url[url.find("://").map_or(0, |i| i + 3)..]);
            let pool = sqlx::mysql::MySqlPoolOptions::new()
                .max_connections(10)
                .acquire_timeout(std::time::Duration::from_secs(10))
                .connect(&url)
                .await
                .map_err(|e| fail(&e))?;
            return Ok(mysql(pool));
        }
        #[cfg(not(feature = "mysql"))]
        return Err(fail(&"Runlight: built without the mysql feature"));
    }
    #[cfg(feature = "sqlite")]
    {
        use std::str::FromStr;
        let path = url.strip_prefix("sqlite://").or_else(|| url.strip_prefix("sqlite:")).unwrap_or(url);
        let options = if path == ":memory:" {
            sqlx::sqlite::SqliteConnectOptions::from_str("sqlite::memory:").map_err(|e| fail(&e))?
        } else {
            sqlx::sqlite::SqliteConnectOptions::new().filename(path).create_if_missing(true)
        };
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .map_err(|e| fail(&e))?;
        Ok(sqlite(pool))
    }
    #[cfg(not(feature = "sqlite"))]
    Err(fail(&"Runlight: built without the sqlite feature"))
}
