//! The little a store needs from a database driver.

use std::sync::Arc;

use crate::BoxFuture;
use crate::js::{self, Value};

/// The SQL a database speaks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dialect {
    /// SQLite.
    Sqlite,
    /// Postgres.
    Postgres,
    /// MySQL 8.4 or MariaDB 11.4 and later.
    Mysql,
}

/// A statement's parameter, in the types a JavaScript driver binds.
#[derive(Clone, Debug, PartialEq)]
pub enum Param {
    /// NULL.
    Null,
    /// A whole number.
    Int(i64),
    /// A number with a fraction.
    Float(f64),
    /// Text.
    Text(String),
}

impl From<i64> for Param {
    fn from(n: i64) -> Param {
        Param::Int(n)
    }
}
impl From<i32> for Param {
    fn from(n: i32) -> Param {
        Param::Int(i64::from(n))
    }
}
impl From<usize> for Param {
    fn from(n: usize) -> Param {
        Param::Int(n as i64)
    }
}
impl From<f64> for Param {
    /// A JavaScript number: whole ones are bound as integers, as the drivers bind them.
    fn from(n: f64) -> Param {
        if js::is_integer(n) && n.abs() < 9.007_199_254_740_992e15 { Param::Int(n as i64) } else { Param::Float(n) }
    }
}
impl From<&str> for Param {
    fn from(s: &str) -> Param {
        Param::Text(s.to_string())
    }
}
impl From<String> for Param {
    fn from(s: String) -> Param {
        Param::Text(s)
    }
}
impl From<&String> for Param {
    fn from(s: &String) -> Param {
        Param::Text(s.clone())
    }
}
impl<T: Into<Param>> From<Option<T>> for Param {
    fn from(v: Option<T>) -> Param {
        v.map_or(Param::Null, Into::into)
    }
}

/// Builds a parameter list: `params![site, from, to]`.
#[macro_export]
macro_rules! params {
    () => { Vec::<$crate::store::Param>::new() };
    ($($v:expr),+ $(,)?) => { vec![$($crate::store::Param::from($v)),+] };
}

/// A column's value, as the driver gave it.
#[derive(Clone, Debug, PartialEq)]
pub enum Cell {
    /// NULL.
    Null,
    /// A whole number.
    Int(i64),
    /// A number with a fraction.
    Float(f64),
    /// Text, as which some drivers give big numbers too.
    Text(String),
}

impl Cell {
    /// The value as JavaScript holds what its driver gave it.
    pub fn to_value(&self) -> Value {
        match self {
            Cell::Null => Value::Null,
            Cell::Int(n) => Value::Number(*n as f64),
            Cell::Float(f) => Value::Number(*f),
            Cell::Text(s) => Value::String(s.clone()),
        }
    }
}

/// One row, its columns by name.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Row(pub Vec<(String, Cell)>);

static NULL: Cell = Cell::Null;

impl Row {
    /// A column, NULL when there is none by that name.
    pub fn get(&self, name: &str) -> &Cell {
        self.0.iter().find(|(n, _)| n == name).map_or(&NULL, |(_, c)| c)
    }

    /// Whether the column is NULL or missing.
    pub fn is_null(&self, name: &str) -> bool {
        matches!(self.get(name), Cell::Null)
    }

    /// `num(row[name])`: `Number(value ?? 0)`, and 0 for anything not finite.
    pub fn num(&self, name: &str) -> f64 {
        let n = match self.get(name) {
            Cell::Null => 0.0,
            Cell::Int(n) => *n as f64,
            Cell::Float(f) => *f,
            Cell::Text(t) => js::text_number(t),
        };
        if n.is_finite() { n } else { 0.0 }
    }

    /// [`Row::num`] as a whole number, for times and counts.
    pub fn int(&self, name: &str) -> i64 {
        js::to_i64(self.num(name))
    }

    /// `Number(row[name])`, NaN for NULL kept as `None`.
    pub fn opt_int(&self, name: &str) -> Option<i64> {
        if self.is_null(name) { None } else { Some(self.int(name)) }
    }

    /// `String(row[name])`: NULL is `"null"`.
    pub fn text(&self, name: &str) -> String {
        match self.get(name) {
            Cell::Null => "null".into(),
            Cell::Int(n) => n.to_string(),
            Cell::Float(f) => js::format_number(*f),
            Cell::Text(t) => t.clone(),
        }
    }

    /// `String(row[name] ?? fallback)`.
    pub fn text_or(&self, name: &str, fallback: &str) -> String {
        if self.is_null(name) { fallback.to_string() } else { self.text(name) }
    }

    /// The row as JavaScript holds it, its columns in order.
    pub fn to_value(&self) -> Value {
        let mut o = js::Object::new();
        for (name, cell) in &self.0 {
            o.set(name.clone(), cell.to_value());
        }
        Value::Object(o)
    }
}

/// A database that refused a statement, or could not be reached.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DbError(pub String);

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DbError {}

/// What a held connection is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hold {
    /// One transaction: committed by `finish(true)`, rolled back by `finish(false)`.
    Transaction,
    /// A database-wide lock, so two processes starting at once do not race to create the same
    /// tables; let go by `finish`.
    Exclusive,
}

/// The little a store needs from a database driver. SQL uses `?` placeholders and "double quotes"
/// around a name that is a keyword somewhere; a driver numbers the placeholders, or fills them in and
/// quotes names its own way, as the TypeScript drivers do.
pub trait Db: Send + Sync {
    /// The SQL the database speaks.
    fn dialect(&self) -> Dialect;

    /// Runs a query and gives its rows.
    fn all<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, DbError>>;

    /// Runs a statement and says how many rows it matched.
    fn run<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<u64, DbError>>;

    /// One connection, held for a transaction or a lock until `finish`. Statements on it run in
    /// turn with nothing else of the store's in between. Holding a transaction on a connection
    /// already in one joins it.
    fn hold(&self, kind: Hold) -> BoxFuture<'_, Result<Arc<dyn Db>, DbError>>;

    /// Ends what `hold` began: commits a transaction (`ok`) or rolls it back, or lets go of a lock.
    /// A connection that was not held answers Ok.
    fn finish(&self, _ok: bool) -> BoxFuture<'_, Result<(), DbError>> {
        Box::pin(async { Ok(()) })
    }

    /// True for a database reached one statement at a time over the network with a cap on
    /// statements per request (Cloudflare D1), so long jobs send fewer, larger pieces.
    fn metered(&self) -> bool {
        false
    }

    /// Lets the connections go.
    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(async {})
    }
}

/// SQL written with `?` placeholders and "double quoted" names, with each placeholder outside quotes
/// filled in by `fill`, as node-postgres and mysql2 send values in the statement's text. For MySQL,
/// a "quoted" name goes in backticks and a backslash inside 'text' is doubled, since MySQL reads it as
/// an escape where standard SQL takes it literally.
pub fn fill_placeholders(
    sql: &str,
    params: &[Param],
    mysql: bool,
    fill: impl Fn(&Param) -> String,
) -> Result<String, DbError> {
    let mut out = String::with_capacity(sql.len() + params.len() * 8);
    let mut n = 0;
    let mut quote: Option<char> = None;
    for ch in sql.chars() {
        if let Some(q) = quote {
            if ch == q {
                quote = None;
                out.push(if mysql && ch == '"' { '`' } else { ch });
            } else if mysql && q == '\'' && ch == '\\' {
                out.push_str("\\\\");
            } else if mysql && q == '"' && ch == '`' {
                out.push_str("``");
            } else {
                out.push(ch);
            }
        } else if ch == '\'' || ch == '"' || (mysql && ch == '`') {
            quote = Some(ch);
            out.push(if mysql && ch == '"' { '`' } else { ch });
        } else if ch == '?' {
            let p = params
                .get(n)
                .ok_or_else(|| DbError("Runlight: a statement has more placeholders than values".into()))?;
            out.push_str(&fill(p));
            n += 1;
        } else {
            out.push(ch);
        }
    }
    if n != params.len() {
        return Err(DbError("Runlight: a statement has more values than placeholders".into()));
    }
    Ok(out)
}

/// A value as a Postgres literal of unknown type, which the server reads as it reads a parameter
/// node-postgres sends untyped: `E'...'` text (backslashes and quotes escaped, whatever
/// standard_conforming_strings says), numbers too, and NULL.
pub fn postgres_literal(p: &Param) -> String {
    match p {
        Param::Null => "NULL".into(),
        Param::Int(n) => format!("'{n}'"),
        Param::Float(f) => format!("'{}'", js::format_number(*f)),
        Param::Text(s) => {
            let mut out = String::with_capacity(s.len() + 3);
            out.push_str("E'");
            for c in s.chars() {
                match c {
                    '\\' => out.push_str("\\\\"),
                    '\'' => out.push_str("''"),
                    _ => out.push(c),
                }
            }
            out.push('\'');
            out
        }
    }
}

/// A value as a MySQL literal, as mysql2's escape() writes the values Runlight binds, except that a
/// quote is doubled rather than escaped with a backslash, so a value stays inside its quotes even on a
/// connection whose sql_mode has NO_BACKSLASH_ESCAPES.
pub fn mysql_literal(p: &Param) -> String {
    match p {
        Param::Null => "NULL".into(),
        Param::Int(n) => n.to_string(),
        Param::Float(f) => js::format_number(*f),
        Param::Text(s) => {
            let mut out = String::with_capacity(s.len() + 2);
            out.push('\'');
            for c in s.chars() {
                match c {
                    '\0' => out.push_str("\\0"),
                    '\x08' => out.push_str("\\b"),
                    '\t' => out.push_str("\\t"),
                    '\x1a' => out.push_str("\\Z"),
                    '\n' => out.push_str("\\n"),
                    '\r' => out.push_str("\\r"),
                    '"' => out.push_str("\\\""),
                    '\'' => out.push_str("''"),
                    '\\' => out.push_str("\\\\"),
                    _ => out.push(c),
                }
            }
            out.push('\'');
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholders_are_filled_outside_quotes() {
        let sql = r#"SELECT "key", 'a?b\c' FROM t WHERE x = ? AND y LIKE ? ESCAPE '\'"#;
        let params = vec![Param::Int(3), Param::Text("o'k\\".into())];
        assert_eq!(
            fill_placeholders(sql, &params, true, mysql_literal).unwrap(),
            r#"SELECT `key`, 'a?b\\c' FROM t WHERE x = 3 AND y LIKE 'o''k\\' ESCAPE '\\'"#
        );
        assert_eq!(
            fill_placeholders(sql, &params, false, postgres_literal).unwrap(),
            r#"SELECT "key", 'a?b\c' FROM t WHERE x = '3' AND y LIKE E'o''k\\' ESCAPE '\'"#
        );
        assert!(fill_placeholders("?", &[], false, postgres_literal).is_err());
    }
}
