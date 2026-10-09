//! What the port needs of JavaScript's own behaviour, so that every value
//! the SDK writes, compares, or counts is written, compared, and counted the
//! same way here: numbers as `Number.prototype.toString` prints them,
//! `JSON.stringify` and `JSON.parse` (objects keep JavaScript's key order),
//! string lengths and cuts in UTF-16 code units, the characters `\s`
//! matches, `Date`'s calendar arithmetic, and how `String()`, `Number()`,
//! and truthiness read a JSON value.
//!
//! Carried over from the CronWatch Rust port's `js` module.

mod date;
mod json;
mod number;
mod text;
mod value;

pub use date::*;
pub use json::{JsonError, Object, Value, parse, quote, stringify};
pub use number::*;
pub use text::*;
pub use value::*;

/// Builds a JSON object in the order its keys are written, as a JavaScript
/// object literal is: `obj! { "ok" => true, "count" => 3 }`.
#[macro_export]
macro_rules! obj {
    () => { $crate::js::Value::Object($crate::js::Object::new()) };
    ($($k:expr => $v:expr),+ $(,)?) => {{
        let mut o = $crate::js::Object::new();
        $( o.set($k, $crate::js::Value::from($v)); )+
        $crate::js::Value::Object(o)
    }};
}

/// Builds a JSON array: `arr![1, "two"]`.
#[macro_export]
macro_rules! arr {
    () => { $crate::js::Value::Array(Vec::new()) };
    ($($v:expr),+ $(,)?) => { $crate::js::Value::Array(vec![$($crate::js::Value::from($v)),+]) };
}
