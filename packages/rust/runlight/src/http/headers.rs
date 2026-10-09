//! Headers as the Fetch API's `Headers` holds them.

/// Header names matched without regard to case, as the Fetch API's
/// `Headers` are. `get` joins repeated values with `", "`; Set-Cookie is kept
/// apart, since its values may hold commas, and read back with
/// `get_set_cookie`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Headers {
    /// Lowercase name and its values, in the order names were first set.
    values: Vec<(String, Vec<String>)>,
}

impl Headers {
    /// No headers.
    pub fn new() -> Headers {
        Headers::default()
    }

    /// Headers from name and value pairs, each appended.
    pub fn from_pairs<K: AsRef<str>, V: AsRef<str>>(pairs: impl IntoIterator<Item = (K, V)>) -> Headers {
        let mut h = Headers::new();
        for (k, v) in pairs {
            h.append(k.as_ref(), v.as_ref());
        }
        h
    }

    /// `set`, returning the headers, for building them in a line.
    pub fn with(mut self, name: &str, value: impl AsRef<str>) -> Headers {
        self.set(name, value.as_ref());
        self
    }

    /// Every value of the header joined with `", "`, or `None`.
    pub fn get(&self, name: &str) -> Option<String> {
        let name = name.to_ascii_lowercase();
        self.values.iter().find(|(n, _)| *n == name).map(|(_, v)| v.join(", "))
    }

    /// Whether the header is there.
    pub fn has(&self, name: &str) -> bool {
        let name = name.to_ascii_lowercase();
        self.values.iter().any(|(n, _)| *n == name)
    }

    /// Gives the header this one value.
    pub fn set(&mut self, name: &str, value: &str) {
        let name = name.to_ascii_lowercase();
        let value = clean(value);
        match self.values.iter_mut().find(|(n, _)| *n == name) {
            Some(entry) => entry.1 = vec![value],
            None => self.values.push((name, vec![value])),
        }
    }

    /// Adds a value to the header.
    pub fn append(&mut self, name: &str, value: &str) {
        let name = name.to_ascii_lowercase();
        let value = clean(value);
        match self.values.iter_mut().find(|(n, _)| *n == name) {
            Some(entry) => entry.1.push(value),
            None => self.values.push((name, vec![value])),
        }
    }

    /// Removes the header.
    pub fn delete(&mut self, name: &str) {
        let name = name.to_ascii_lowercase();
        self.values.retain(|(n, _)| *n != name);
    }

    /// The Set-Cookie values, each apart.
    pub fn get_set_cookie(&self) -> Vec<String> {
        self.values.iter().find(|(n, _)| n == "set-cookie").map(|(_, v)| v.clone()).unwrap_or_default()
    }

    /// Every name with its values, in the order names were first set.
    pub fn all(&self) -> &[(String, Vec<String>)] {
        &self.values
    }

    /// Name and joined value pairs in name order, as iterating Fetch
    /// `Headers` gives them; each Set-Cookie on its own.
    pub fn entries(&self) -> Vec<(String, String)> {
        let mut names: Vec<&(String, Vec<String>)> = self.values.iter().collect();
        names.sort_by(|a, b| a.0.cmp(&b.0));
        let mut out = Vec::new();
        for (name, values) in names {
            if name == "set-cookie" {
                for v in values {
                    out.push((name.clone(), v.clone()));
                }
            } else {
                out.push((name.clone(), values.join(", ")));
            }
        }
        out
    }

    /// Whether there are none.
    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }
}

/// Header values never carry a line break, so nothing a caller passes can add
/// a header of its own; the space Fetch trims goes too.
fn clean(value: &str) -> String {
    let v: String = value.chars().filter(|c| !matches!(c, '\r' | '\n' | '\0')).collect();
    v.trim_matches(|c| c == ' ' || c == '\t').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers_read_as_fetch_reads_them() {
        let mut h = Headers::new();
        h.append("Accept", "a");
        h.append("accept", "b");
        h.append("Set-Cookie", "x=1, y");
        h.append("set-cookie", "z=2");
        h.set("X-Test", " v\r\n ");
        assert_eq!(h.get("ACCEPT").as_deref(), Some("a, b"));
        assert_eq!(h.get_set_cookie(), vec!["x=1, y", "z=2"]);
        assert_eq!(h.get("x-test").as_deref(), Some("v"));
        assert_eq!(h.entries()[0], ("accept".to_string(), "a, b".to_string()));
        h.delete("accept");
        assert!(!h.has("Accept"));
    }
}
