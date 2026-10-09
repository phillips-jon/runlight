//! MySQL 8.4 and MariaDB 11.4, on the app's pool. Each statement runs on the pool on its own; a
//! transaction or a lock holds one connection until it ends.

use std::sync::Arc;

use runlight::BoxFuture;
use runlight::store::{Db, DbError, Dialect, Hold, Param, Row, fill_placeholders, mysql_literal};
use sqlx::pool::PoolConnection;
use sqlx::{AssertSqlSafe, MySql, MySqlPool};
use tokio::sync::Mutex;

use crate::rows::{db_error, mysql_row};

/// One lock per database, so installs sharing a server do not wait on each other. Lock names are 64
/// characters at most.
const LOCK: &str = "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))";

/// The store's driver over a MySQL pool. SQL written for SQLite and Postgres is sent as MySQL reads it:
/// a "quoted" name in backticks, a backslash inside 'text' doubled, and each value written into the
/// statement, escaped, as mysql2 fills them in.
#[derive(Clone)]
pub struct MysqlDb {
    pool: MySqlPool,
}

impl MysqlDb {
    /// The store's driver over a pool.
    pub fn new(pool: MySqlPool) -> MysqlDb {
        MysqlDb { pool }
    }
}

fn text(sql: &str, params: &[Param]) -> Result<AssertSqlSafe<String>, DbError> {
    Ok(AssertSqlSafe(fill_placeholders(sql, params, true, mysql_literal)?))
}

async fn exec(conn: &mut PoolConnection<MySql>, sql: &str) -> Result<Vec<Row>, DbError> {
    let rows = sqlx::raw_sql(AssertSqlSafe(sql.to_string())).fetch_all(&mut **conn).await.map_err(db_error)?;
    rows.iter().map(mysql_row).collect()
}

impl Db for MysqlDb {
    fn dialect(&self) -> Dialect {
        Dialect::Mysql
    }

    fn all<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, DbError>> {
        Box::pin(async move {
            let rows = sqlx::raw_sql(text(sql, &params)?).fetch_all(&self.pool).await.map_err(db_error)?;
            rows.iter().map(mysql_row).collect()
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
                Hold::Transaction => begin(&mut conn).await?,
                Hold::Exclusive => loop {
                    let rows = exec(&mut conn, &format!("SELECT GET_LOCK({LOCK}, 5) AS ok")).await?;
                    let row = rows.into_iter().next().unwrap_or_default();
                    if row.is_null("ok") {
                        return Err(DbError("Runlight: MySQL refused the lock for creating tables".into()));
                    }
                    if row.num("ok") == 1.0 {
                        break;
                    }
                    // Not got within 5 seconds: another process is creating the tables. Ask again.
                },
            }
            Ok(Arc::new(Held { conn: Arc::new(Mutex::new(Some(conn))), kind, role: Role::Owner }) as Arc<dyn Db>)
        })
    }
}

/// As Postgres does by default: each statement sees what was committed before it began, and InnoDB
/// takes no gap locks, so two writers to neighbouring rows do not deadlock.
async fn begin(conn: &mut PoolConnection<MySql>) -> Result<(), DbError> {
    exec(conn, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED").await?;
    exec(conn, "START TRANSACTION").await?;
    Ok(())
}

/// One connection held for a transaction or a lock.
struct Held {
    conn: Arc<Mutex<Option<PoolConnection<MySql>>>>,
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
        Dialect::Mysql
    }

    fn all<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, DbError>> {
        Box::pin(async move {
            let mut guard = self.conn.lock().await;
            let conn = guard.as_mut().ok_or_else(ended)?;
            let rows = sqlx::raw_sql(text(sql, &params)?).fetch_all(&mut **conn).await.map_err(db_error)?;
            rows.iter().map(mysql_row).collect()
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
            if kind == Hold::Transaction && self.kind == Hold::Exclusive {
                let mut guard = self.conn.lock().await;
                begin(guard.as_mut().ok_or_else(ended)?).await?;
                return Ok(Arc::new(Held { conn: self.conn.clone(), kind, role: Role::Nested }) as Arc<dyn Db>);
            }
            Ok(Arc::new(Held { conn: self.conn.clone(), kind: self.kind, role: Role::Joined }) as Arc<dyn Db>)
        })
    }

    fn finish(&self, ok: bool) -> BoxFuture<'_, Result<(), DbError>> {
        Box::pin(async move {
            let mut guard = self.conn.lock().await;
            match self.role {
                Role::Joined => Ok(()),
                Role::Nested => {
                    let Some(conn) = guard.as_mut() else { return Ok(()) };
                    exec(conn, if ok { "COMMIT" } else { "ROLLBACK" }).await.map(|_| ())
                }
                Role::Owner => {
                    let Some(mut conn) = guard.take() else { return Ok(()) };
                    let result = match self.kind {
                        Hold::Transaction => exec(&mut conn, if ok { "COMMIT" } else { "ROLLBACK" }).await.map(|_| ()),
                        // A lost connection ends its session, and the lock with it.
                        Hold::Exclusive => {
                            let _ = exec(&mut conn, &format!("DO RELEASE_LOCK({LOCK})")).await;
                            Ok(())
                        }
                    };
                    if result.is_err() {
                        // A connection still in its transaction must never go back to the pool.
                        conn.detach();
                    }
                    result
                }
            }
        })
    }
}
