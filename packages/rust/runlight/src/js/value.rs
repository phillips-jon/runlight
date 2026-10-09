//! How JavaScript reads a JSON value it was given: `String(v)`, `Number(v)`,
//! truthiness, and `typeof`. Request bodies and stored JSON are read through
//! these, so a value of an unexpected type is read as the SDK reads it.

use super::json::{Object, Value};
use super::{format_number, number_of_text};

impl Value {
    /// `value[key]` for an object, `None` (JavaScript's `undefined`) for a
    /// key that is not there or a value that is not an object.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(o) => o.get(key),
            _ => None,
        }
    }

    /// `value[key]`, with `undefined` read as `null`.
    pub fn at(&self, key: &str) -> &Value {
        static NULL: Value = Value::Null;
        self.get(key).unwrap_or(&NULL)
    }

    /// Whether this is an object that is not an array, as
    /// `value && typeof value === "object" && !Array.isArray(value)`.
    pub fn is_object(&self) -> bool {
        matches!(self, Value::Object(_))
    }

    /// Whether this is an array.
    pub fn is_array(&self) -> bool {
        matches!(self, Value::Array(_))
    }

    /// Whether this is a string.
    pub fn is_string(&self) -> bool {
        matches!(self, Value::String(_))
    }

    /// The object, mutably, when this is one.
    pub fn as_object_mut(&mut self) -> Option<&mut Object> {
        match self {
            Value::Object(o) => Some(o),
            _ => None,
        }
    }

    /// The array, mutably, when this is one.
    pub fn as_array_mut(&mut self) -> Option<&mut Vec<Value>> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }

    /// `typeof value === "number" && Number.isFinite(value)`.
    pub fn finite(&self) -> Option<f64> {
        match self {
            Value::Number(n) if n.is_finite() => Some(*n),
            _ => None,
        }
    }
}

/// `String(value)`: `"null"` for null, numbers as JavaScript prints them, an
/// array as its items joined with commas, an object as `[object Object]`.
pub fn js_string(value: &Value) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => format_number(*n),
        Value::String(s) => s.clone(),
        Value::Array(a) => {
            a.iter().map(|v| if v.is_null() { String::new() } else { js_string(v) }).collect::<Vec<_>>().join(",")
        }
        Value::Object(_) => "[object Object]".into(),
    }
}

/// `String(value ?? "")`: `undefined` and `null` as the empty string.
pub fn str_or_empty(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(v) => js_string(v),
    }
}

/// `Number(value)`: null and `false` are 0, `true` 1, text as JavaScript
/// reads it (empty text is 0), an array through its text, an object NaN.
pub fn js_number(value: &Value) -> f64 {
    match value {
        Value::Null => 0.0,
        Value::Bool(b) => f64::from(u8::from(*b)),
        Value::Number(n) => *n,
        Value::String(s) => text_number(s),
        Value::Array(_) => text_number(&js_string(value)),
        Value::Object(_) => f64::NAN,
    }
}

/// `Number(text)`: text empty once trimmed is 0, as JavaScript reads it.
pub fn text_number(s: &str) -> f64 {
    if super::trim(s).is_empty() { 0.0 } else { number_of_text(s) }
}

/// `Number(value)` for a value that may be `undefined` (NaN).
pub fn opt_number(value: Option<&Value>) -> f64 {
    value.map_or(f64::NAN, js_number)
}

/// Whether JavaScript reads the value as true in a condition.
pub fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => *n != 0.0 && !n.is_nan(),
        Value::String(s) => !s.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

/// [`truthy`] for a value that may be `undefined`.
pub fn opt_truthy(value: Option<&Value>) -> bool {
    value.is_some_and(truthy)
}

/// `Math.round`: halves go up toward positive infinity.
pub fn round(x: f64) -> f64 {
    if !x.is_finite() {
        return x;
    }
    // The fraction is exact, where x + 0.5 can round up past it.
    let f = x.floor();
    if x - f >= 0.5 { f + 1.0 } else { f }
}

/// `Math.round` to a whole number, as the SDK keeps counts.
pub fn round_i64(x: f64) -> i64 {
    super::to_i64(round(x))
}

/// `parseInt(text, 10)`: leading space skipped, an optional sign, then the
/// digits there are; NaN when there are none.
pub fn parse_int(text: &str) -> f64 {
    let t = super::trim_start(text);
    let (sign, rest) = match t.as_bytes().first() {
        Some(b'-') => (-1.0, &t[1..]),
        Some(b'+') => (1.0, &t[1..]),
        _ => (1.0, t),
    };
    let digits: &str = &rest[..rest.bytes().take_while(u8::is_ascii_digit).count()];
    if digits.is_empty() {
        return f64::NAN;
    }
    sign * digits.parse::<f64>().unwrap_or(f64::NAN)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js::parse;

    #[test]
    fn values_read_as_javascript_reads_them() {
        let v = parse(r#"{"a":[1,null,"x"],"b":{},"c":"  12 ","d":"","e":true}"#).unwrap();
        assert_eq!(js_string(v.at("a")), "1,,x");
        assert_eq!(js_string(v.at("b")), "[object Object]");
        assert_eq!(js_string(v.at("zz")), "null");
        assert_eq!(str_or_empty(v.get("zz")), "");
        assert_eq!(js_number(v.at("c")), 12.0);
        assert_eq!(js_number(v.at("d")), 0.0);
        assert_eq!(js_number(v.at("e")), 1.0);
        assert!(js_number(v.at("b")).is_nan());
        assert!(opt_number(v.get("zz")).is_nan());
        assert!(truthy(v.at("b")));
        assert!(!truthy(v.at("d")));
        assert_eq!(round(-2.5), -2.0);
        assert_eq!(round(2.5), 3.0);
        assert_eq!(round(0.49999999999999994), 0.0);
        assert_eq!(parse_int(" 42px"), 42.0);
        assert!(parse_int("px").is_nan());
    }
}
