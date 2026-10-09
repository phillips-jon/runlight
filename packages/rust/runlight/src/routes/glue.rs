//! Where the routes meet the modules around them: mail, the assistant, MCP, OAuth, connecting
//! installs, imports, icons, translations, and accounts.

use super::parts::R;
use super::*;
use crate::error::Error;
use crate::store::{ReportRow, SiteRow};

pub(crate) const VERSION: &str = "0.0.0";
pub(crate) const API_VERSION: u32 = 1;

/// What the standalone server adds to the routes.
#[derive(Clone, Default)]
pub struct RoutesExtras {
    /// More names the dashboard is reached at, which can never be link domains either.
    pub own_hosts: Option<Arc<dyn Fn() -> BoxFuture<'static, Vec<String>> + Send + Sync>>,
}

/// The sign-in accounts' web side.
pub(crate) struct Web;

pub(crate) fn web(_rl: &Runlight, _secret: &str, _base: &str, _token: Option<&str>, _open: bool, _origin: Option<&str>) -> Web {
    Web
}

pub(crate) async fn web_access(_web: &Web, _request: &Request) -> Access {
    Access::Denied
}

pub(crate) async fn web_handle(_web: &Web, _request: &Request, _path: &str) -> Result<Option<Response>, Error> {
    Ok(None)
}

/// The languages the dashboard speaks, English first.
pub(crate) fn languages() -> Vec<String> {
    crate::assets::LOCALE_TEXTS.iter().map(|(k, _)| k.clone()).collect()
}

/// A translator for a language: `t(key, vars)`, and the language used.
pub(crate) fn translator(lang: &str) -> (impl Fn(&str, &[(&str, &str)]) -> String + use<>, String) {
    let code = if languages().iter().any(|l| l == lang) { lang.to_string() } else { "en".to_string() };
    let table = |code: &str| {
        crate::assets::LOCALE_TEXTS.iter().find(|(k, _)| k == code).and_then(|(_, t)| js::parse(t).ok()).unwrap_or(Value::Null)
    };
    let own = table(&code);
    let english = table("en");
    let t = move |key: &str, vars: &[(&str, &str)]| {
        let text = own.get(key).or_else(|| english.get(key)).and_then(Value::as_str).unwrap_or(key).to_string();
        crate::re::uni_re!(r"\{(\w+)\}")
            .replace_all(&text, |c: &regex::Captures| vars.iter().find(|(k, _)| *k == &c[1]).map_or_else(|| c[0].to_string(), |(_, v)| v.to_string()))
            .into_owned()
    };
    (t, code)
}

pub(crate) async fn oauth_response(_routes: &Routes, _request: &Request, _path: &str, _url: &Url) -> Result<Option<Response>, Error> {
    Ok(None)
}

pub(crate) fn resource_metadata_url(origin: &str, base: &str) -> String {
    format!("{origin}/.well-known/oauth-protected-resource{base}/mcp")
}

pub(crate) async fn mcp_response(_routes: &Routes, _request: &Request, _url: &Url) -> R {
    Ok(coded("Not found", "not_found", 404, None))
}

pub(crate) async fn resolves_privately(_rl: &Runlight, _domain: &str) -> bool {
    false
}

pub(crate) async fn public_addresses(_rl: &Runlight, _name: &str) -> Vec<String> {
    vec![]
}

/// A public fetch, or whether it timed out.
pub(crate) async fn public_fetch(_rl: &Runlight, _url: &str, _ms: u64) -> Result<Response, bool> {
    Err(false)
}

pub(crate) async fn own_hosts(routes: &Routes) -> Vec<String> {
    match &routes.0.options.extras.own_hosts {
        Some(f) => f().await,
        None => vec![],
    }
}

pub(crate) async fn import_step(_routes: &Routes, _site: &str, _source: &str, _body: &Value) -> R {
    Ok(coded("Not found", "not_found", 404, None))
}

pub(crate) async fn mail_view(_rl: &Runlight, _managed: bool) -> Result<Value, Error> {
    Ok(Value::Null)
}

pub(crate) async fn save_mail_settings(_rl: &Runlight, _input: Option<&Value>) -> Result<(), Error> {
    Ok(())
}

pub(crate) async fn send_test_mail(_rl: &Runlight, _to: &str, _lang: &str) -> R {
    Ok(coded("Set up a mail service first", "mail_unset", 400, None))
}

/// The last period's key and when it is due.
pub(crate) fn last_period(_frequency: &str, _now: i64, _timezone: &str) -> (String, i64) {
    (String::new(), i64::MAX)
}

pub(crate) async fn deliver_report(_rl: &Runlight, _report: &ReportRow, _site: &SiteRow) -> Result<(), Error> {
    Ok(())
}

pub(crate) async fn token_made(_routes: &Routes, _request: &Request, _row: &TokenRow) -> Result<bool, Error> {
    Ok(true)
}

pub(crate) async fn start_connect(_routes: &Routes, _body: &Value, _done: &str) -> R {
    Ok(coded("Not found", "not_found", 404, None))
}

pub(crate) async fn finish_connect(_routes: &Routes, _url: &Url) -> Result<Result<String, String>, Error> {
    Ok(Err("failed".into()))
}

pub(crate) async fn umami_import(_routes: &Routes, _path: &str, _url: &Url, _body: &Value) -> R {
    Ok(coded("Not found", "not_found", 404, None))
}

pub(crate) async fn csv_import(_routes: &Routes, _site: &str, _body: &Value) -> R {
    Ok(coded("Not found", "not_found", 404, None))
}

pub(crate) async fn assistant_api(_routes: &Routes, _request: &Request, _path: &str, _url: &Url, _call: &Call) -> Result<Option<Response>, Error> {
    Ok(None)
}

pub(crate) async fn fetch_icon(_rl: &Runlight, _url: &str) -> Option<(Vec<u8>, String)> {
    None
}

impl Runlight {
    /// Sends every report that is due. Gives how many went and how many failed.
    pub async fn send_reports(&self) -> Result<(i64, i64), Error> {
        Ok((0, 0))
    }
}
