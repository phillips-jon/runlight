//! Rows as the store reads them, whatever database gave them: each column by
//! name, its value as the database's JavaScript driver gives it (a whole
//! number, a fraction, text, or NULL).

#![cfg_attr(not(any(feature = "sqlite", feature = "postgres", feature = "mysql")), allow(dead_code, unused_imports))]

use runlight::store::{Cell, DbError, Row};

/// A driver's error as the store's.
pub(crate) fn db_error(e: impl std::fmt::Display) -> DbError {
    DbError(e.to_string())
}

#[cfg(feature = "sqlite")]
pub(crate) fn sqlite_row(row: &sqlx::sqlite::SqliteRow) -> Result<Row, DbError> {
    use sqlx::{Column, Row as _, TypeInfo, ValueRef};
    let mut out = Vec::with_capacity(row.len());
    for (i, column) in row.columns().iter().enumerate() {
        let raw = row.try_get_raw(i).map_err(db_error)?;
        let cell = if raw.is_null() {
            Cell::Null
        } else {
            match raw.type_info().name() {
                "INTEGER" => Cell::Int(row.try_get_unchecked::<i64, _>(i).map_err(db_error)?),
                "REAL" => Cell::Float(row.try_get_unchecked::<f64, _>(i).map_err(db_error)?),
                // Text read as bytes, so one value that is not UTF-8 reads with U+FFFD, as the SDK reads
                // it, rather than failing every read its row is part of.
                _ => Cell::Text(
                    String::from_utf8_lossy(&row.try_get_unchecked::<Vec<u8>, _>(i).map_err(db_error)?).into_owned(),
                ),
            }
        };
        out.push((column.name().to_string(), cell));
    }
    Ok(Row(out))
}

/// A Postgres value from its bytes, in text (the simple protocol's form) or binary.
#[cfg(feature = "postgres")]
fn pg_cell(raw: sqlx::postgres::PgValueRef<'_>) -> Result<Cell, DbError> {
    use sqlx::postgres::PgValueFormat;
    use sqlx::{TypeInfo, ValueRef};
    if raw.is_null() {
        return Ok(Cell::Null);
    }
    let kind = raw.type_info().name().to_string();
    let bytes = raw.as_bytes().map_err(db_error)?;
    let binary = raw.format() == PgValueFormat::Binary;
    let text = || String::from_utf8_lossy(bytes).into_owned();
    let bad = || DbError(format!("Runlight: an unexpected {kind} value from Postgres"));
    Ok(match (kind.as_str(), binary) {
        ("INT2" | "INT4" | "INT8" | "OID", true) => Cell::Int(match bytes.len() {
            2 => i64::from(i16::from_be_bytes(bytes.try_into().map_err(|_| bad())?)),
            4 => i64::from(i32::from_be_bytes(bytes.try_into().map_err(|_| bad())?)),
            8 => i64::from_be_bytes(bytes.try_into().map_err(|_| bad())?),
            _ => return Err(bad()),
        }),
        ("INT2" | "INT4" | "INT8" | "OID", false) => {
            text().trim().parse().map(Cell::Int).unwrap_or_else(|_| Cell::Text(text()))
        }
        ("FLOAT4", true) => Cell::Float(f64::from(f32::from_be_bytes(bytes.try_into().map_err(|_| bad())?))),
        ("FLOAT8", true) => Cell::Float(f64::from_be_bytes(bytes.try_into().map_err(|_| bad())?)),
        ("FLOAT4" | "FLOAT8", false) => Cell::Float(runlight::js::number_of_text(&text())),
        ("BOOL", true) => Cell::Int(i64::from(bytes.first().is_some_and(|b| *b != 0))),
        ("BOOL", false) => Cell::Int(i64::from(bytes.first() == Some(&b't'))),
        _ => Cell::Text(text()),
    })
}

#[cfg(feature = "postgres")]
pub(crate) fn pg_row(row: &sqlx::postgres::PgRow) -> Result<Row, DbError> {
    use sqlx::{Column, Row as _};
    let mut out = Vec::with_capacity(row.len());
    for (i, column) in row.columns().iter().enumerate() {
        out.push((column.name().to_string(), pg_cell(row.try_get_raw(i).map_err(db_error)?)?));
    }
    Ok(Row(out))
}

/// A MySQL row. A `utf8mb4_0900_bin` column is flagged binary, so sqlx names its type `VARBINARY` or
/// `BLOB`: everything but numbers is read as bytes and taken as UTF-8. Sums and averages arrive as
/// DECIMAL, which is read as its text and taken as a number.
#[cfg(feature = "mysql")]
pub(crate) fn mysql_row(row: &sqlx::mysql::MySqlRow) -> Result<Row, DbError> {
    use sqlx::{Column, Row as _, TypeInfo, ValueRef};
    let mut out = Vec::with_capacity(row.len());
    for (i, column) in row.columns().iter().enumerate() {
        let raw = row.try_get_raw(i).map_err(db_error)?;
        let cell = if raw.is_null() {
            Cell::Null
        } else {
            let kind = raw.type_info().name().to_string();
            let bytes = || row.try_get_unchecked::<Vec<u8>, _>(i).map_err(db_error);
            match kind.trim_end_matches(" UNSIGNED") {
                "TINYINT" | "SMALLINT" | "MEDIUMINT" | "INT" | "BIGINT" | "YEAR" | "BOOLEAN" => {
                    Cell::Int(row.try_get_unchecked::<i64, _>(i).map_err(db_error)?)
                }
                "FLOAT" | "DOUBLE" => Cell::Float(row.try_get_unchecked::<f64, _>(i).map_err(db_error)?),
                "DECIMAL" => Cell::Float(runlight::js::number_of_text(&String::from_utf8_lossy(&bytes()?))),
                _ => Cell::Text(String::from_utf8_lossy(&bytes()?).into_owned()),
            }
        };
        out.push((column.name().to_string(), cell));
    }
    Ok(Row(out))
}
