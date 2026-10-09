//! Rebrandly (importers/rebrandly.ts). Its API gives only total clicks, with no dates, so links come
//! across with their slugs and domains and start their history fresh. https://developers.rebrandly.com/docs

use super::http::{Http, or_now, parse_value};
use super::types::{ImportError, Importer, StepInput, field, filled, foreign_link, items, nullish, or, step_answer};
use super::visits::object_of;
use crate::BoxFuture;
use crate::js::{self, Value};
use crate::sources::encode_uri_component;

const BASE: &str = "https://api.rebrandly.com/v1";
const PAGE: usize = 25;

/// Rebrandly's links.
pub struct Rebrandly;

impl Importer for Rebrandly {
    fn step<'a>(&'a self, http: &'a Http, input: StepInput<'a>) -> BoxFuture<'a, Result<Value, ImportError>> {
        Box::pin(async move {
            let Some(key) = filled(input.credentials, "apiKey") else {
                return Err(ImportError::new("Enter a Rebrandly API key", "import_key", &[("service", "Rebrandly")]));
            };
            let mut headers = vec![("apikey", key)];
            if let Some(workspace) = filled(input.credentials, "workspace") {
                headers.push(("workspace", workspace));
            }
            let last = input
                .cursor
                .filter(|c| !c.is_empty())
                .map_or_else(String::new, |c| format!("&last={}", encode_uri_component(c)));
            let list =
                http.get(&format!("{BASE}/links?orderBy=createdAt&orderDir=desc&limit={PAGE}{last}"), &headers).await?;
            let list = items(Some(&list), "links")?;
            let mut links = Vec::new();
            for l in list {
                let l = object_of(Some(l))?;
                let domain =
                    nullish(field(field(l, "domain"), "fullName"), Some(&Value::String(String::new()))).cloned();
                let name = or(field(l, "title"), None).cloned().unwrap_or_else(|| Value::from(""));
                let created = or_now(parse_value(field(l, "createdAt")), input.now);
                let item = foreign_link(
                    Some(Value::from(super::write::tpl(field(l, "id")))),
                    field(l, "slashtag").cloned(),
                    domain,
                    Some(name),
                    field(l, "destination").cloned(),
                    created,
                );
                links.push(Value::Object(item));
            }
            let end = list.last().filter(|l| js::truthy(l));
            let cursor = match end {
                Some(end) if list.len() == PAGE => Some(super::write::tpl(field(Some(end), "id"))),
                _ => None,
            };
            Ok(step_answer(cursor, Some(Value::Null), links))
        })
    }
}
