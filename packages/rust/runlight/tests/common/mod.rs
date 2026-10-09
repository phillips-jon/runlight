//! What the tests share: the language-neutral fixtures, read from where the
//! PHP port and conformance/ keep them.

#![allow(dead_code)]

use runlight::js::{self, Value};

/// The repository's root.
pub fn root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// A fixture written from the TypeScript SDK, in packages/php/tests/fixtures.
pub fn fixture(name: &str) -> Value {
    let path = root().join(format!("packages/php/tests/fixtures/{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    js::parse(&text).expect("a fixture is JSON")
}

/// A file in conformance/.
pub fn conformance(name: &str) -> Value {
    let path = root().join(format!("conformance/{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    js::parse(&text).expect("a conformance file is JSON")
}

/// The items of an array in a value.
pub fn list<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

/// A string in a value, empty when it is not one.
pub fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

/// Values compared as JSON with keys sorted, as deepEqual compares them.
pub fn canonical(v: &Value) -> String {
    fn sorted(v: &Value) -> Value {
        match v {
            Value::Object(o) => {
                let mut keys: Vec<&str> = o.keys().collect();
                keys.sort();
                let mut out = js::Object::new();
                for k in keys {
                    out.set(k, sorted(o.get(k).unwrap()));
                }
                // Keys that are array indexes keep JavaScript's order; the rest are sorted.
                Value::Object(out)
            }
            Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
            other => other.clone(),
        }
    }
    js::stringify(&sorted(v))
}
