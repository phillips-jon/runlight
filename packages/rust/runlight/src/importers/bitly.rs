//! Bitly (importers/bitly.ts). Links are listed per group (every group in the account), with archived
//! ones. Bitly only keeps daily click counts, and only as far back as the account's plan allows. A custom
//! back-half or branded domain wins over the random bit.ly one. https://dev.bitly.com/api-reference

use super::http::{Http, or_now, parse_value};
use super::types::{
    ImportError, Importer, StepInput, field, filled, foreign_link, items, known_link, nullish, or, set_opt,
    step_answer, text,
};
use super::visits::object_of;
use crate::BoxFuture;
use crate::js::{self, Object, Value};
use crate::re::{js_re, replace_first};
use crate::sources::encode_uri_component;

const BASE: &str = "https://api-ssl.bitly.com/v4";
const PAGE: usize = 20;

/// A short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale".
fn split(value: &str) -> (String, String) {
    let bare = replace_first(js_re!(r"^https?://"), value, "");
    match bare.find('/') {
        None => (bare, String::new()),
        Some(at) => (bare[..at].to_string(), replace_first(js_re!(r"/$"), &bare[at + 1..], "")),
    }
}

/// Bitly's links.
pub struct Bitly;

impl Importer for Bitly {
    fn step<'a>(&'a self, http: &'a Http, input: StepInput<'a>) -> BoxFuture<'a, Result<Value, ImportError>> {
        Box::pin(async move {
            let Some(token) = filled(input.credentials, "token").or_else(|| filled(input.credentials, "apiKey")) else {
                return Err(ImportError::new("Enter a Bitly access token", "import_key", &[("service", "Bitly")]));
            };
            let auth = format!("Bearer {token}");
            let headers = [("authorization", auth.as_str())];
            let state: Object = match input.cursor.filter(|c| !c.is_empty()) {
                Some(c) => match js::parse(c).map_err(|e| ImportError::other(format!("SyntaxError: {e}")))? {
                    Value::Object(o) => o,
                    Value::Null => return Err(ImportError::other("TypeError: Cannot read properties of null")),
                    _ => Object::new(),
                },
                None => {
                    let body = http.get(&format!("{BASE}/groups"), &headers).await?;
                    let mut groups = Vec::new();
                    for g in items(field(Some(&body), "groups"), "groups")? {
                        groups.push(field(object_of(Some(g))?, "guid").cloned().unwrap_or(Value::Null));
                    }
                    let mut o = Object::new();
                    o.set("groups", Value::Array(groups));
                    o.set("g", 0);
                    o.set("after", Value::Null);
                    o
                }
            };
            let groups = object_of(state.get("groups"))?;
            let g = state.get("g");
            let group = field(groups, &super::write::tpl(g));
            if !js::opt_truthy(group) {
                return Ok(step_answer(None, Some(Value::Null), vec![]));
            }

            let after = state.get("after");
            let after = if js::opt_truthy(after) {
                format!("&search_after={}", encode_uri_component(&super::write::tpl(after)))
            } else {
                String::new()
            };
            let page = http
                .get(
                    &format!("{BASE}/groups/{}/bitlinks?size={PAGE}&archived=both{after}", super::write::tpl(group)),
                    &headers,
                )
                .await?;
            let list = items(field(Some(&page), "links"), "links")?;

            let mut links = Vec::new();
            for b in list {
                let b = object_of(Some(b))?;
                if js::opt_truthy(field(b, "is_deleted")) {
                    continue;
                }
                let id = field(b, "id");
                let long_url = field(b, "long_url");
                let short = nullish(field(field(b, "custom_bitlinks"), "0"), id);
                let (domain, slug) = split(&super::write::tpl(short));
                if (input.known)(super::write::tpl(id), Some(slug.clone()), super::types::arg(long_url)).await? {
                    links.push(known_link(id.cloned(), text(""), text(""), long_url.cloned()));
                    continue;
                }
                let read = async {
                    let clicks = http
                        .get(
                            &format!(
                                "{BASE}/bitlinks/{}/clicks?unit=day&units=-1",
                                encode_uri_component(&super::write::tpl(id))
                            ),
                            &headers,
                        )
                        .await?;
                    let mut out = Vec::new();
                    for c in items(field(Some(&clicks), "link_clicks"), "link_clicks")? {
                        let c = object_of(Some(c))?;
                        let count = field(c, "clicks");
                        if count.map_or(f64::NAN, js::js_number) > 0.0 {
                            let day = match field(c, "date") {
                                Some(Value::String(s)) => js::head16(s, 10),
                                _ => return Err(ImportError::other("TypeError: date.slice is not a function")),
                            };
                            out.push(crate::obj! { "day" => day, "clicks" => count.cloned().unwrap_or(Value::Null) });
                        }
                    }
                    Ok::<_, ImportError>(out)
                };
                // Plans without analytics refuse this; the link still comes across.
                let daily = match read.await {
                    Ok(d) => Some(d),
                    Err(e) if e.is_http() && e.status() != Some(401) => None,
                    Err(e) => return Err(e),
                };
                let name = or(field(b, "title"), None).cloned().unwrap_or_else(|| Value::from(""));
                let created = or_now(parse_value(field(b, "created_at")), input.now);
                let mut item =
                    foreign_link(id.cloned(), text(&slug), text(&domain), Some(name), long_url.cloned(), created);
                set_opt(&mut item, "daily", daily.map(Value::Array));
                links.push(Value::Object(item));
            }

            let next = field(field(Some(&page), "pagination"), "search_after").filter(|v| js::truthy(v));
            let more = match next {
                Some(next) if list.len() == PAGE => Some(state.clone().with("after", next.clone())),
                _ => {
                    let g = g.map_or(f64::NAN, js::js_number) + 1.0;
                    let count = match groups {
                        Some(Value::Array(a)) => a.len() as f64,
                        Some(Value::String(s)) => js::len16(s) as f64,
                        _ => f64::NAN,
                    };
                    (g < count).then(|| state.clone().with("g", g).with("after", Value::Null))
                }
            };
            Ok(step_answer(more.map(|m| js::stringify(&Value::Object(m))), Some(Value::Null), links))
        })
    }
}
