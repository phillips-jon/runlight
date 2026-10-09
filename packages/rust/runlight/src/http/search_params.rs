//! JavaScript's `URLSearchParams`.

/// Query parameters as `URLSearchParams` reads and writes them: pairs kept
/// in order, `+` read as a space, bytes that are not UTF-8 read as U+FFFD,
/// and written back in the application/x-www-form-urlencoded form.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SearchParams {
    pairs: Vec<(String, String)>,
}

impl SearchParams {
    /// No pairs.
    pub fn new() -> SearchParams {
        SearchParams::default()
    }

    /// `new URLSearchParams(text)`: a leading `?` is skipped.
    pub fn parse(text: &str) -> SearchParams {
        let text = text.strip_prefix('?').unwrap_or(text);
        SearchParams { pairs: url::form_urlencoded::parse(text.as_bytes()).into_owned().collect() }
    }

    /// Form fields from a body's bytes, as `formData()` reads them.
    pub fn parse_bytes(bytes: &[u8]) -> SearchParams {
        SearchParams { pairs: url::form_urlencoded::parse(bytes).into_owned().collect() }
    }

    /// `new URLSearchParams(pairs)`.
    pub fn from_pairs<K: Into<String>, V: Into<String>>(pairs: impl IntoIterator<Item = (K, V)>) -> SearchParams {
        SearchParams { pairs: pairs.into_iter().map(|(k, v)| (k.into(), v.into())).collect() }
    }

    /// The first value of `name`.
    pub fn get(&self, name: &str) -> Option<&str> {
        self.pairs.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    /// Every value of `name`, in order.
    pub fn get_all(&self, name: &str) -> Vec<String> {
        self.pairs.iter().filter(|(k, _)| k == name).map(|(_, v)| v.clone()).collect()
    }

    /// Whether `name` is there.
    pub fn has(&self, name: &str) -> bool {
        self.pairs.iter().any(|(k, _)| k == name)
    }

    /// Replaces the first `name` and drops the rest, or appends it.
    pub fn set(&mut self, name: &str, value: &str) {
        let mut found = false;
        self.pairs.retain_mut(|(k, v)| {
            if k != name {
                return true;
            }
            if found {
                return false;
            }
            found = true;
            *v = value.to_string();
            true
        });
        if !found {
            self.pairs.push((name.to_string(), value.to_string()));
        }
    }

    /// Adds a pair.
    pub fn append(&mut self, name: &str, value: &str) {
        self.pairs.push((name.to_string(), value.to_string()));
    }

    /// Removes every pair named `name`.
    pub fn delete(&mut self, name: &str) {
        self.pairs.retain(|(k, _)| k != name);
    }

    /// The pairs, in order.
    pub fn pairs(&self) -> &[(String, String)] {
        &self.pairs
    }

    /// Whether there are none.
    pub fn is_empty(&self) -> bool {
        self.pairs.is_empty()
    }
}

impl std::fmt::Display for SearchParams {
    /// `toString()`: the form encoding, spaces as `+`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut s = url::form_urlencoded::Serializer::new(String::new());
        for (k, v) in &self.pairs {
            s.append_pair(k, v);
        }
        f.write_str(&s.finish())
    }
}
