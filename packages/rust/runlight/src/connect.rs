//! Connecting another Runlight to this one (a hub) without copying a token:
//! this server registers itself with the install's OAuth server, sends the
//! owner to that install's consent page, and on the way back swaps the code
//! for a manage token, limited there to the one site the owner picked.

use crate::error::Error;
use crate::goals::CodedError;
use crate::hash::random_id;
use crate::http::{FetchInit, Response, SearchParams, Url};
use crate::js::{self, Object, Value};
use crate::oauth::s256;
use crate::re::{js_re, test};
use crate::runlight::Runlight;
use crate::{arr, obj};

const PENDING_MS: i64 = 15 * 60_000;
const TIMEOUT_MS: u64 = 10_000;
/// The most an install's answer while connecting may weigh; a real one is under a kilobyte.
const MAX_BYTES: usize = 64 * 1024;

/// Why connecting failed, as a code the dashboard says in its own words. The
/// first four (`expired`, `denied`, `refused`, and `token`) come back from the
/// consent page, the rest (`url`, `unreachable`, `not_runlight`, `endpoints`,
/// `old`, and `register`) from starting.
pub type ConnectError = CodedError;

/// What starting or finishing a connection can end in besides its answer: a
/// [`ConnectError`] with its code, or Runlight's own error (the database, or
/// adding the site).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnectFailure {
    /// Refused, with a code the dashboard turns into its own words.
    Connect(ConnectError),
    /// Anything else.
    Runlight(Error),
}

impl From<Error> for ConnectFailure {
    fn from(e: Error) -> ConnectFailure {
        ConnectFailure::Runlight(e)
    }
}

impl From<crate::store::DbError> for ConnectFailure {
    fn from(e: crate::store::DbError) -> ConnectFailure {
        ConnectFailure::Runlight(Error::Db(e))
    }
}

impl std::fmt::Display for ConnectFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectFailure::Connect(e) => f.write_str(&e.message),
            ConnectFailure::Runlight(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for ConnectFailure {}

fn refuse(message: impl Into<String>, code: &str, params: &[(&str, &str)]) -> ConnectFailure {
    ConnectFailure::Connect(CodedError::new(message, code, params))
}

fn invalid_url() -> ConnectFailure {
    ConnectFailure::Runlight(Error::Other("TypeError: Invalid URL".into()))
}

fn host_of(url: &str) -> Result<String, ConnectFailure> {
    Url::parse(url).map(|u| u.host()).ok_or_else(invalid_url)
}

/// The install's address as its dashboard is, without a trailing slash. `local` allows an install on
/// this machine, at http://localhost or http://127.0.0.1.
pub fn install_url(value: Option<&Value>, local: bool) -> Result<String, ConnectError> {
    let url = crate::re::replace_all(js_re!(r"/+$"), js::trim(&js::str_or_empty(value)), "");
    // The pattern says which addresses are allowed; the parser, that it is an address at all ("https://[" is not).
    if !crate::safefetch::install_address(&url, local) || !Url::can_parse(&url) {
        return Err(CodedError::new("Enter the install's address, like https://example.com/runlight", "url", &[]));
    }
    Ok(url)
}

/// `answer.json()`, or `None` where the body is not JSON or weighs more than [`MAX_BYTES`].
fn json_of(answer: &Response) -> Option<Value> {
    if answer.body.len() > MAX_BYTES {
        return None;
    }
    answer.json_body().ok()
}

/// A request to the install, read no further than one byte past [`MAX_BYTES`].
fn capped(mut init: FetchInit) -> FetchInit {
    init.max_bytes = Some(MAX_BYTES + 1);
    init.truncate = true;
    init
}

/// A saved attempt, or `None` when it cannot be read or has no time it runs
/// out, which counts as expired.
fn pending_from(value: &str, now: i64) -> Option<Value> {
    let pending = js::parse(value).ok()?;
    if !matches!(pending, Value::Object(_) | Value::Array(_)) {
        return None;
    }
    match pending.get("expires") {
        Some(Value::Number(expires)) if *expires >= now as f64 => Some(pending),
        _ => None,
    }
}

/// Attempts nobody came back from are removed, so they do not pile up in settings.
async fn clear_expired(runlight: &Runlight) -> Result<(), ConnectFailure> {
    let store = runlight.store();
    for (key, value) in store.settings_starting_with("connect:").await? {
        if pending_from(&value, runlight.now()).is_none() {
            store.set_setting(&key, None).await?;
        }
    }
    Ok(())
}

/// Starts connecting: returns the address of the install's consent page.
/// `back` is where the install sends the owner afterwards, and `site` which of
/// its sites to offer first ("" for none).
pub async fn start_connect(
    runlight: &Runlight,
    input: Option<&Value>,
    back: &str,
    site: &str,
) -> Result<String, ConnectFailure> {
    let url = install_url(input, runlight.local_installs()).map_err(ConnectFailure::Connect)?;
    let unreachable = |url: &str| -> ConnectFailure {
        match host_of(url) {
            Ok(host) => refuse(format!("Could not reach {url}"), "unreachable", &[("host", &host)]),
            Err(e) => e,
        }
    };
    let Ok(answer) = runlight
        .fetch_install(
            &format!("{url}/.well-known/oauth-authorization-server"),
            capped(FetchInit::default().timeout(TIMEOUT_MS)),
        )
        .await
    else {
        return Err(unreachable(&url));
    };
    let meta = if answer.ok() { json_of(&answer) } else { None }.unwrap_or(Value::Null);
    let (Some(authorization), Some(token), Some(registration)) = (
        meta.get("authorization_endpoint").filter(|v| js::truthy(v)),
        meta.get("token_endpoint").filter(|v| js::truthy(v)),
        meta.get("registration_endpoint").filter(|v| js::truthy(v)),
    ) else {
        return Err(refuse(format!("{url} did not answer like a Runlight install"), "not_runlight", &[("url", &url)]));
    };
    // Its endpoints must be its own, so an address cannot steer this server into requests elsewhere.
    let origin = Url::parse(&url).map(|u| u.origin());
    let own = |endpoint: &Value| -> bool {
        let Some(origin) = &origin else { return false };
        Url::parse(&js::js_string(endpoint)).is_some_and(|u| &u.origin() == origin)
    };
    if ![authorization, token, registration].into_iter().all(own) {
        return Err(refuse(format!("{url} named endpoints on another address"), "endpoints", &[("url", &url)]));
    }
    let manage = matches!(meta.get("scopes_supported"), Some(Value::Array(scopes)) if scopes.iter().any(|s| s.as_str() == Some("manage")));
    if !manage {
        return Err(refuse(
            format!("{url} runs an older Runlight. Update it, or connect it with an API token from its Settings."),
            "old",
            &[("url", &url)],
        ));
    }

    let back_host = host_of(back)?;
    let body = obj! { "client_name" => format!("Runlight at {back_host}"), "redirect_uris" => arr![back] };
    let Ok(registered) = runlight
        .fetch_install(
            &js::js_string(registration),
            capped(
                FetchInit::method("POST")
                    .header("content-type", "application/json")
                    .body(body.to_json())
                    .timeout(TIMEOUT_MS),
            ),
        )
        .await
    else {
        return Err(unreachable(&url));
    };
    let client = json_of(&registered).unwrap_or(Value::Null);
    let client_id = client.get("client_id").filter(|v| js::truthy(v)).cloned();
    let Some(client_id) = client_id.filter(|_| registered.ok()) else {
        // Say why, in the install's own words when it gives them.
        let reason = match client.get("error_description").filter(|v| js::truthy(v)) {
            Some(d) => format!("{}.", js::head16(&js::js_string(d), 200)),
            None if registered.status == 400 => "This server's address must use https.".to_string(),
            None => format!("It answered {}.", registered.status),
        };
        return Err(refuse(
            format!("{url} would not let this server connect. {reason}"),
            "register",
            &[("url", &url), ("reason", &reason)],
        ));
    };
    clear_expired(runlight).await?;

    let state = random_id(16);
    let verifier = format!("{}{}", random_id(32), random_id(32));
    let pending = obj! {
        "url" => url.clone(),
        "client" => client_id.clone(),
        "verifier" => verifier.clone(),
        "redirect" => back,
        "token" => token.clone(),
        "expires" => runlight.now() + PENDING_MS,
    };
    runlight.store().set_setting(&format!("connect:{state}"), Some(&pending.to_json())).await?;
    let mut to = Url::parse(&js::js_string(authorization)).ok_or_else(invalid_url)?;
    let client_text = js::js_string(&client_id);
    let mut params = vec![
        ("response_type", "code".to_string()),
        ("client_id", client_text),
        ("redirect_uri", back.to_string()),
        ("code_challenge", s256(&verifier)),
        ("code_challenge_method", "S256".to_string()),
        ("scope", "manage".to_string()),
        ("state", state),
    ];
    // Which of its sites to offer first, when connecting again for a site already here.
    if !site.is_empty() {
        params.push(("site", site.to_string()));
    }
    to.set_search(&SearchParams::from_pairs(params).to_string());
    Ok(to.href())
}

/// Finishes connecting when the owner comes back from the consent page. Returns the site's id here.
pub async fn finish_connect(runlight: &Runlight, params: &SearchParams) -> Result<String, ConnectFailure> {
    let store = runlight.store();
    let state = params.get("state").unwrap_or("");
    let key = format!("connect:{state}");
    let stored = if test(js_re!(r"^[a-f0-9]{32}$"), state) {
        store.setting(&key).await?.filter(|s| !s.is_empty())
    } else {
        None
    };
    // Each attempt works once.
    if stored.is_some() {
        store.set_setting(&key, None).await?;
    }
    let Some(pending) = stored.and_then(|text| pending_from(&text, runlight.now())) else {
        return Err(refuse("That connection took too long or was already used. Start again.", "expired", &[]));
    };
    if params.get("error") == Some("access_denied") {
        return Err(refuse("The connection was not allowed.", "denied", &[]));
    }
    if let Some(error) = params.get("error").filter(|e| !e.is_empty()) {
        let message = params.get("error_description").unwrap_or(error);
        return Err(refuse(message, "refused", &[]));
    }

    let text = |k: &str| js::js_string(pending.at(k));
    let form = SearchParams::from_pairs([
        ("grant_type", "authorization_code".to_string()),
        ("code", params.get("code").unwrap_or("").to_string()),
        ("client_id", text("client")),
        ("redirect_uri", text("redirect")),
        ("code_verifier", text("verifier")),
    ]);
    let answer = runlight
        .fetch_install(
            &text("token"),
            capped(
                FetchInit::method("POST")
                    .header("content-type", "application/x-www-form-urlencoded")
                    .body(form.to_string())
                    .timeout(TIMEOUT_MS),
            ),
        )
        .await
        .ok();
    let granted = answer.filter(Response::ok).and_then(|a| json_of(&a)).unwrap_or(Value::Null);
    let Some(access_token) = granted.get("access_token").filter(|v| js::truthy(v)) else {
        let host = host_of(&text("url"))?;
        return Err(refuse(format!("{host} did not give this server a token. Start again."), "token", &[]));
    };
    let mut remote = Object::new();
    remote.set("url", pending.at("url").clone());
    remote.set("token", access_token.clone());
    if let Some(site) = granted.get("site") {
        remote.set("site", site.clone());
    }
    let site = runlight.add_site(&obj! { "remote" => remote }).await?;
    Ok(site.id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_addresses_are_https_or_local_when_allowed() {
        let url = |s: &str| install_url(Some(&Value::from(s)), false);
        assert_eq!(url(" https://example.com/runlight// ").unwrap(), "https://example.com/runlight");
        assert_eq!(url("http://localhost:3000").unwrap_err().code, "url");
        assert_eq!(install_url(Some(&Value::from("http://localhost:3000")), true).unwrap(), "http://localhost:3000");
        assert_eq!(install_url(Some(&Value::from("http://10.0.0.1")), true).unwrap_err().code, "url");
        assert_eq!(url("javascript:alert(1)").unwrap_err().code, "url");
        assert_eq!(url("http://example.com").unwrap_err().code, "url");
        assert_eq!(install_url(None, false).unwrap_err().code, "url");
    }
}
