//! Dub (importers/dub.ts). Links come from GET /links (cursor pages, archived included). Click history is
//! per click from /events where the plan allows, else daily counts from /analytics, else none; the
//! first link decides. https://dub.co/docs/api-reference

use super::http::{Http, or_now, parse_value};
use super::types::{
    ImportError, Importer, StepInput, arg, field, filled, foreign_link, items, known_link, or, set_opt, step_answer,
    text,
};
use super::visits::object_of;
use crate::BoxFuture;
use crate::js::{self, Object, Value};
use crate::sources::encode_uri_component;

const BASE: &str = "https://api.dub.co";
const PAGE: usize = 10;

/// Daily counts from a series of `{ start, clicks }` points: the days with clicks.
fn daily_of(series: &Value, day_key: &str) -> Result<Vec<Value>, ImportError> {
    let mut out = Vec::new();
    for p in items(Some(series), "series")? {
        let p = object_of(Some(p))?;
        let clicks = field(p, "clicks");
        if clicks.map_or(f64::NAN, js::js_number) > 0.0 {
            let day = match field(p, day_key) {
                Some(Value::String(s)) => js::head16(s, 10),
                _ => return Err(ImportError::other(format!("TypeError: {day_key}.slice is not a function"))),
            };
            out.push(crate::obj! { "day" => day, "clicks" => clicks.cloned().unwrap_or(Value::Null) });
        }
    }
    Ok(out)
}

/// Whether Dub said the plan does not include what was asked (403, or 402). Any other failure (a server
/// error that outlasts the retries, say) fails the step and leaves the history mode as it was.
fn plan_refused(error: &ImportError) -> bool {
    matches!(error.status(), Some(403 | 402))
}

/// Dub's links.
pub struct Dub;

impl Importer for Dub {
    fn step<'a>(&'a self, http: &'a Http, input: StepInput<'a>) -> BoxFuture<'a, Result<Value, ImportError>> {
        Box::pin(async move {
            let Some(key) = filled(input.credentials, "apiKey") else {
                return Err(ImportError::new("Enter a Dub API key", "import_key", &[("service", "Dub")]));
            };
            let auth = format!("Bearer {key}");
            let headers = [("authorization", auth.as_str())];
            let state = match input.cursor.filter(|c| !c.is_empty()) {
                Some(c) => js::parse(c).map_err(|e| ImportError::other(format!("SyntaxError: {e}")))?,
                None => crate::obj! { "after" => Value::Null, "history" => Value::Null },
            };
            let state = object_of(Some(&state))?;
            // What the account's plan lets us read: every click (Business), daily counts (Pro), or neither
            // (Free). `None` is undefined, from a cursor without it.
            let mut history: Option<Value> = field(state, "history").cloned();
            let after = field(state, "after");
            let after = if js::opt_truthy(after) {
                format!("&startingAfter={}", encode_uri_component(&super::write::tpl(after)))
            } else {
                String::new()
            };
            let list = http.get(&format!("{BASE}/links?pageSize={PAGE}&showArchived=true{after}"), &headers).await?;
            let list = items(Some(&list), "links")?;

            let is = |h: &Option<Value>, s: &str| matches!(h, Some(Value::String(v)) if v == s);
            let mut links = Vec::new();
            for l in list {
                let l = object_of(Some(l))?;
                let (id, slug, url) = (field(l, "id"), field(l, "key"), field(l, "url"));
                if (input.known)(super::write::tpl(id), arg(slug), arg(url)).await? {
                    links.push(known_link(id.cloned(), slug.cloned(), text(""), url.cloned()));
                    continue;
                }
                let link_id = encode_uri_component(&super::write::tpl(id));
                let mut clicks: Option<Vec<Value>> = None;
                let mut daily: Option<Vec<Value>> = None;
                if matches!(history, Some(Value::Null)) || is(&history, "events") {
                    let read = async {
                        let mut out = Vec::new();
                        let mut page = 1;
                        loop {
                            let events = http
                                .get(
                                    &format!("{BASE}/events?event=clicks&linkId={link_id}&interval=all&sortOrder=asc&limit=1000&page={page}"),
                                    &headers,
                                )
                                .await?;
                            let events = items(Some(&events), "events")?;
                            for e in events {
                                let e = object_of(Some(e))?;
                                let click = field(e, "click");
                                let c = |k: &str| field(click, k);
                                let referer = c("referer");
                                let fallback =
                                    if js::opt_truthy(referer) && referer.and_then(Value::as_str) != Some("(direct)") {
                                        Value::from(format!("https://{}/", super::write::tpl(referer)))
                                    } else {
                                        Value::from("")
                                    };
                                let referrer = or(c("refererUrl"), None).cloned().unwrap_or(fallback);
                                let device = match c("device") {
                                    None | Some(Value::Null) => None,
                                    Some(Value::String(s)) => Some(Value::from(s.to_lowercase())),
                                    Some(_) => {
                                        return Err(ImportError::other("TypeError: toLowerCase is not a function"));
                                    }
                                };
                                let mut o = Object::new();
                                o.set("ts", parse_value(field(e, "timestamp")));
                                set_opt(&mut o, "visit", c("id").cloned());
                                o.set("referrer", referrer);
                                set_opt(&mut o, "country", c("country").cloned());
                                set_opt(&mut o, "region", c("region").cloned());
                                set_opt(&mut o, "city", c("city").cloned());
                                set_opt(&mut o, "device", device);
                                set_opt(&mut o, "browser", c("browser").cloned());
                                set_opt(&mut o, "os", c("os").cloned());
                                out.push(Value::Object(o));
                            }
                            if events.len() < 1000 {
                                return Ok::<_, ImportError>(out);
                            }
                            page += 1;
                        }
                    };
                    match read.await {
                        Ok(c) => {
                            clicks = Some(c);
                            history = text("events");
                        }
                        Err(e) if plan_refused(&e) => {
                            clicks = None;
                            history = text("daily");
                        }
                        Err(e) => return Err(e),
                    }
                }
                if is(&history, "daily") {
                    let read = async {
                        let series = http
                            .get(
                                &format!(
                                    "{BASE}/analytics?event=clicks&groupBy=timeseries&interval=all&linkId={link_id}"
                                ),
                                &headers,
                            )
                            .await?;
                        daily_of(&series, "start")
                    };
                    match read.await {
                        Ok(d) => daily = Some(d),
                        Err(e) if plan_refused(&e) => history = text("none"),
                        Err(e) => return Err(e),
                    }
                }
                let name = or(field(l, "title"), None).cloned().unwrap_or_else(|| Value::from(""));
                let created = or_now(parse_value(field(l, "createdAt")), input.now);
                let mut item = foreign_link(
                    id.cloned(),
                    slug.cloned(),
                    field(l, "domain").cloned(),
                    Some(name),
                    url.cloned(),
                    created,
                );
                set_opt(&mut item, "clicks", clicks.map(Value::Array));
                set_opt(&mut item, "daily", daily.map(Value::Array));
                links.push(Value::Object(item));
            }
            let last = list.last().filter(|l| js::truthy(l));
            let cursor = match last {
                Some(last) if list.len() == PAGE => {
                    let mut next = Object::new();
                    set_opt(&mut next, "after", field(Some(last), "id").cloned());
                    set_opt(&mut next, "history", history);
                    Some(js::stringify(&Value::Object(next)))
                }
                _ => None,
            };
            Ok(step_answer(cursor, Some(Value::Null), links))
        })
    }
}
