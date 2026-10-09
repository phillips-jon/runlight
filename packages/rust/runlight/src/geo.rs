//! Where a visitor is, from the headers a hosting platform adds or a lookup
//! of the app's choosing. Only the country, region, and city are kept.

use std::sync::Arc;

use base64::Engine;

use crate::http::Headers;
use crate::js::{self, Value};
use crate::re::{js_re, test};
use crate::sources::decode_uri_component;
use crate::{BoxError, BoxFuture};

/// A place.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Location {
    /// ISO 3166-1 alpha-2, upper case.
    pub country: String,
    /// ISO 3166-2, such as "US-CA".
    pub region: String,
    /// The city.
    pub city: String,
}

/// What a lookup found, any part of it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Found {
    /// The country code.
    pub country: Option<String>,
    /// The region's code or name.
    pub region: Option<String>,
    /// The city.
    pub city: Option<String>,
}

/// Looks a client IP up in a database of the app's choosing, such as an
/// MMDB file ([`crate::mmdb::Mmdb`] is one).
pub trait GeoLookup: Send + Sync {
    /// The place an address is in, if known.
    fn lookup<'a>(&'a self, ip: &'a str) -> BoxFuture<'a, Result<Option<Found>, BoxError>>;
}

/// A shared lookup.
pub type SharedGeo = Arc<dyn GeoLookup>;

/// A lookup from a plain function.
pub fn geo_fn<F>(f: F) -> SharedGeo
where
    F: Fn(&str) -> Option<Found> + Send + Sync + 'static,
{
    struct FnGeo<F>(F);
    impl<F: Fn(&str) -> Option<Found> + Send + Sync> GeoLookup for FnGeo<F> {
        fn lookup<'a>(&'a self, ip: &'a str) -> BoxFuture<'a, Result<Option<Found>, BoxError>> {
            let found = (self.0)(ip);
            Box::pin(async move { Ok(found) })
        }
    }
    Arc::new(FnGeo(f))
}

fn decode(value: Option<String>) -> String {
    match value {
        None => String::new(),
        Some(v) if v.is_empty() => String::new(),
        Some(v) => match decode_uri_component(&v) {
            Some(text) => js::trim(&text).to_string(),
            None => js::trim(&v).to_string(),
        },
    }
}

/// A place as it is kept: a country code or nothing, a region as ISO 3166-2
/// where it is a code, and a city only with a country.
pub fn clean(location: &Found) -> Location {
    let mut country = js::head16(&location.country.clone().unwrap_or_default().to_uppercase(), 2);
    if !test(js_re!(r"^[A-Z]{2}$"), &country) || country == "XX" || country == "T1" {
        country = String::new();
    }
    // A code ("CA", "US-CA") is kept as ISO 3166-2; a name from a database
    // that has no codes ("California") is kept readable, as "US-California".
    let raw = js::trim(location.region.as_deref().unwrap_or("")).to_string();
    let mut region = if test(js_re!(r"^([A-Za-z]{2}-)?[A-Za-z0-9]{1,3}$"), &raw) {
        raw.to_uppercase()
    } else {
        js::head16(&raw, 80)
    };
    if !region.is_empty() && !test(js_re!(r"^[A-Z]{2}-"), &region) && !country.is_empty() {
        region = format!("{country}-{region}");
    }
    if country.is_empty() {
        region = String::new();
    }
    let city = if country.is_empty() { String::new() } else { js::head16(location.city.as_deref().unwrap_or(""), 100) };
    Location { country, region, city }
}

/// Location from the headers a hosting platform adds, if any.
pub fn location_from_headers(headers: &Headers) -> Option<Location> {
    if let Some(vercel) = headers.get("x-vercel-ip-country").filter(|v| !v.is_empty()) {
        return Some(clean(&Found {
            country: Some(vercel),
            region: Some(decode(headers.get("x-vercel-ip-country-region"))),
            city: Some(decode(headers.get("x-vercel-ip-city"))),
        }));
    }
    if let Some(cloudflare) = headers.get("cf-ipcountry").filter(|v| !v.is_empty()) {
        return Some(clean(&Found {
            country: Some(cloudflare),
            region: Some(decode(headers.get("cf-region-code"))),
            city: Some(decode(headers.get("cf-ipcity"))),
        }));
    }
    if let Some(netlify) = headers.get("x-nf-geo").filter(|v| !v.is_empty()) {
        // atob gives one character per byte.
        let text: String = atob(&netlify)?.iter().map(|b| char::from(*b)).collect();
        let geo = js::parse(&text).ok()?;
        // `null.country` throws, and so does `.toUpperCase()` or `.trim()` on anything but text: either
        // way the headers say nothing.
        if geo.is_null() {
            return None;
        }
        let field = |v: Option<&Value>| match v {
            None | Some(Value::Null) => Ok(String::new()),
            Some(Value::String(s)) => Ok(s.clone()),
            Some(_) => Err(()),
        };
        let country = field(geo.get("country").and_then(|c| c.get("code"))).ok()?;
        let region = field(geo.get("subdivision").and_then(|c| c.get("code"))).ok()?;
        let city = field(geo.get("city"));
        let mut found = clean(&Found { country: Some(country), region: Some(region), city: Some(String::new()) });
        // The city is read only once there is a country.
        if !found.country.is_empty() {
            found.city = js::head16(&city.ok()?, 100);
        }
        return Some(found);
    }
    None
}

/// `atob`: base64 with ASCII whitespace skipped and the padding optional.
pub fn atob(text: &str) -> Option<Vec<u8>> {
    use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
    const LENIENT: GeneralPurpose = GeneralPurpose::new(
        &base64::alphabet::STANDARD,
        GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
    );
    let clean: String = text.chars().filter(|c| !matches!(c, ' ' | '\t' | '\n' | '\x0c' | '\r')).collect();
    LENIENT.decode(clean).ok()
}

/// Where a request came from: the platform's headers, else the lookup.
pub async fn locate(headers: &Headers, ip: &str, lookup: Option<&SharedGeo>) -> Location {
    if let Some(found) = location_from_headers(headers)
        && !found.country.is_empty()
    {
        return found;
    }
    if let Some(lookup) = lookup
        && !ip.is_empty()
    {
        // A broken lookup must never lose the event.
        if let Ok(Some(found)) = lookup.lookup(ip).await {
            return clean(&found);
        }
    }
    Location::default()
}
