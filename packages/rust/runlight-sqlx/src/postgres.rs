//! Postgres, on the app's pool. Each statement runs on the pool on its own, so the store's writes never
//! join a transaction the app has open; a transaction or a lock holds one connection until it ends.

use std::sync::Arc;

use runlight::BoxFuture;
use runlight::store::{Db, DbError, Dialect, Hold, Param, Row, fill_placeholders, postgres_literal};
use sqlx::pool::PoolConnection;
use sqlx::{AssertSqlSafe, PgPool, Postgres};
use tokio::sync::Mutex;

use crate::rows::{db_error, pg_row};

/// Arbitrary but fixed, so every Runlight process takes the same lock to create tables.
const MIGRATION_LOCK: i64 = 7_331_906;

/// The store's driver over a Postgres pool. Values go in the statement's text as literals of unknown
/// type, so Postgres infers each one's type as it does for node-postgres's untyped parameters.
#[derive(Clone)]
pub struct PostgresDb {
    pool: PgPool,
}

impl PostgresDb {
    /// The store's driver over a pool.
    pub fn new(pool: PgPool) -> PostgresDb {
        PostgresDb { pool }
    }
}

fn text(sql: &str, params: &[Param]) -> Result<AssertSqlSafe<String>, DbError> {
    Ok(AssertSqlSafe(fill_placeholders(sql, params, false, postgres_literal)?))
}

impl Db for PostgresDb {
    fn dialect(&self) -> Dialect {
        Dialect::Postgres
    }

    fn all<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, DbError>> {
        Box::pin(async move {
            let rows = sqlx::raw_sql(text(sql, &params)?).fetch_all(&self.pool).await.map_err(db_error)?;
            rows.iter().map(pg_row).collect()
        })
    }

    fn run<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<u64, DbError>> {
        Box::pin(async move {
            Ok(sqlx::raw_sql(text(sql, &params)?).execute(&self.pool).await.map_err(db_error)?.rows_affected())
        })
    }

    fn hold(&self, kind: Hold) -> BoxFuture<'_, Result<Arc<dyn Db>, DbError>> {
        Box::pin(async move {
            let mut conn = self.pool.acquire().await.map_err(db_error)?;
            match kind {
                Hold::Transaction => {
                    sqlx::raw_sql(AssertSqlSafe("BEGIN".to_string())).execute(&mut *conn).await.map_err(db_error)?;
                }
                Hold::Exclusive => loop {
                    // Asked for again and again rather than waited on: a waiting statement would hold up an
                    // index being built CONCURRENTLY by whoever has the lock, and the two would wait on each
                    // other for good.
                    let rows =
                        sqlx::raw_sql(AssertSqlSafe(format!("SELECT pg_try_advisory_lock({MIGRATION_LOCK}) AS ok")))
                            .fetch_all(&mut *conn)
                            .await
                            .map_err(db_error)?;
                    let ok = rows.first().map(pg_row).transpose()?.is_some_and(|r| r.num("ok") == 1.0);
                    if ok {
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                },
            }
            Ok(Arc::new(Held { conn: Arc::new(Mutex::new(Some(conn))), kind, role: Role::Owner }) as Arc<dyn Db>)
        })
    }
}

/// One connection held for a transaction or a lock.
struct Held {
    conn: Arc<Mutex<Option<PoolConnection<Postgres>>>>,
    kind: Hold,
    role: Role,
}

/// What finishing a held connection does.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    /// Ends the transaction or lets the lock go, and gives the connection back.
    Owner,
    /// A transaction begun inside a lock: ends the transaction, and keeps the connection.
    Nested,
    /// Joined what was already held: ends nothing.
    Joined,
}

fn ended() -> DbError {
    DbError("Runlight: the held connection has been let go".into())
}

impl Db for Held {
    fn dialect(&self) -> Dialect {
        Dialect::Postgres
    }

    fn all<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, DbError>> {
        Box::pin(async move {
            let mut guard = self.conn.lock().await;
            let conn = guard.as_mut().ok_or_else(ended)?;
            let rows = sqlx::raw_sql(text(sql, &params)?).fetch_all(&mut **conn).await.map_err(db_error)?;
            rows.iter().map(pg_row).collect()
        })
    }

    fn run<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<u64, DbError>> {
        Box::pin(async move {
            let mut guard = self.conn.lock().await;
            let conn = guard.as_mut().ok_or_else(ended)?;
            Ok(sqlx::raw_sql(text(sql, &params)?).execute(&mut **conn).await.map_err(db_error)?.rows_affected())
        })
    }

    fn hold(&self, kind: Hold) -> BoxFuture<'_, Result<Arc<dyn Db>, DbError>> {
        Box::pin(async move {
            // A transaction inside the lock runs on the locked connection; anything else joins what is held.
            if kind == Hold::Transaction && self.kind == Hold::Exclusive {
                let mut guard = self.conn.lock().await;
                let conn = guard.as_mut().ok_or_else(ended)?;
                sqlx::raw_sql(AssertSqlSafe("BEGIN".to_string())).execute(&mut **conn).await.map_err(db_error)?;
                return Ok(Arc::new(Held { conn: self.conn.clone(), kind, role: Role::Nested }) as Arc<dyn Db>);
            }
            Ok(Arc::new(Held { conn: self.conn.clone(), kind: self.kind, role: Role::Joined }) as Arc<dyn Db>)
        })
    }

    fn finish(&self, ok: bool) -> BoxFuture<'_, Result<(), DbError>> {
        Box::pin(async move {
            let mut guard = self.conn.lock().await;
            if self.role == Role::Joined {
                return Ok(());
            }
            if self.role == Role::Nested {
                let Some(conn) = guard.as_mut() else { return Ok(()) };
                let end = if ok { "COMMIT" } else { "ROLLBACK" };
                sqlx::raw_sql(AssertSqlSafe(end.to_string())).execute(&mut **conn).await.map_err(db_error)?;
                return Ok(());
            }
            let Some(mut conn) = guard.take() else { return Ok(()) };
            let result = match self.kind {
                Hold::Transaction => {
                    let end = if ok { "COMMIT" } else { "ROLLBACK" };
                    sqlx::raw_sql(AssertSqlSafe(end.to_string()))
                        .execute(&mut *conn)
                        .await
                        .map(|_| ())
                        .map_err(db_error)
                }
                // A lost connection ends its session, and the lock with it.
                Hold::Exclusive => {
                    let _ = sqlx::raw_sql(AssertSqlSafe(format!("SELECT pg_advisory_unlock({MIGRATION_LOCK})")))
                        .execute(&mut *conn)
                        .await;
                    Ok(())
                }
            };
            if result.is_err() {
                // A connection still in its transaction must never go back to the pool.
                conn.detach();
            }
            result
        })
    }
}
