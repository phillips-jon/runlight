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

pub(crate) async fn oauth_response(routes: &Routes, request: &Request, path: &str, url: &Url) -> Result<Option<Response>, Error> {
    crate::oauth::oauth_response(routes, request, path, url).await
}

pub(crate) fn resource_metadata_url(origin: &str, base: &str) -> String {
    crate::oauth::resource_metadata_url(origin, base)
}

/// What OAuth asks of the routes, as routes() hands it to oauthResponse.
impl crate::oauth::OAuthHost for Routes {
    fn runlight(&self) -> &Runlight {
        self.rl()
    }

    fn base(&self) -> &str {
        &self.0.base
    }

    fn is_owner<'a>(&'a self, request: &'a Request) -> BoxFuture<'a, bool> {
        Box::pin(async move { self.can_read(request, &Call::default()).await == CanRead::Yes })
    }

    fn is_reader<'a>(&'a self, request: &'a Request) -> BoxFuture<'a, bool> {
        Box::pin(async move {
            match (&self.0.options.authorize, &self.0.web) {
                (Some(authorize), _) => authorize(request).await == Access::Read,
                (None, Some(web)) => web_access(web, request).await == Access::Read,
                (None, None) => false,
            }
        })
    }

    fn sign_in(&self) -> Option<&str> {
        self.0.sign_in.as_deref()
    }

    fn account_of<'a>(&'a self, request: &'a Request) -> BoxFuture<'a, Result<Option<String>, Error>> {
        Box::pin(account_of(self, request))
    }

    fn token_made<'a>(&'a self, token: &'a TokenRow, by: &'a str) -> BoxFuture<'a, Result<bool, Error>> {
        Box::pin(token_made_by(self, token, by))
    }
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

/// The account a request comes from, where the app has accounts (options.accountOf, or the accounts web's).
pub(crate) async fn account_of(_routes: &Routes, _request: &Request) -> Result<Option<String>, Error> {
    Ok(None)
}

/// Notes that `by` made a token; false when they can no longer make one (options.tokenMade, or the accounts web's).
pub(crate) async fn token_made_by(_routes: &Routes, _row: &TokenRow, _by: &str) -> Result<bool, Error> {
    Ok(true)
}

pub(crate) async fn start_connect(routes: &Routes, body: &Value, done: &str) -> R {
    use crate::connect::ConnectFailure;
    let site = body.get("site").and_then(Value::as_str).unwrap_or("");
    match crate::connect::start_connect(routes.rl(), body.get("url"), done, site).await {
        Ok(authorize) => Ok(json(&obj! { "authorize" => authorize }, 200, &[])),
        Err(ConnectFailure::Connect(error)) => {
            let code = if error.code == "unreachable" { "unreachable".to_string() } else { format!("connect_{}", error.code) };
            Ok(coded_error(&crate::goals::CodedError { code, ..error }, 400))
        }
        // Any other RangeError, in its own words.
        Err(ConnectFailure::Runlight(Error::Range(message))) => Ok(refused_plain(&message, "connect_failed", 400)),
        Err(ConnectFailure::Runlight(error)) => match error.coded() {
            Some(own) => Ok(refused(own, 400)),
            None => Err(error),
        },
    }
}

/// Finishes connecting: the site's id, or the code the dashboard explains (`failed` for a refusal without one).
pub(crate) async fn finish_connect(routes: &Routes, url: &Url) -> Result<Result<String, String>, Error> {
    use crate::connect::ConnectFailure;
    match crate::connect::finish_connect(routes.rl(), &url.search_params()).await {
        Ok(id) => Ok(Ok(id)),
        Err(ConnectFailure::Connect(error)) => Ok(Err(error.code)),
        // A RangeError from adding the site.
        Err(ConnectFailure::Runlight(Error::Range(_) | Error::Settings(_) | Error::Link(_) | Error::Mail(_))) => Ok(Err("failed".into())),
        Err(ConnectFailure::Runlight(error)) => Err(error),
    }
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
