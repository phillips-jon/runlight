//! Short.io (importers/shortio.ts). Links are listed per domain. Daily click counts come from the
//! statistics API, paced to its limit of 60 requests a minute, so a step holds only a few links.
//! https://developers.short.io/reference

use super::http::{Http, iso_string, or_now, parse_value};
use super::types::{
    ImportError, Importer, StepInput, arg, field, filled, foreign_link, items, known_link, nullish, or, set_opt,
    step_answer, text,
};
use super::visits::object_of;
use crate::BoxFuture;
use crate::js::{self, Object, Value};
use crate::sources::encode_uri_component;

const API: &str = "https://api.short.io";
const STATS: &str = "https://statistics.short.io/statistics";
const PAGE: usize = 8;
/// The statistics API allows 60 requests a minute.
const STATS_GAP_MS: f64 = 1050.0;

/// Short.io's links.
pub struct Shortio;

impl Importer for Shortio {
    fn step<'a>(&'a self, http: &'a Http, input: StepInput<'a>) -> BoxFuture<'a, Result<Value, ImportError>> {
        Box::pin(async move {
            let Some(key) = filled(input.credentials, "apiKey") else {
                return Err(ImportError::new(
                    "Enter a Short.io secret API key",
                    "import_key",
                    &[("service", "Short.io")],
                ));
            };
            let headers = [("authorization", key)];
            let state: Object = match input.cursor.filter(|c| !c.is_empty()) {
                Some(c) => match js::parse(c).map_err(|e| ImportError::other(format!("SyntaxError: {e}")))? {
                    Value::Object(o) => o,
                    Value::Null => return Err(ImportError::other("TypeError: Cannot read properties of null")),
                    _ => Object::new(),
                },
                None => {
                    let body = http.get(&format!("{API}/api/domains?limit=300"), &headers).await?;
                    let mut domains = Vec::new();
                    for d in items(Some(&body), "domains")? {
                        let d = object_of(Some(d))?;
                        let mut o = Object::new();
                        set_opt(&mut o, "id", field(d, "id").cloned());
                        set_opt(&mut o, "hostname", field(d, "hostname").cloned());
                        domains.push(Value::Object(o));
                    }
                    let mut o = Object::new();
                    o.set("domains", Value::Array(domains));
                    o.set("d", 0);
                    o.set("token", Value::Null);
                    o.set("total", Value::Null);
                    o
                }
            };
            let domains = object_of(state.get("domains"))?;
            let d = state.get("d");
            let domain = field(domains, &super::write::tpl(d));
            if !js::opt_truthy(domain) {
                return Ok(step_answer(None, Some(Value::Null), vec![]));
            }

            let token = state.get("token");
            let token = if js::opt_truthy(token) {
                format!("&pageToken={}", encode_uri_component(&super::write::tpl(token)))
            } else {
                String::new()
            };
            let page = http
                .get(
                    &format!(
                        "{API}/api/links?domain_id={}&limit={PAGE}{token}",
                        super::write::tpl(field(domain, "id"))
                    ),
                    &headers,
                )
                .await?;

            let mut links = Vec::new();
            for l in items(field(Some(&page), "links"), "links")? {
                let l = object_of(Some(l))?;
                let id = super::write::tpl(nullish(field(l, "idString"), field(l, "id")));
                let (slug, url) = (field(l, "path"), field(l, "originalURL"));
                if (input.known)(id.clone(), arg(slug), arg(url)).await? {
                    links.push(known_link(text(&id), slug.cloned(), text(""), url.cloned()));
                    continue;
                }
                let read = async {
                    http.pause(STATS_GAP_MS).await;
                    let body = js::stringify(
                        &crate::obj! { "period" => "total", "clicksChartInterval" => "day", "tz" => "UTC" },
                    );
                    let body = http
                        .get_json(
                            &format!("{STATS}/link/{}/by_interval", encode_uri_component(&id)),
                            "POST",
                            &[("authorization", key), ("content-type", "application/json")],
                            Some(&body),
                        )
                        .await?;
                    let raw = field(Some(&body), "clickStatistics");
                    let empty = Value::Array(vec![]);
                    let points = match raw {
                        Some(Value::Array(_)) => raw.unwrap_or(&empty),
                        _ => nullish(field(field(field(raw, "datasets"), "0"), "data"), Some(&empty)).unwrap_or(&empty),
                    };
                    let mut out = Vec::new();
                    for p in items(Some(points), "points")? {
                        let p = object_of(Some(p))?;
                        let y = field(p, "y");
                        if y.map_or(f64::NAN, js::js_number) > 0.0 {
                            let ms = match field(p, "x") {
                                Some(Value::Number(n)) => *n,
                                x => parse_value(x),
                            };
                            let day = js::head16(&iso_string(ms)?, 10);
                            out.push(crate::obj! { "day" => day, "clicks" => y.cloned().unwrap_or(Value::Null) });
                        }
                    }
                    Ok::<_, ImportError>(out)
                };
                let daily = match read.await {
                    Ok(d) => Some(d),
                    Err(e) if e.is_http() && e.status() != Some(401) => None,
                    Err(e) => return Err(e),
                };
                let name = or(field(l, "title"), None).cloned().unwrap_or_else(|| Value::from(""));
                let created = or_now(parse_value(field(l, "createdAt")), input.now);
                let mut item = foreign_link(
                    text(&id),
                    slug.cloned(),
                    field(domain, "hostname").cloned(),
                    Some(name),
                    url.cloned(),
                    created,
                );
                set_opt(&mut item, "daily", daily.map(Value::Array));
                links.push(Value::Object(item));
            }

            let next = field(Some(&page), "nextPageToken").filter(|v| js::truthy(v));
            let more = match next {
                Some(next) => Some(state.clone().with("token", next.clone())),
                None => {
                    let d = d.map_or(f64::NAN, js::js_number) + 1.0;
                    let count = match domains {
                        Some(Value::Array(a)) => a.len() as f64,
                        _ => f64::NAN,
                    };
                    (d < count).then(|| state.clone().with("d", d).with("token", Value::Null))
                }
            };
            Ok(step_answer(more.map(|m| js::stringify(&Value::Object(m))), Some(Value::Null), links))
        })
    }
}
