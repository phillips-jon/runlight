//! Where the routes meet the modules around them: mail, the assistant, MCP, OAuth, connecting
//! installs, imports, icons, translations, and accounts.

use super::parts::R;
use super::*;
use crate::error::Error;

pub(crate) use super::wired::*;

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


pub(crate) async fn oauth_response(_routes: &Routes, _request: &Request, _path: &str, _url: &Url) -> Result<Option<Response>, Error> {
    Ok(None)
}

pub(crate) fn resource_metadata_url(origin: &str, base: &str) -> String {
    format!("{origin}/.well-known/oauth-protected-resource{base}/mcp")
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

