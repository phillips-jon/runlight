//! Umami v3 (and forks with custom link domains) (importers/umami.ts). Signs in with an API key, or with
//! a username and password (stock self-hosted Umami has no API keys). In Umami a link's clicks are
//! events stored under the link's id, with the visitor's session holding place and device.

use std::collections::HashMap;

use super::http::{Http, or_now, parse_value};
use super::types::{
    Credentials, ImportError, Importer, StepInput, arg, credential, field, foreign_link, items, known_link, nullish,
    set_opt, step_answer,
};
use super::visits::{at_least, object_of};
use crate::BoxFuture;
use crate::js::{self, Object, Value};
use crate::re::{js_re, replace_first, test};

const PAGE: f64 = 5.0;

/// `Bearer ${token}`, as a template literal writes a token that may be missing.
pub(crate) fn bearer(token: Option<&Value>) -> String {
    format!("Bearer {}", super::write::tpl(token))
}

/// Signs in to an Umami: an API key, or a username and password (stock self-hosted Umami has no API
/// keys). A token from an earlier step is reused. Answers the address and the token (`None` when the
/// sign-in answered without one, as JavaScript's undefined).
pub async fn umami_sign_in(
    http: &Http,
    credentials: &Credentials,
    token: Option<Value>,
) -> Result<(String, Option<Value>), ImportError> {
    let base = replace_first(js_re!(r"/+$"), js::trim(credentials.get("url").map_or("", String::as_str)), "");
    if !test(js_re!(r"^https?://[^/]+"), &base) {
        return Err(ImportError::new(
            "Enter your Umami address, like https://stats.example.com",
            "import_umami_address",
            &[],
        ));
    }
    let key = credential(credentials, "apiKey").unwrap_or("");
    if !key.is_empty() {
        return Ok((base, Some(Value::from(key))));
    }
    if js::opt_truthy(token.as_ref()) {
        return Ok((base, token));
    }
    let username = credentials.get("username").filter(|u| !u.is_empty());
    let password = credentials.get("password").filter(|p| !p.is_empty());
    let (Some(username), Some(password)) = (username, password) else {
        return Err(ImportError::new("Enter an API key, or a username and password", "import_umami_login", &[]));
    };
    let body = js::stringify(&crate::obj! { "username" => username.as_str(), "password" => password.as_str() });
    let login = http
        .get_json(&format!("{base}/api/auth/login"), "POST", &[("content-type", "application/json")], Some(&body))
        .await?;
    // A sign-in that answers without a token was refused, whatever its status.
    match field(Some(&login), "token") {
        Some(Value::String(t)) if !t.is_empty() => Ok((base, Some(Value::from(t.as_str())))),
        _ => Err(ImportError::new("The key or sign-in was refused", "import_refused", &[])),
    }
}

/// Umami's links.
pub struct Umami;

impl Importer for Umami {
    fn step<'a>(&'a self, http: &'a Http, input: StepInput<'a>) -> BoxFuture<'a, Result<Value, ImportError>> {
        Box::pin(async move {
            let now = input.now;
            // A key comes with every step; only a sign-in token, which expires, rides in the cursor.
            let saved = match input.cursor.filter(|c| !c.is_empty()) {
                Some(c) => js::parse(c).map_err(|e| ImportError::other(format!("SyntaxError: {e}")))?,
                None => crate::obj! { "page" => 1 },
            };
            let saved = object_of(Some(&saved))?;
            let key = credential(input.credentials, "apiKey").unwrap_or("");
            let (base, token) = umami_sign_in(http, input.credentials, field(saved, "token").cloned()).await?;
            let page = field(saved, "page").cloned();
            let auth = bearer(token.as_ref());
            let headers = [("authorization", auth.as_str())];
            let list = http
                .get(
                    &format!(
                        "{base}/api/links?page={}&pageSize={}",
                        super::write::tpl(page.as_ref()),
                        js::format_number(PAGE)
                    ),
                    &headers,
                )
                .await?;

            let all = |path: String| {
                let (base, headers) = (&base, &headers);
                async move {
                    let mut out: Vec<Value> = Vec::new();
                    let mut n = 1;
                    loop {
                        let body = http.get(&format!("{base}/api{path}&page={n}&pageSize=1000"), headers).await?;
                        let data = items(field(Some(&body), "data"), "data")?;
                        out.extend(data.iter().cloned());
                        if at_least(out.len(), field(Some(&body), "count")) || data.is_empty() {
                            return Ok::<_, ImportError>(out);
                        }
                        n += 1;
                    }
                }
            };

            let mut links = Vec::new();
            let data = items(field(Some(&list), "data"), "data")?;
            for l in data {
                let l = object_of(Some(l))?;
                if js::opt_truthy(field(l, "deletedAt")) {
                    continue;
                }
                let id = field(l, "id");
                let (slug, url) = (field(l, "slug"), field(l, "url"));
                if (input.known)(super::write::tpl(id), arg(slug), arg(url)).await? {
                    links.push(known_link(id.cloned(), slug.cloned(), field(l, "name").cloned(), url.cloned()));
                    continue;
                }
                let created = or_now(parse_value(field(l, "createdAt")), now);
                let range = format!(
                    "startAt={}&endAt={}",
                    js::format_number(created - 86_400_000.0),
                    js::format_number(now as f64 + 60_000.0)
                );
                let website = super::write::tpl(id);
                let events = all(format!("/websites/{website}/events?{range}")).await?;
                let sessions = all(format!("/websites/{website}/sessions?{range}")).await?;
                let mut info: HashMap<String, &Value> = HashMap::new();
                for s in &sessions {
                    let key = field(object_of(Some(s))?, "id").map_or_else(|| "undefined".into(), js::stringify);
                    info.insert(key, s);
                }
                let mut clicks = Vec::new();
                for e in &events {
                    let e = object_of(Some(e))?;
                    let s = info.get(&field(e, "sessionId").map_or_else(|| "undefined".into(), js::stringify)).copied();
                    let domain = field(e, "referrerDomain");
                    let referrer = if js::opt_truthy(domain) {
                        let path = field(e, "referrerPath");
                        let path =
                            if js::opt_truthy(path) { js::js_string(path.unwrap_or(&Value::Null)) } else { "/".into() };
                        format!("https://{}{path}", super::write::tpl(domain))
                    } else {
                        String::new()
                    };
                    let mut c = Object::new();
                    c.set("ts", parse_value(field(e, "createdAt")));
                    set_opt(&mut c, "visit", field(e, "sessionId").cloned());
                    c.set("referrer", referrer);
                    set_opt(&mut c, "path", field(e, "urlPath").cloned());
                    set_opt(&mut c, "query", field(e, "urlQuery").cloned());
                    set_opt(&mut c, "country", field(e, "country").cloned());
                    set_opt(&mut c, "region", field(s, "region").cloned());
                    set_opt(&mut c, "city", field(e, "city").cloned());
                    set_opt(&mut c, "browser", field(e, "browser").cloned());
                    set_opt(&mut c, "os", field(e, "os").cloned());
                    set_opt(&mut c, "device", field(e, "device").cloned());
                    set_opt(&mut c, "screen", field(s, "screen").cloned());
                    set_opt(&mut c, "language", field(s, "language").cloned());
                    clicks.push(Value::Object(c));
                }
                let domain =
                    nullish(field(field(l, "customDomain"), "domain"), Some(&Value::String(String::new()))).cloned();
                let item =
                    foreign_link(id.cloned(), slug.cloned(), domain, field(l, "name").cloned(), url.cloned(), created)
                        .with("clicks", Value::Array(clicks));
                links.push(Value::Object(item));
            }
            let page_number = page.as_ref().map_or(f64::NAN, js::js_number);
            // Without a count there is no total, and a full page may have more after it.
            let count = match field(Some(&list), "count") {
                Some(Value::Number(n)) if n.is_finite() => Some(*n),
                _ => None,
            };
            let more = match count {
                None => data.len() as f64 == PAGE,
                Some(c) => page_number * PAGE < c && !data.is_empty(),
            };
            let cursor = more.then(|| {
                let mut next = Object::new();
                next.set("page", page_number + 1.0);
                if key.is_empty()
                    && let Some(t) = &token
                {
                    next.set("token", t.clone());
                }
                js::stringify(&Value::Object(next))
            });
            Ok(step_answer(cursor, Some(Value::from(count)), links))
        })
    }
}
