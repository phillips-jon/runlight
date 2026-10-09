//! What the tests share: fresh stores on every database at hand, and the
//! fixtures written from the TypeScript SDK.
//!
//! SQLite always runs, in memory. Postgres runs when RUNLIGHT_TEST_PG is
//! set: a connection URL, or anything else for
//! postgres://joncphillips@127.0.0.1:5432/runlight_test_rust, and each store
//! gets a schema of its own there, dropped at the end. MySQL runs when
//! RUNLIGHT_TEST_MYSQL is set (a URL, or anything else for MySQL 8.4 at
//! 127.0.0.1:33084 and MariaDB 11.4 at 127.0.0.1:33114, database
//! runlight_test_rust), and MariaDB alone when RUNLIGHT_TEST_MARIADB is a
//! URL. A MySQL database is one per server, so the tests that use it take
//! turns, each starting from no tables.

#![allow(dead_code)]

use std::str::FromStr;
use std::sync::{Arc, LazyLock};

use runlight::js::{self, Value};
use runlight::store::SqlStore;
use tokio::sync::{Mutex, OwnedMutexGuard};

pub const PG_URL: &str = "postgres://joncphillips@127.0.0.1:5432/runlight_test_rust";
pub const MYSQL_URL: &str = "mysql://root:runlight@127.0.0.1:33084/runlight_test_rust";
pub const MARIADB_URL: &str = "mysql://root:runlight@127.0.0.1:33114/runlight_test_rust";

/// The repository's root.
pub fn root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// A fixture written from the TypeScript SDK, in packages/php/tests/fixtures.
pub fn fixture(name: &str) -> Value {
    let path = root().join(format!("packages/php/tests/fixtures/{name}.json"));
    js::parse(&std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))).expect("JSON")
}

/// A file in conformance/.
pub fn conformance(name: &str) -> Value {
    let path = root().join(format!("conformance/{name}.json"));
    js::parse(&std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))).expect("JSON")
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

/// The databases to test on, by name, each with its URL ("" for SQLite).
pub fn kinds() -> Vec<(&'static str, String)> {
    let mut out = vec![("sqlite", String::new())];
    if let Some(pg) = env("RUNLIGHT_TEST_PG") {
        out.push(("postgres", if pg.contains("://") { pg } else { PG_URL.into() }));
    }
    if let Some(my) = env("RUNLIGHT_TEST_MYSQL") {
        if my.contains("://") {
            out.push(("mysql", my));
        } else {
            out.push(("mysql", MYSQL_URL.into()));
            out.push(("mariadb", MARIADB_URL.into()));
        }
    }
    if let Some(maria) = env("RUNLIGHT_TEST_MARIADB").filter(|m| m.contains("://")) {
        out.push(("mariadb", maria));
    }
    out
}

/// One turn per MySQL server, as its one test database is shared.
static TURNS: LazyLock<std::sync::Mutex<std::collections::HashMap<String, Arc<Mutex<()>>>>> =
    LazyLock::new(Default::default);

/// What drops a store's tables or schema.
type Cleanup = Box<dyn FnOnce() -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> + Send>;

/// A fresh, empty store on a database, and what to do when the test is done with it.
pub struct Fresh {
    pub store: SqlStore,
    cleanup: Option<Cleanup>,
    _turn: Option<OwnedMutexGuard<()>>,
}

impl Fresh {
    /// Drops what the store made.
    pub async fn done(mut self) {
        self.store.close().await;
        if let Some(cleanup) = self.cleanup.take() {
            cleanup().await;
        }
    }
}

fn random_name() -> String {
    format!("rl_rust_{}", runlight::hash::random_id(5))
}

/// A fresh store of a kind.
pub async fn fresh(kind: &str, url: &str) -> Fresh {
    match kind {
        "sqlite" => {
            Fresh { store: runlight_sqlx::connect(":memory:").await.expect("SQLite"), cleanup: None, _turn: None }
        }
        "postgres" => {
            let name = random_name();
            let admin = sqlx::PgPool::connect(url).await.expect("Postgres");
            sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE SCHEMA \"{name}\"")))
                .execute(&admin)
                .await
                .expect("a schema");
            let options = sqlx::postgres::PgConnectOptions::from_str(url)
                .expect("a URL")
                .options([("search_path", name.as_str())]);
            let pool =
                sqlx::postgres::PgPoolOptions::new().max_connections(5).connect_with(options).await.expect("Postgres");
            let store = runlight_sqlx::postgres(pool);
            Fresh {
                store,
                cleanup: Some(Box::new(move || {
                    Box::pin(async move {
                        let _ = sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DROP SCHEMA IF EXISTS \"{name}\" CASCADE")))
                            .execute(&admin)
                            .await;
                        admin.close().await;
                    })
                })),
                _turn: None,
            }
        }
        _ => {
            let lock = TURNS.lock().unwrap().entry(url.to_string()).or_default().clone();
            let turn = lock.lock_owned().await;
            let pool = sqlx::mysql::MySqlPoolOptions::new().max_connections(5).connect(url).await.expect("MySQL");
            drop_tables(&pool).await;
            let cleanup_pool = pool.clone();
            Fresh {
                store: runlight_sqlx::mysql(pool),
                cleanup: Some(Box::new(move || {
                    Box::pin(async move {
                        drop_tables(&cleanup_pool).await;
                        cleanup_pool.close().await;
                    })
                })),
                _turn: Some(turn),
            }
        }
    }
}

/// Every Runlight table in the shared MySQL database goes, so the next test starts from none.
async fn drop_tables(pool: &sqlx::MySqlPool) {
    use sqlx::Row;
    let rows = sqlx::query("SELECT table_name AS t FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'rl\\_%'")
        .fetch_all(pool)
        .await
        .expect("the tables");
    for row in rows {
        let name: String = row
            .try_get::<String, _>("t")
            .or_else(|_| row.try_get::<Vec<u8>, _>("t").map(|b| String::from_utf8_lossy(&b).into_owned()))
            .unwrap();
        sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DROP TABLE IF EXISTS `{name}`")))
            .execute(pool)
            .await
            .expect("a dropped table");
    }
}
