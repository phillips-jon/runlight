//! The dashboard, its locales and map, the tracker, and the element picker:
//! the TypeScript SDK's built files, copied into assets/ by
//! scripts/rust-assets.mts, so this crate serves the very same bytes.

use std::sync::LazyLock;

use crate::js::{self, Value};

/// The dashboard's script.
pub const DASHBOARD_JS: &str = include_str!("../assets/dashboard.js");
/// The dashboard's style sheet.
pub const DASHBOARD_CSS: &str = include_str!("../assets/dashboard.css");
/// The world map the dashboard draws countries on.
pub const WORLD_JSON: &str = include_str!("../assets/world.json");
/// The tracker, with its click rules still a placeholder.
pub const TRACKER: &str = include_str!("../assets/tracker.js");
/// The element picker, with its target and hosts still placeholders.
pub const PICKER: &str = include_str!("../assets/picker.js");

const BUILD: &str = include_str!("../assets/build.json");
const LOCALES_JSON: &str = include_str!("../assets/locales.json");

/// The hashes and icon the build recorded.
pub struct Build {
    /// The dashboard's script and style sheet's hash.
    pub dashboard_hash: String,
    /// The world map's hash.
    pub world_hash: String,
    /// The locales' hash.
    pub locales_hash: String,
    /// The tracker's hash.
    pub tracker_hash: String,
}

/// What assets/build.json says.
pub static BUILD_INFO: LazyLock<Build> = LazyLock::new(|| {
    let v = js::parse(BUILD).expect("assets/build.json is JSON");
    let s = |k: &str| js::str_or_empty(v.get(k));
    Build { dashboard_hash: s("dashboardHash"), world_hash: s("worldHash"), locales_hash: s("localesHash"), tracker_hash: s("trackerHash") }
});

/// Every language's messages as the JSON text the dashboard reads, English first, in the build's order.
pub static LOCALE_TEXTS: LazyLock<Vec<(String, String)>> = LazyLock::new(|| {
    let v = js::parse(LOCALES_JSON).expect("assets/locales.json is JSON");
    let Value::Object(o) = v else { return Vec::new() };
    o.iter().map(|(k, v)| (k.to_string(), js::str_or_empty(Some(v)))).collect()
});

/// The languages other than English the dashboard loads on demand (the SDK's `LOCALES`), and their text.
pub fn locales() -> impl Iterator<Item = &'static (String, String)> {
    LOCALE_TEXTS.iter().filter(|(k, _)| k != "en")
}
