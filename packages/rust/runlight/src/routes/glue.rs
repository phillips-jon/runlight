//! Where the routes meet the modules around them: mail, the assistant, MCP, OAuth, connecting
//! installs, imports, icons, translations, and accounts.

use super::parts::R;
use super::*;
use crate::error::Error;
use crate::importers::visits::{import_csv_visits, import_umami_visits, umami_websites};
use crate::importers::{Http, ImportError, credentials_from};

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
pub(crate) type Web = crate::accounts::AccountsWeb;

/// Accounts as routes.ts makes them: the app's token proves who may make the first account, and in development
/// without one, anyone may. Emails link to the origin option when there is one.
pub(crate) fn web(
    rl: &Runlight,
    secret: &str,
    base: &str,
    token: Option<&str>,
    open: bool,
    origin: Option<&str>,
) -> Web {
    use crate::accounts::{AccountsWebOptions, FirstAccount, Home, accounts_web};
    let clock = rl.clone();
    let home: Option<Home> = origin.filter(|o| !o.is_empty()).and_then(Url::parse).map(|u| {
        let origin = u.origin();
        Arc::new(move || {
            let origin = origin.clone();
            Box::pin(async move { Some(origin) }) as BoxFuture<'static, Option<String>>
        }) as Home
    });
    accounts_web(AccountsWebOptions {
        runlight: rl.clone(),
        secret: secret.to_string(),
        base: base.to_string(),
        now: Arc::new(move || clock.now()),
        first_account: match token {
            Some(token) => FirstAccount::Token(token.to_string()),
            None if open => FirstAccount::Open,
            None => FirstAccount::Locked,
        },
        home,
        forgot: "https://runlight.sh/docs/configuration/#accounts".into(),
    })
}

/// What a signed-in person may do. A session cookie that cannot be read (a URIError in the TypeScript) is refused.
pub(crate) async fn web_access(web: &Web, request: &Request) -> Access {
    web.access(request).await.unwrap_or(Access::Denied)
}

pub(crate) async fn web_handle(web: &Web, request: &Request, path: &str) -> Result<Option<Response>, Error> {
    web.handle(request, path).await
}

pub(crate) async fn oauth_response(
    routes: &Routes,
    request: &Request,
    path: &str,
    url: &Url,
) -> Result<Option<Response>, Error> {
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

pub(crate) async fn own_hosts(routes: &Routes) -> Vec<String> {
    match &routes.0.options.extras.own_hosts {
        Some(f) => f().await,
        None => vec![],
    }
}

pub(crate) async fn import_step(routes: &Routes, site: &str, source: &str, body: &Value) -> R {
    let rl = routes.rl();
    let credentials = credentials_from(body.get("credentials"));
    let done = js::opt_number(body.get("done"));
    let done = if done.is_nan() { 0.0 } else { done };
    let step =
        crate::importers::import_step(rl, site, source, &credentials, body.get("cursor").and_then(Value::as_str), done)
            .await;
    match step {
        Ok(s) => Ok(json(&s.to_value(), 200, &[])),
        Err(ImportError::Coded { error, .. }) => Ok(refused(&error, 400)),
        Err(ImportError::Other(e)) => Err(e),
    }
}

/// Notes who made a new token; false takes it back. A token made by no signed-in account is the app's own.
pub(crate) async fn token_made(routes: &Routes, request: &Request, row: &TokenRow) -> Result<bool, Error> {
    match account_of(routes, request).await? {
        Some(by) => token_made_by(routes, row, &by).await,
        None => Ok(true),
    }
}

/// The account a request comes from, where the app has accounts (options.accountOf, or the accounts web's).
pub(crate) async fn account_of(routes: &Routes, request: &Request) -> Result<Option<String>, Error> {
    match &routes.0.web {
        Some(web) => web.account_of(request).await,
        None => Ok(None),
    }
}

/// Notes that `by` made a token; false when they can no longer make one (options.tokenMade, or the accounts web's).
pub(crate) async fn token_made_by(routes: &Routes, row: &TokenRow, by: &str) -> Result<bool, Error> {
    match &routes.0.web {
        Some(web) => web.token_made(row, by).await,
        None => Ok(true),
    }
}

pub(crate) async fn start_connect(routes: &Routes, body: &Value, done: &str) -> R {
    use crate::connect::ConnectFailure;
    let site = body.get("site").and_then(Value::as_str).unwrap_or("");
    match crate::connect::start_connect(routes.rl(), body.get("url"), done, site).await {
        Ok(authorize) => Ok(json(&obj! { "authorize" => authorize }, 200, &[])),
        Err(ConnectFailure::Connect(error)) => {
            let code =
                if error.code == "unreachable" { "unreachable".to_string() } else { format!("connect_{}", error.code) };
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
        Err(ConnectFailure::Runlight(Error::Range(_) | Error::Settings(_) | Error::Link(_) | Error::Mail(_))) => {
            Ok(Err("failed".into()))
        }
        Err(ConnectFailure::Runlight(error)) => Err(error),
    }
}

pub(crate) async fn umami_import(routes: &Routes, path: &str, url: &Url, body: &Value) -> R {
    let rl = routes.rl();
    let credentials = credentials_from(body.get("credentials"));
    let http = Http::new(rl.fetcher().clone());
    if path == "/api/import/umami/websites" {
        let websites = umami_websites(&http, &credentials).await;
        return match websites {
            Ok(w) => Ok(json(&obj! { "websites" => Value::Array(w) }, 200, &[])),
            Err(ImportError::Coded { error, .. }) => Ok(refused(&error, 400)),
            Err(ImportError::Other(e)) => Err(e),
        };
    }
    rl.init().await?;
    let site = match routes.query_site(url) {
        Ok(s) => s,
        Err(r) => return Ok(r),
    };
    let website = js::str_or_empty(body.get("website"));
    let step =
        import_umami_visits(rl, &http, &site.id, &credentials, &website, body.get("cursor").and_then(Value::as_str))
            .await;
    match step {
        Ok(s) => Ok(json(&s.to_value(), 200, &[])),
        Err(ImportError::Coded { error, .. }) => Ok(refused(&error, 400)),
        Err(ImportError::Other(e)) => Err(e),
    }
}

pub(crate) async fn csv_import(routes: &Routes, site: &str, body: &Value) -> R {
    let step = import_csv_visits(routes.rl(), site, body.get("rows")).await;
    match step {
        Ok(s) => Ok(json(&s.to_value(), 200, &[])),
        Err(ImportError::Coded { error, .. }) => Ok(refused(&error, 400)),
        Err(ImportError::Other(e)) => Err(e),
    }
}
