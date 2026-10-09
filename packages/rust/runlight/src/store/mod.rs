//! Runlight's tables: the database driver a store needs ([`Db`]), the rows
//! it keeps, and [`SqlStore`], the same tables and statements as the
//! TypeScript SDK's store on SQLite, Postgres, and MySQL or MariaDB. The
//! drivers over sqlx are the runlight-sqlx crate.

mod db;
mod rows;
pub(crate) mod sql;
mod sql_store;

pub use db::*;
pub use rows::*;
pub use sql::{BOUNCE_MS, EVENT_TAIL_MS, JOURNEY_VISITS, MYSQL_COLLATION, js_order};
pub use sql_store::SqlStore;
