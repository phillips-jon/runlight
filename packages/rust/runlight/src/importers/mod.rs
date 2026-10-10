//! Imports from other tools: short links with their clicks from other shorteners, and visit history from
//! Umami or a CSV file (importers/index.ts).

pub mod bitly;
pub mod csvvisits;
pub mod dub;
pub mod http;
pub mod rebrandly;
pub mod shortio;
pub mod types;
pub mod umami;
pub mod visits;
pub mod write;

pub use http::Http;
pub use types::{Credentials, ImportError, ImportStep, Importer, Known, StepInput};

use self::types::field;
use self::write::{WriteStatus, imported_link_id, same_url, write_link};
use crate::js::{self, Object, Value};
use crate::runlight::Runlight;

/// The importer for a source: umami, dub, bitly, shortio, or rebrandly.
pub fn importer(source: &str) -> Option<&'static dyn Importer> {
    Some(match source {
        "umami" => &umami::Umami,
        "dub" => &dub::Dub,
        "bitly" => &bitly::Bitly,
        "shortio" => &shortio::Shortio,
        "rebrandly" => &rebrandly::Rebrandly,
        _ => return None,
    })
}

/// Credentials as a request sends them: an object's fields as text (`String(v)`), an array's items
/// by index, and nothing from anything else.
pub fn credentials_from(value: Option<&Value>) -> Credentials {
    let mut out = Credentials::new();
    match value {
        Some(Value::Object(o)) => {
            for (k, v) in o.iter() {
                out.insert(k.to_string(), js::js_string(v));
            }
        }
        Some(Value::Array(a)) => {
            for (i, v) in a.iter().enumerate() {
                out.insert(i.to_string(), js::js_string(v));
            }
        }
        _ => {}
    }
    out
}

/// One step of an import: fetch the next few links from the source, write each with its history, and
/// report progress. The cursor carries where to pick up, so the page calls this until the cursor comes
/// back `None`. Requests go through the Runlight's fetcher.
pub async fn import_step(
    rl: &Runlight,
    site: &str,
    source: &str,
    credentials: &Credentials,
    cursor: Option<&str>,
    done: f64,
) -> Result<ImportStep, ImportError> {
    import_step_with(
        rl,
        &Http::new(rl.fetcher().clone()).with_lookup(rl.lookup().cloned()),
        site,
        source,
        credentials,
        cursor,
        done,
    )
    .await
}

/// [`import_step`] with the requests sent through `http`.
pub async fn import_step_with(
    rl: &Runlight,
    http: &Http,
    site: &str,
    source: &str,
    credentials: &Credentials,
    cursor: Option<&str>,
    done: f64,
) -> Result<ImportStep, ImportError> {
    let Some(importer) = importer(source) else {
        return Err(ImportError::new(
            format!("Runlight cannot import from {source}"),
            "import_source",
            &[("source", source)],
        ));
    };
    rl.init().await?;
    let store = rl.store().clone();
    let source_name = source.to_string();
    let known: &Known = &move |source_id: String, slug: Option<String>, url: Option<String>| {
        let (store, source) = (store.clone(), source_name.clone());
        Box::pin(async move {
            if store.link_by_id(&imported_link_id(&source, &source_id)).await?.is_some() {
                return Ok(true);
            }
            let (Some(slug), Some(url)) = (slug.filter(|s| !s.is_empty()), url.filter(|u| !u.is_empty())) else {
                return Ok(false);
            };
            let taken = store.link_by_slug(&slug).await?;
            Ok(taken.is_some_and(|t| same_url(&t.url, &url)))
        })
    };
    let result = importer.step(http, StepInput { credentials, cursor, known, now: rl.now() }).await?;
    // A total that is not a number is as good as none.
    let total = field(Some(&result), "total").and_then(Value::as_f64).filter(|t| t.is_finite());
    let mut step = ImportStep {
        cursor: match field(Some(&result), "cursor") {
            None | Some(Value::Null) => None,
            Some(v) => Some(js::js_string(v)),
        },
        done,
        total,
        links: 0.0,
        clicks: 0.0,
        skipped: 0.0,
        failed: vec![],
    };
    let empty = vec![];
    let items = field(Some(&result), "links").and_then(Value::as_array).unwrap_or(&empty);
    for item in items {
        if js::opt_truthy(field(Some(item), "known")) {
            step.done += 1.0;
            step.skipped += 1.0;
            continue;
        }
        let link = field(Some(item), "link").cloned().unwrap_or(Value::Null);
        let written = write_link(rl, site, source, &link, item).await?;
        step.done += 1.0;
        match written.status {
            WriteStatus::Created => {
                step.links += 1.0;
                step.clicks += written.clicks;
            }
            WriteStatus::Skipped => step.skipped += 1.0,
            WriteStatus::Failed => {
                let mut o = Object::new();
                types::set_opt(&mut o, "slug", field(Some(&link), "slug").cloned());
                o.set("reason", written.reason.unwrap_or_default());
                if let Some(code) = written.code {
                    o.set("code", code);
                    let mut p = Object::new();
                    for (k, v) in written.params {
                        p.set(k, v);
                    }
                    o.set("params", p);
                }
                step.failed.push(Value::Object(o));
            }
        }
    }
    // Links the source skipped (deleted ones) still count toward progress.
    if !js::opt_truthy(field(Some(&result), "cursor"))
        && let Some(t) = total
    {
        step.done = if step.done.is_nan() { f64::NAN } else { step.done.max(t) };
    }
    Ok(step)
}
