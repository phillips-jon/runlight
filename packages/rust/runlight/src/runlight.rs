//! The Runlight: sites, the tracker's hits, short links, AI agent fetches,
//! and the scheduled upkeep (runlight.ts).

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use crate::error::Error;
use crate::geo::{SharedGeo, locate};
use crate::hash::{new_id, random_salt, visitor_hash};
use crate::http::{FetchInit, Headers, Request, Response, SharedFetcher, Url, default_fetcher};
use crate::js::{self, Object, Value};
use crate::limit::RateLimit;
use crate::payload::{MAX_BODY, Payload, parse_payload};
use crate::re::{js_re, test};
use crate::sources::{Page, attribute, decode_uri_component, parse_page, strip_www};
use crate::store::{EVENT_TAIL_MS, EventRow, SessionRow, SiteOverrides, SiteRow, SqlStore};
use crate::time::{add_days, is_timezone, local_date, start_of};
use crate::ua::{ClientHints, ai_agent, is_bot, parse_client};

/// A path on every link domain that answers when the domain reaches this Runlight.
pub const LINK_DOMAIN_CHECK: &str = "/.well-known/runlight-link-domain";
/// Raised whenever what a rolled-up day holds changes.
const ROLLUP_VERSION: &str = "3";
/// Days of rollups built per site in one scheduled check.
const ROLLUP_BATCH: usize = 10;
/// The most a connected install's list of sites may weigh; a real one is a few kilobytes.
pub(crate) const REMOTE_MAX_BYTES: usize = 2 * 1024 * 1024;
/// On a database that caps statements per request (Cloudflare D1), fewer days a check.
const METERED_ROLLUP_BATCH: usize = 4;
const ROLLUP_DELAY_MS: i64 = 2 * 3_600_000;
/// The choices for how long a site keeps its visits.
pub const RETENTION_MONTHS: [i64; 5] = [6, 12, 24, 36, 60];
/// Thirty minutes without a request ends a session.
pub const SESSION_IDLE_MS: i64 = 30 * 60 * 1000;

/// A site as code gives it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SiteOptions {
    /// Stable id, stored with every row. Default "default".
    pub id: Option<String>,
    /// Its name.
    pub name: Option<String>,
    /// Hostnames that belong to this site. With one site, empty means any hostname.
    pub hostnames: Option<Vec<String>>,
    /// IANA timezone for reports. Default "UTC".
    pub timezone: Option<String>,
}

/// Where the client's address is read from.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum TrustProxy {
    /// The last X-Forwarded-For entry, then X-Real-IP, then CF-Connecting-IP (the default).
    #[default]
    On,
    /// Only the connection's address.
    Off,
    /// Only this header: `x-forwarded-for`, `x-real-ip`, or `cf-connecting-ip`.
    Header(String),
}

/// A clock in epoch milliseconds.
pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

/// How a Runlight is made.
#[derive(Clone)]
pub struct RunlightOptions {
    /// Where everything is kept.
    pub store: SqlStore,
    /// The site this install counts. Ignored when `sites` is given.
    pub site: Option<SiteOptions>,
    /// Several sites in one install, told apart by hostname.
    pub sites: Option<Vec<SiteOptions>>,
    /// Sites are added, changed, and deleted in the dashboard and kept in the database.
    pub managed_sites: bool,
    /// Looks up a location for an IP when the platform sends no location headers.
    pub geo: Option<SharedGeo>,
    /// Where the client's address is read from.
    pub trust_proxy: TrustProxy,
    /// Where short links on the app's own domain live. Default "/go".
    pub link_path: Option<String>,
    /// The mail service for email reports, in code, as the SDK's MailSettings object.
    pub mail: Option<Object>,
    /// Encrypts the keys kept in the database. Default RUNLIGHT_SECRET, then RUNLIGHT_TOKEN.
    pub secret: Option<String>,
    /// Tracker requests allowed per visitor address per minute. `None` is the default, 120; zero,
    /// a negative number, or NaN turns the limit off.
    pub rate_limit: Option<f64>,
    /// The clock, for tests.
    pub now: Option<Clock>,
    /// Everything that calls another server goes through this.
    pub fetcher: Option<SharedFetcher>,
}

impl RunlightOptions {
    /// Options with a store and the defaults.
    pub fn new(store: SqlStore) -> RunlightOptions {
        RunlightOptions {
            store,
            site: None,
            sites: None,
            managed_sites: false,
            geo: None,
            trust_proxy: TrustProxy::On,
            link_path: None,
            mail: None,
            secret: None,
            rate_limit: None,
            now: None,
            fetcher: None,
        }
    }
}

/// Another Runlight install a site is read from: its address, its token there, and its own id for the site.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Remote {
    /// Its address.
    pub url: String,
    /// The token it gave.
    pub token: String,
    /// Its own id for the site.
    pub site: String,
    /// The site's hostnames there.
    pub hostnames: Vec<String>,
    /// `manage` when the token may change the site's settings there.
    pub scope: Option<String>,
}

impl Remote {
    fn to_value(&self) -> Value {
        let mut o = Object::new();
        o.set("url", self.url.clone());
        o.set("token", self.token.clone());
        o.set("site", self.site.clone());
        o.set("hostnames", Value::Array(self.hostnames.iter().map(|h| Value::from(h.as_str())).collect()));
        if let Some(scope) = &self.scope {
            o.set("scope", scope.clone());
        }
        Value::Object(o)
    }

    fn from_value(v: &Value) -> Remote {
        Remote {
            url: js::str_or_empty(v.get("url")),
            token: js::str_or_empty(v.get("token")),
            site: js::str_or_empty(v.get("site")),
            hostnames: v.get("hostnames").and_then(Value::as_array).map(|a| a.iter().map(js::js_string).collect()).unwrap_or_default(),
            scope: v.get("scope").and_then(Value::as_str).map(str::to_string),
        }
    }
}

/// What a connected install last said about its site.
#[derive(Clone, Debug, PartialEq)]
pub struct RemoteInfo {
    /// Its last visit.
    pub last_seen: Option<f64>,
    /// How long it keeps visits: `None` while it cannot be reached (undefined), `Some(None)` for forever.
    pub retention_months: Option<Option<f64>>,
    /// `ok`, `refused`, or `unreachable`.
    pub connection: &'static str,
}

/// An environment variable, trimmed, or `None` when it is empty.
pub fn env_value(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|v| js::trim(&v).to_string()).filter(|v| !v.is_empty())
}

/// What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets.
pub fn is_email(text: &str) -> bool {
    crate::re::uni_re!(r#"^[^@<>"]+@[^@<>"]+\.[^@<>"]+$"#).is_match(text)
        && !text.chars().any(|c| js::is_space(c))
}

fn site_row(options: &SiteOptions, index: usize) -> Result<SiteRow, String> {
    let timezone = options.timezone.clone().unwrap_or_else(|| "UTC".into());
    if !is_timezone(&timezone) {
        return Err(format!("Runlight: unknown timezone \"{timezone}\""));
    }
    let id = options.id.clone().unwrap_or_else(|| if index == 0 { "default".into() } else { String::new() });
    if id.is_empty() || !test(js_re!(r"(?i)^[a-z0-9][a-z0-9._-]{0,63}$"), &id) {
        return Err(format!("Runlight: site id \"{id}\" must be letters, digits, dots, dashes, or underscores"));
    }
    let hostnames = options.hostnames.clone().unwrap_or_default();
    Ok(SiteRow {
        id,
        name: options.name.clone().unwrap_or_else(|| hostnames.first().cloned().unwrap_or_else(|| "My site".into())),
        hostnames: hostnames.iter().map(|h| strip_www(h)).collect(),
        timezone,
    })
}

fn utc_day(ts: i64) -> String {
    js::head16(&js::iso_string(ts), 10)
}

/// The sort `a.name.localeCompare(b.name)` gives, near enough: case-insensitive first, then as written.
pub(crate) fn locale_compare(a: &str, b: &str) -> std::cmp::Ordering {
    a.to_lowercase().cmp(&b.to_lowercase()).then_with(|| b.cmp(a))
}

#[derive(Default)]
struct State {
    configured: Vec<SiteRow>,
    overrides: HashMap<String, SiteOverrides>,
    remotes: Vec<(String, Remote)>,
    remote_seen: HashMap<String, (i64, RemoteInfo)>,
    link_domains: Option<(i64, HashSet<String>)>,
    salts: HashMap<String, (String, String, Option<String>)>,
    optimized_at: i64,
}

pub(crate) struct Inner {
    pub(crate) store: SqlStore,
    pub(crate) managed_sites: bool,
    geo: Option<SharedGeo>,
    trust_proxy: TrustProxy,
    limit: Option<RateLimit>,
    clock: Clock,
    pub(crate) link_path: String,
    pub(crate) mail_in_code: Option<Object>,
    pub(crate) secret: Option<String>,
    pub(crate) fetcher: SharedFetcher,
    state: Mutex<State>,
    ready: tokio::sync::Mutex<bool>,
    checking: tokio::sync::Mutex<()>,
    turns: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    pruning: Mutex<Vec<tokio::task::JoinHandle<()>>>,
    prune_turn: Arc<tokio::sync::Mutex<()>>,
    pub(crate) route_bases: Mutex<Vec<String>>,
}

/// Privacy friendly web analytics that lives inside your app. A cheap handle to clone.
#[derive(Clone)]
pub struct Runlight(pub(crate) Arc<Inner>);


impl Runlight {
    /// A Runlight over a store. Refuses a site whose timezone or id is not one, several sites without
    /// hostnames, and two sites with one id.
    pub fn new(options: RunlightOptions) -> Result<Runlight, String> {
        let configured: Vec<SiteOptions> = if options.managed_sites {
            vec![]
        } else {
            match &options.sites {
                Some(sites) if !sites.is_empty() => sites.clone(),
                _ => vec![options.site.clone().unwrap_or_default()],
            }
        };
        let configured = configured.iter().enumerate().map(|(i, s)| site_row(s, i)).collect::<Result<Vec<_>, _>>()?;
        if configured.len() > 1 && configured.iter().any(|s| s.hostnames.is_empty()) {
            return Err("Runlight: with several sites, give each one its hostnames".into());
        }
        let ids: HashSet<&str> = configured.iter().map(|s| s.id.as_str()).collect();
        if ids.len() != configured.len() {
            return Err("Runlight: two sites share an id".into());
        }
        let per_minute = options.rate_limit.unwrap_or(120.0);
        // Zero, or anything that is not a positive number, means no limit, never a limit of nothing.
        let limit = (per_minute > 0.0).then(|| RateLimit::new(per_minute));
        let clock: Clock = options.now.clone().unwrap_or_else(|| {
            Arc::new(|| std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64))
        });
        let link_path = format!("/{}", options.link_path.as_deref().unwrap_or("/go").trim_matches('/'));
        let secret = options.secret.clone().or_else(|| env_value("RUNLIGHT_SECRET")).or_else(|| env_value("RUNLIGHT_TOKEN"));
        Ok(Runlight(Arc::new(Inner {
            store: options.store,
            managed_sites: options.managed_sites,
            geo: options.geo,
            trust_proxy: options.trust_proxy,
            limit,
            clock,
            link_path,
            mail_in_code: options.mail,
            secret,
            fetcher: options.fetcher.unwrap_or_else(default_fetcher),
            state: Mutex::new(State { configured, ..State::default() }),
            ready: tokio::sync::Mutex::new(false),
            checking: tokio::sync::Mutex::new(()),
            turns: Mutex::new(HashMap::new()),
            pruning: Mutex::new(Vec::new()),
            prune_turn: Arc::new(tokio::sync::Mutex::new(())),
            route_bases: Mutex::new(Vec::new()),
        })))
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The store.
    pub fn store(&self) -> &SqlStore {
        &self.0.store
    }

    /// The clock's time, in epoch milliseconds.
    pub fn now(&self) -> i64 {
        (self.0.clock)()
    }

    /// The fetcher everything that calls out goes through.
    pub fn fetcher(&self) -> &SharedFetcher {
        &self.0.fetcher
    }

    /// Whether sites are managed in the dashboard.
    pub fn managed_sites(&self) -> bool {
        self.0.managed_sites
    }

    /// The secret the keys in the database are sealed with, if any.
    pub fn secret(&self) -> Option<&str> {
        self.0.secret.as_deref()
    }

    /// Where links on the app's own domain are served, such as "/go".
    pub fn link_path(&self) -> &str {
        &self.0.link_path
    }

    /// Creates tables and records the configured sites. Runs once.
    pub async fn init(&self) -> Result<(), Error> {
        let mut ready = self.0.ready.lock().await;
        if *ready {
            return Ok(());
        }
        let store = &self.0.store;
        store.migrate().await?;
        // A database that never had its statistics gathered gets them now, before any report is read.
        store.optimize(true).await;
        if self.0.managed_sites {
            let sites = store.sites().await?;
            self.state().configured = sites;
            self.load_remotes().await?;
        }
        let configured = self.state().configured.clone();
        for site in &configured {
            store.upsert_site(site, self.now()).await?;
        }
        let overrides = store.site_overrides().await?;
        self.state().overrides = overrides;
        // A process starting with a timezone set in code is the newest word on it: if the code changed it,
        // the days built in the old one are cleared here, once, and never by a process still running.
        for site in self.sites() {
            if self.is_remote(&site.id) {
                continue;
            }
            let stored = store.setting(&format!("rollup-zone:{}", site.id)).await?;
            let zone = stored.and_then(|s| js::parse(&s).ok()).map(|v| js::str_or_empty(v.get("zone")));
            match zone {
                None => {
                    let value = obj_zone(&site.timezone, 0);
                    store.set_setting(&format!("rollup-zone:{}", site.id), Some(&value)).await?;
                }
                Some(zone) if zone != site.timezone => {
                    self.zone_changed(&site.id, &site.timezone).await?;
                }
                _ => {}
            }
        }
        *ready = true;
        Ok(())
    }

    /// The sites, with any settings changed in the dashboard applied.
    pub fn sites(&self) -> Vec<SiteRow> {
        let state = self.state();
        state
            .configured
            .iter()
            .map(|site| {
                let mut site = site.clone();
                if let Some(o) = state.overrides.get(&site.id) {
                    if let Some(Value::String(name)) = o.get("name") {
                        site.name = name.clone();
                    }
                    if let Some(Value::String(tz)) = o.get("timezone") {
                        site.timezone = tz.clone();
                    }
                }
                site
            })
            .collect()
    }

    /// The configured sites, without dashboard changes.
    pub(crate) fn configured(&self) -> Vec<SiteRow> {
        self.state().configured.clone()
    }

    /// Checks a list of hostnames for a managed site: at least one, each a domain, none taken.
    fn hostnames_for(&self, input: Option<&Value>, except: Option<&str>) -> Result<Vec<String>, Error> {
        let list: Vec<String> = match input {
            Some(Value::Array(a)) => a.iter().map(js::js_string).collect(),
            other => {
                let text = js::str_or_empty(other);
                crate::re::uni_re!(r"[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF},]+")
                    .split(&text)
                    .map(str::to_string)
                    .collect()
            }
        };
        let mut hostnames: Vec<String> = Vec::new();
        for h in list {
            let h = js::trim(&h).to_string();
            let h = crate::re::replace_first(js_re!(r"^https?://"), &h, "");
            let h = crate::re::replace_first(js_re!(r"[/:][\s\S]*$"), &h, "");
            let h = strip_www(&h);
            if !h.is_empty() && !hostnames.contains(&h) {
                hostnames.push(h);
            }
        }
        if hostnames.is_empty() {
            return Err(Error::settings("Add the site's domain, like example.com", "site_domain_needed", &[]));
        }
        let configured = self.configured();
        for host in &hostnames {
            if !is_domain(host) && host != "localhost" {
                return Err(Error::settings(format!("\"{host}\" is not a domain name"), "site_domain_invalid", &[("host", host)]));
            }
            if let Some(owner) = configured.iter().find(|s| Some(s.id.as_str()) != except && s.hostnames.contains(host)) {
                return Err(Error::settings(
                    format!("{host} already belongs to {}", owner.name),
                    "site_domain_taken",
                    &[("host", host), ("site", &owner.name)],
                ));
            }
        }
        Ok(hostnames)
    }

    async fn load_remotes(&self) -> Result<(), Error> {
        let mut remotes = Vec::new();
        for (key, value) in self.0.store.settings_starting_with("remote:").await? {
            if let Some(opened) = crate::mail::secret::unseal(&value, self.0.secret.as_deref())
                && let Ok(v) = js::parse(&opened)
            {
                remotes.push((key["remote:".len()..].to_string(), Remote::from_value(&v)));
            }
        }
        self.state().remotes = remotes;
        Ok(())
    }

    /// Whether a site is counted by another install.
    pub fn is_remote(&self, id: &str) -> bool {
        self.state().remotes.iter().any(|(k, _)| k == id)
    }

    /// The install a site is read from, when it is counted elsewhere.
    pub fn remote(&self, id: &str) -> Option<Remote> {
        self.state().remotes.iter().find(|(k, _)| k == id).map(|(_, r)| r.clone())
    }

    /// When a connected install's site last had a visit, asked at most once a minute.
    pub async fn remote_last_seen(&self, id: &str) -> Option<f64> {
        self.remote_info(id).await.and_then(|i| i.last_seen)
    }

    /// What a connected install says about its site, asked at most once a minute.
    pub async fn remote_info(&self, id: &str) -> Option<RemoteInfo> {
        let remote = self.remote(id)?;
        let cached = self.state().remote_seen.get(id).cloned();
        if let Some((at, info)) = &cached
            && self.now() - at < 60_000
        {
            return Some(info.clone());
        }
        let mut info = RemoteInfo { last_seen: cached.as_ref().and_then(|c| c.1.last_seen), retention_months: None, connection: "unreachable" };
        let init = FetchInit::default().header("authorization", format!("Bearer {}", remote.token)).timeout(8000).max_bytes(REMOTE_MAX_BYTES);
        if let Ok(answer) = self.0.fetcher.fetch(&format!("{}/api/sites", remote.url), init).await {
            if answer.status == 401 || answer.status == 403 {
                info.connection = "refused";
            }
            if let Ok(body) = answer.json_body()
                && let Some(there) = body.get("sites").and_then(Value::as_array).and_then(|a| a.iter().find(|s| js::str_or_empty(s.get("id")) == remote.site && s.get("id").is_some_and(Value::is_string)))
            {
                info = RemoteInfo {
                    last_seen: there.get("lastSeen").and_then(Value::as_f64),
                    retention_months: Some(there.get("retentionMonths").and_then(Value::as_f64)),
                    connection: "ok",
                };
            }
        }
        self.state().remote_seen.insert(id.to_string(), (self.now(), info.clone()));
        Some(info)
    }

    /// Forgets what a connected install said, after a change made through it.
    pub fn forget_remote_info(&self, id: &str) {
        self.state().remote_seen.remove(id);
    }

    /// Asks a connected install to delete the token this server holds for it. A failure leaves it listed there.
    async fn revoke_remote_token(&self, remote: &Remote) {
        let init = FetchInit::method("DELETE").header("authorization", format!("Bearer {}", remote.token)).timeout(5000);
        let _ = self.0.fetcher.fetch(&format!("{}/api/token", remote.url), init).await;
    }

    async fn seal(&self, value: &str) -> String {
        crate::mail::secret::seal(value, self.0.secret.as_deref())
    }

    /// Connects a site counted by another Runlight (an app's own install) so this server shows it too.
    async fn add_remote_site(&self, input: &Value, name: Option<&Value>) -> Result<SiteRow, Error> {
        let url = js::trim(&js::str_or_empty(input.get("url"))).trim_end_matches('/').to_string();
        if !test(js_re!(r"^https://[^/]+|^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)"), &url) {
            return Err(Error::settings("Enter the install's address, like https://example.com/runlight", "connect_url", &[]));
        }
        let token = js::trim(&js::str_or_empty(input.get("token"))).to_string();
        if token.is_empty() {
            return Err(Error::settings("Enter an API token from that install", "install_token", &[]));
        }
        let fetcher = &self.0.fetcher;
        let auth = format!("Bearer {token}");
        let answer = match fetcher
            .fetch(&format!("{url}/api/sites"), FetchInit::default().header("authorization", &auth).timeout(10_000).max_bytes(REMOTE_MAX_BYTES))
            .await
        {
            Ok(a) => a,
            Err(crate::http::FetchError::TooLong(_)) => Response::status(200),
            Err(_) => {
                let host = Url::parse(&url).map(|u| u.host()).unwrap_or_default();
                return Err(Error::settings(format!("Could not reach {url}"), "unreachable", &[("host", &host)]));
            }
        };
        if answer.status == 401 || answer.status == 403 {
            return Err(Error::settings("That install refused the token", "install_refused", &[]));
        }
        let body = answer.json_body().ok();
        let sites: Vec<Value> = body.as_ref().and_then(|b| b.get("sites")).and_then(Value::as_array).cloned().unwrap_or_default();
        if !answer.ok() || sites.is_empty() {
            return Err(Error::settings(format!("{url} did not answer like a Runlight install"), "connect_not_runlight", &[("url", &url)]));
        }
        // What the token may do there; an install from before manage tokens has no /api/token and reads only.
        let mut scope = "read".to_string();
        let mut token_site = String::new();
        if let Ok(about) = fetcher
            .fetch(&format!("{url}/api/token"), FetchInit::default().header("authorization", &auth).timeout(10_000).max_bytes(REMOTE_MAX_BYTES))
            .await
            && about.ok()
            && let Ok(info) = about.json_body()
        {
            if info.get("scope").and_then(Value::as_str) == Some("manage") {
                scope = "manage".into();
            }
            token_site = js::str_or_empty(info.get("site"));
        }
        let wanted = if token_site.is_empty() { input.get("site").cloned() } else { Some(Value::String(token_site)) };
        let there = sites.iter().find(|s| match (&wanted, s.get("id")) {
            (Some(w), Some(id)) => w == id,
            (None, None) => true,
            _ => false,
        });
        let there = there.unwrap_or(&sites[0]).clone();
        // An install's answer is read as given: a site without a list of hostnames has none.
        let hostnames: Vec<String> = there
            .get("hostnames")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|h| h.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        let there_id = js::str_or_empty(there.get("id"));
        // Connecting the same site again (to allow changes, or with a new token) updates it in place.
        let known: Vec<(String, Remote)> = self.state().remotes.clone();
        for (existing, k) in known {
            if k.url == url && k.site == there_id {
                let updated = Remote { token: token.clone(), scope: Some(scope.clone()), hostnames: hostnames.clone(), ..k.clone() };
                if k.token != token {
                    self.revoke_remote_token(&k).await;
                }
                let sealed = self.seal(&updated.to_value().to_json()).await;
                self.0.store.set_setting(&format!("remote:{existing}"), Some(&sealed)).await?;
                {
                    let mut state = self.state();
                    if let Some(slot) = state.remotes.iter_mut().find(|(id, _)| *id == existing) {
                        slot.1 = updated;
                    }
                    state.remote_seen.remove(&existing);
                }
                return self.site(Some(&existing)).ok_or_else(|| Error::Range("Unknown site".into()));
            }
        }
        let host_source = hostnames.first().cloned().unwrap_or_else(|| Url::parse(&url).map(|u| u.host()).unwrap_or_default());
        let host = crate::re::replace_all(js_re!(r"(?i)[^a-z0-9._-]"), &host_source, "-").to_lowercase();
        let stem = js::head16(&host, 56);
        let mut id = stem.clone();
        let mut n = 2;
        while self.configured().iter().any(|s| s.id == id) {
            id = format!("{stem}-{n}");
            n += 1;
        }
        let given = js::head16(js::trim(&js::str_or_empty(name)), 80);
        let site_name = if given.is_empty() { js::str_or_empty(there.get("name")) } else { given };
        let tz = js::str_or_empty(there.get("timezone"));
        // No hostnames: tracker hits never land on a site that is counted elsewhere.
        let site = SiteRow { id: id.clone(), name: site_name, hostnames: vec![], timezone: if is_timezone(&tz) { tz } else { "UTC".into() } };
        let remote = Remote { url, token, site: there_id, hostnames, scope: Some(scope) };
        self.0.store.upsert_site(&site, self.now()).await?;
        let sealed = self.seal(&remote.to_value().to_json()).await;
        self.0.store.set_setting(&format!("remote:{id}"), Some(&sealed)).await?;
        let mut state = self.state();
        state.remotes.push((id, remote));
        state.configured.push(site.clone());
        state.configured.sort_by(|a, b| locale_compare(&a.name, &b.name));
        Ok(site)
    }

    /// Adds a site, when sites are managed in the dashboard: one counted here, or one connected from another install.
    pub async fn add_site(&self, input: &Value) -> Result<SiteRow, Error> {
        self.init().await?;
        if !self.0.managed_sites {
            return Err(Error::settings("Sites are set in code", "sites_in_code", &[]));
        }
        if let Some(remote) = input.get("remote")
            && js::truthy(remote)
            && (remote.is_object() || remote.is_array())
        {
            return self.add_remote_site(remote, input.get("name")).await;
        }
        let hostnames = self.hostnames_for(input.get("hostnames"), None)?;
        let given = js::trim(&js::str_or_empty(input.get("name"))).to_string();
        let name = if given.is_empty() { hostnames[0].clone() } else { given };
        if js::len16(&name) > 80 {
            return Err(Error::settings("A site name is 1 to 80 characters", "site_name", &[]));
        }
        let timezone = input.get("timezone").filter(|v| !v.is_null()).map_or_else(|| "UTC".to_string(), js::js_string);
        if !is_timezone(&timezone) {
            return Err(Error::settings(format!("Unknown timezone \"{timezone}\""), "unknown_timezone", &[("timezone", &timezone)]));
        }
        let stem = js::head16(&crate::re::replace_all(js_re!(r"[^a-z0-9._-]"), &hostnames[0], "-"), 56);
        let mut id = stem.clone();
        let mut n = 2;
        while self.configured().iter().any(|s| s.id == id) {
            id = format!("{stem}-{n}");
            n += 1;
        }
        let site = SiteRow { id, name, hostnames, timezone };
        self.0.store.upsert_site(&site, self.now()).await?;
        let mut state = self.state();
        state.configured.push(site.clone());
        state.configured.sort_by(|a, b| locale_compare(&a.name, &b.name));
        Ok(site)
    }

    /// Deletes a site and everything recorded for it, when sites are managed in the dashboard.
    pub async fn delete_site(&self, id: &str) -> Result<(), Error> {
        self.init().await?;
        if !self.0.managed_sites {
            return Err(Error::settings("Sites are set in code", "sites_in_code", &[]));
        }
        if !self.configured().iter().any(|s| s.id == id) {
            return Err(Error::settings("Unknown site", "unknown_site", &[]));
        }
        let store = &self.0.store;
        store.delete_site(id).await?;
        for key in ["retention", "observe-key", "rollup-zone", "orphans-swept"] {
            store.set_setting(&format!("{key}:{id}"), None).await?;
        }
        // A site made again with the same id starts its Umami import from the beginning.
        for (key, _) in store.settings_starting_with(&format!("import:umami-visits:{id}:")).await? {
            store.set_setting(&key, None).await?;
        }
        // A connected install keeps its own data; only the connection goes, and its token there with it.
        if let Some(remote) = self.remote(id) {
            self.revoke_remote_token(&remote).await;
            self.state().remotes.retain(|(k, _)| k != id);
            store.set_setting(&format!("remote:{id}"), None).await?;
        }
        let mut state = self.state();
        state.configured.retain(|s| s.id != id);
        state.overrides.remove(id);
        Ok(())
    }

    /// Changes a site's name, timezone, or (when managed) hostnames from the dashboard.
    pub async fn update_site(&self, id: &str, patch: &Value) -> Result<SiteRow, Error> {
        self.init().await?;
        let Some(current) = self.configured().into_iter().find(|s| s.id == id) else {
            return Err(Error::settings("Unknown site", "unknown_site", &[]));
        };
        let name_of = |v: &Value| -> Result<String, Error> {
            let name = js::trim(&js::js_string(v)).to_string();
            if name.is_empty() || js::len16(&name) > 80 {
                return Err(Error::settings("A site name is 1 to 80 characters", "site_name", &[]));
            }
            Ok(name)
        };
        let zone_of = |v: &Value| -> Result<String, Error> {
            let tz = js::js_string(v);
            if !is_timezone(&tz) {
                return Err(Error::settings(format!("Unknown timezone \"{tz}\""), "unknown_timezone", &[("timezone", &tz)]));
            }
            Ok(tz)
        };
        if self.0.managed_sites {
            let mut next = current.clone();
            if let Some(name) = patch.get("name") {
                next.name = name_of(name)?;
            }
            if let Some(tz) = patch.get("timezone") {
                next.timezone = zone_of(tz)?;
                if Some(next.timezone.clone()) != self.site(Some(id)).map(|s| s.timezone) {
                    self.zone_changed(id, &next.timezone).await?;
                }
            }
            if let Some(hostnames) = patch.get("hostnames")
                && !self.is_remote(id)
            {
                next.hostnames = self.hostnames_for(Some(hostnames), Some(id))?;
            }
            self.0.store.upsert_site(&next, self.now()).await?;
            let mut state = self.state();
            if let Some(slot) = state.configured.iter_mut().find(|s| s.id == id) {
                *slot = next;
            }
            drop(state);
            return self.site(Some(id)).ok_or_else(|| Error::Range("Unknown site".into()));
        }
        let mut next = self.state().overrides.get(id).cloned().unwrap_or_default();
        if let Some(name) = patch.get("name") {
            next.set("name", name_of(name)?);
        }
        if let Some(tz) = patch.get("timezone") {
            let tz = zone_of(tz)?;
            next.set("timezone", tz.clone());
            if Some(tz.clone()) != self.site(Some(id)).map(|s| s.timezone) {
                self.zone_changed(id, &tz).await?;
            }
        }
        self.0.store.set_site_overrides(id, &next).await?;
        self.state().overrides.insert(id.to_string(), next);
        self.site(Some(id)).ok_or_else(|| Error::Range("Unknown site".into()))
    }

    /// How many months of visits a site keeps, or `None` to keep everything (the default).
    pub async fn retention(&self, site: &str) -> Result<Option<i64>, Error> {
        let value = self.0.store.setting(&format!("retention:{site}")).await?;
        let n = value.map_or(0.0, |v| js::text_number(&v));
        Ok(RETENTION_MONTHS.iter().find(|m| **m as f64 == n).copied())
    }

    /// Sets how many months of visits a site keeps; the deleting runs after the answer.
    pub async fn set_retention(&self, site: &str, months: Option<i64>) -> Result<(), Error> {
        if self.site(Some(site)).is_none() || self.is_remote(site) {
            return Err(Error::settings("Unknown site", "unknown_site", &[]));
        }
        if let Some(m) = months
            && !RETENTION_MONTHS.contains(&m)
        {
            return Err(Error::settings("Keep visits for 6, 12, 24, 36, 60 months, or forever", "retention_bad", &[("months", "6, 12, 24, 36, 60")]));
        }
        self.0.store.set_setting(&format!("retention:{site}"), months.map(|m| m.to_string()).as_deref()).await?;
        // Deleting a long history takes a while, so it runs in pieces after the answer, with tracking going on between them.
        self.prune_later(Some(site.to_string()));
        Ok(())
    }

    fn prune_later(&self, only: Option<String>) {
        let rl = self.clone();
        let turn = self.0.prune_turn.clone();
        let handle = tokio::spawn(async move {
            let _turn = turn.lock().await;
            if let Err(error) = rl.apply_retention(only.as_deref()).await {
                eprintln!("Runlight: could not apply retention {error}");
            }
        });
        self.0.pruning.lock().unwrap_or_else(|e| e.into_inner()).push(handle);
    }

    /// Runs work after the answer, such as an email that must not slow a sign-in down. `idle()` waits for it.
    pub fn later<F>(&self, work: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        let handle = tokio::spawn(work);
        self.0.pruning.lock().unwrap_or_else(|e| e.into_inner()).push(handle);
    }

    /// Waits for retention work still running; the scheduled check and tests wait for it.
    pub async fn idle(&self) {
        loop {
            let handles: Vec<_> = std::mem::take(&mut *self.0.pruning.lock().unwrap_or_else(|e| e.into_inner()));
            if handles.is_empty() {
                return;
            }
            for h in handles {
                let _ = h.await;
            }
        }
    }

    /// Days are the site's local days, so a new timezone clears the built ones.
    async fn zone_changed(&self, id: &str, timezone: &str) -> Result<i64, Error> {
        let since = self.now();
        self.0.store.clear_rollups(id, None, None).await?;
        self.0.store.set_setting(&format!("rollup-zone:{id}"), Some(&obj_zone(timezone, since))).await?;
        Ok(since)
    }

    /// Since when a site's days may be built: 0 for always, or when its timezone last changed. `None`
    /// when this process holds a different timezone than the one on record.
    async fn rollup_since(&self, site: &SiteRow) -> Result<Option<i64>, Error> {
        let key = format!("rollup-zone:{}", site.id);
        let Some(stored) = self.0.store.setting(&key).await? else {
            self.0.store.set_setting(&key, Some(&obj_zone(&site.timezone, 0))).await?;
            return Ok(Some(0));
        };
        let zone = js::parse(&stored).unwrap_or(Value::Null);
        Ok((js::str_or_empty(zone.get("zone")) == site.timezone).then(|| js::to_i64(js::opt_number(zone.get("since")))))
    }

    /// Adds up each site's finished days, so long ranges read a row a day instead of every visit.
    pub async fn build_rollups(&self) -> Result<usize, Error> {
        let store = &self.0.store;
        // Days rolled up by an earlier way of counting are cleared once, and built again below.
        if store.setting("rollup-version").await?.as_deref() != Some(ROLLUP_VERSION) {
            for site in self.sites() {
                store.clear_rollups(&site.id, None, None).await?;
            }
            store.set_setting("rollup-version", Some(ROLLUP_VERSION)).await?;
        }
        let mut built = 0;
        let now = self.now();
        for site in self.sites() {
            if self.is_remote(&site.id) {
                continue;
            }
            let Some(first) = store.first_seen(&site.id).await? else { continue };
            let cutoff = self.retention_cutoff(&site.id).await?.unwrap_or(0);
            let Some(since) = self.rollup_since(&site).await? else { continue };
            let done = store.rollup_days(&site.id).await?;
            let today = local_date(now, &site.timezone);
            let batch = if store.db().metered() { METERED_ROLLUP_BATCH } else { ROLLUP_BATCH };
            let oldest = local_date(first.max(cutoff), &site.timezone);
            let mut made = 0;
            // Newest first, so recent ranges speed up before a long history is done.
            let mut day = add_days(&today, -1);
            while day >= oldest && made < batch {
                if !done.contains(&day) {
                    let start = start_of(&day, &site.timezone, 0);
                    let end = start_of(&add_days(&day, 1), &site.timezone, 0);
                    if start < since {
                        break;
                    }
                    if !(now < end + ROLLUP_DELAY_MS || start < cutoff) {
                        match store.build_rollup_day(&site.id, &day, start, end).await {
                            Ok(()) => made += 1,
                            // Another process building the same day at once loses nothing: the day is there either way.
                            Err(error) => {
                                if !store.rollup_days(&site.id).await?.contains(&day) {
                                    eprintln!("Runlight: could not add up {day} for {} {error}", site.id);
                                }
                            }
                        }
                        tokio::task::yield_now().await;
                    }
                }
                day = add_days(&day, -1);
            }
            built += made;
        }
        Ok(built)
    }

    /// The oldest moment a site keeps visits from, or `None` when it keeps everything.
    pub async fn retention_cutoff(&self, site: &str) -> Result<Option<i64>, Error> {
        let Some(months) = self.retention(site).await? else { return Ok(None) };
        Ok(Some(minus_months(self.now(), months)))
    }

    /// Deletes visits older than each site's retention allows. Cheap when there is nothing to delete.
    async fn apply_retention(&self, only: Option<&str>) -> Result<(), Error> {
        let store = &self.0.store;
        for site in self.sites() {
            if only.is_some_and(|o| o != site.id) || self.is_remote(&site.id) {
                continue;
            }
            let Some(cutoff) = self.retention_cutoff(&site.id).await? else { continue };
            store.drop_before(&site.id, cutoff).await?;
            // Earlier versions let an event join its visit days late, so retention could leave such an event
            // behind once its visit was gone. They are swept once.
            let key = format!("orphans-swept:{}", site.id);
            if store.setting(&key).await?.is_none_or(|v| v.is_empty()) {
                store.drop_orphans(&site.id, cutoff, self.now()).await?;
                store.set_setting(&key, Some("1")).await?;
            }
        }
        Ok(())
    }

    /// A site by id, or the first site when no id is given.
    pub fn site(&self, id: Option<&str>) -> Option<SiteRow> {
        let sites = self.sites();
        match id.filter(|i| !i.is_empty()) {
            None => sites.into_iter().next(),
            Some(id) => sites.into_iter().find(|s| s.id == id),
        }
    }

    /// The site a page belongs to, or `None` if it belongs to none.
    pub fn site_for(&self, hostname: &str, id: Option<&str>) -> Option<SiteRow> {
        let host = strip_www(hostname);
        let id = id.filter(|i| !i.is_empty());
        // A site counted by another install never takes hits here.
        let remotes: Vec<String> = self.state().remotes.iter().map(|(k, _)| k.clone()).collect();
        let sites = self.sites();
        if !remotes.is_empty() {
            let local: Vec<SiteRow> = sites.into_iter().filter(|s| !remotes.contains(&s.id)).collect();
            if let Some(id) = id
                && remotes.iter().any(|r| r == id)
            {
                return None;
            }
            return site_among(&local, &host, id);
        }
        site_among(&sites, &host, id)
    }

    /// A test from a developer's own machine while a site is being set up.
    async fn setup_site(&self, hostname: &str, id: Option<&str>) -> Result<Option<SiteRow>, Error> {
        let lower = hostname.to_lowercase();
        let host = lower.trim_start_matches('[').trim_end_matches(']');
        let host = {
            // `replace(/^\[|\]$/g, "")`: one bracket at each end at most.
            let mut h = lower.as_str();
            if let Some(rest) = h.strip_prefix('[') {
                h = rest;
            }
            if let Some(rest) = h.strip_suffix(']') {
                h = rest;
            }
            let _ = host;
            h.to_string()
        };
        if !(host == "localhost" || host == "127.0.0.1" || host == "::1" || test(js_re!(r"\.(localhost|local|test)$"), &host)) {
            return Ok(None);
        }
        let site = match id.filter(|i| !i.is_empty()) {
            Some(id) => self.site(Some(id)),
            None => {
                let sites = self.sites();
                if sites.len() == 1 { sites.into_iter().next() } else { None }
            }
        };
        let Some(site) = site else { return Ok(None) };
        if self.is_remote(&site.id) {
            return Ok(None);
        }
        Ok(self.0.store.last_seen(&site.id).await?.is_none().then_some(site))
    }

    /// The visitor's address, for the daily visitor hash and the rate limit.
    pub fn client_ip(&self, request: &Request) -> String {
        let h = &request.headers;
        let last = |name: &str| -> Option<String> {
            let value = h.get(name)?;
            value.split(',').map(|x| js::trim(x).to_string()).filter(|x| !x.is_empty()).next_back()
        };
        let forwarded = match &self.0.trust_proxy {
            TrustProxy::Off => None,
            TrustProxy::On => last("x-forwarded-for").or_else(|| h.get("x-real-ip")).or_else(|| h.get("cf-connecting-ip")),
            TrustProxy::Header(name) if name == "x-forwarded-for" => last("x-forwarded-for"),
            TrustProxy::Header(name) => h.get(name),
        };
        if let Some(f) = forwarded
            && !js::trim(&f).is_empty()
        {
            return js::trim(&f).to_string();
        }
        request.remote_address.clone()
    }

    /// Today's salt in a site's timezone and, if it still exists, yesterday's.
    async fn current_salts(&self, now: i64, timezone: &str) -> Result<(String, Option<String>), Error> {
        let day = local_date(now, timezone);
        if let Some((d, today, yesterday)) = self.state().salts.get(timezone).cloned()
            && d == day
        {
            return Ok((today, yesterday));
        }
        let today = self.0.store.salt(&day, &random_salt()).await?;
        let yesterday = self.0.store.salt_if_exists(&add_days(&day, -1)).await?;
        self.drop_old_salts(now).await?;
        self.state().salts.insert(timezone.to_string(), (day, today.clone(), yesterday.clone()));
        Ok((today, yesterday))
    }

    /// Deletes salts whose day has ended everywhere.
    async fn drop_old_salts(&self, now: i64) -> Result<(), Error> {
        self.0.store.drop_salts_before(&utc_day(now - 2 * 86_400_000)).await?;
        Ok(())
    }

    /// The host a proxy says the request was for, read only when proxy headers are trusted.
    pub(crate) fn forwarded_host(&self, request: &Request) -> Option<String> {
        if self.0.trust_proxy == TrustProxy::Off { None } else { request.headers.get("x-forwarded-host") }
    }

    /// Handles one tracker request. Always succeeds unless the database fails; bad input is dropped quietly.
    pub async fn collect(&self, request: &Request) -> Result<(), Error> {
        let length = request.headers.get("content-length").map_or(0.0, |l| js::text_number(&l));
        if length > MAX_BODY as f64 {
            return Ok(());
        }
        // Read no more than a tracker hit can be, whatever the length header says.
        if request.body.len() > MAX_BODY {
            return Ok(());
        }
        let text = request.text();
        let Some(payload) = parse_payload(&text) else { return Ok(()) };
        let ua = request.headers.get("user-agent").unwrap_or_default();
        if ai_agent(&ua).is_some() || is_bot(&ua) {
            return Ok(());
        }
        if let Some(limit) = &self.0.limit
            && !limit.allow(&self.client_ip(request), self.now())
        {
            return Ok(());
        }
        // A database too busy to take the hit right now gets it a little later, at the time it arrived.
        let now = self.now();
        let mut attempt = 1;
        loop {
            match self.record(&payload, request, now).await {
                Err(error) if attempt < 3 && busy(&error) => {
                    tokio::time::sleep(std::time::Duration::from_millis(500 * attempt)).await;
                    attempt += 1;
                }
                other => return other,
            }
        }
    }

    async fn record(&self, payload: &Payload, request: &Request, now: i64) -> Result<(), Error> {
        // Managed sites load from the database in init(), so it must come first.
        self.init().await?;
        let hostname = payload.url.hostname();
        let site = match self.site_for(&hostname, Some(&payload.site)) {
            Some(s) => s,
            None => match self.setup_site(&hostname, Some(&payload.site)).await? {
                Some(s) => s,
                None => return Ok(()),
            },
        };
        if payload.kind == "engagement" {
            return self.engagement(&site, payload, now).await;
        }
        let store = &self.0.store;
        let page = parse_page(&payload.url);
        let mut session: Option<(String, String)> = None;
        let mut reopen = true;
        if payload.kind == "event"
            && !payload.pageview_id.is_empty()
            && let Some(pageview) = store.pageview(&site.id, &payload.pageview_id).await?
            && now - pageview.started_at < EVENT_TAIL_MS
        {
            // An event joins its page's visit unless that visit began longer ago than reports look for its rows.
            session = Some((pageview.session.clone(), pageview.visitor.clone()));
            // A visit idle past the 30 minutes stays ended: the event counts in it without reopening it.
            reopen = now - pageview.last_at <= SESSION_IDLE_MS;
            if now - pageview.started_at > 3_600_000 {
                store.touched_old_visit(&site.id, pageview.started_at, now - ROLLUP_DELAY_MS + 3_600_000).await?;
            }
        }
        let (id, visitor) = match session {
            Some(s) => s,
            None => {
                let screen = match (payload.screen_width, payload.screen_height) {
                    (Some(w), Some(h)) if w != 0 && h != 0 => format!("{w}x{h}"),
                    _ => String::new(),
                };
                self.session_for(&site, request, &page, &payload.referrer, now, payload.screen_width.map(|w| w as f64), &screen, &payload.language)
                    .await?
            }
        };
        store.touch_session(&id, now, payload.kind, &page.path, reopen).await?;
        store
            .insert_event(&EventRow {
                site: site.id.clone(),
                ts: now,
                kind: payload.kind.into(),
                visitor,
                session: id,
                pageview: payload.pageview_id.clone(),
                path: page.path.clone(),
                hostname: page.hostname.clone(),
                title: if payload.kind == "pageview" { payload.title.clone() } else { String::new() },
                name: if payload.kind == "event" { payload.name.clone() } else { String::new() },
                props: payload.props.clone(),
                engaged_ms: 0,
                scroll: None,
                link: String::new(),
            })
            .await?;
        Ok(())
    }

    /// The visitor's open session on a site, or a new one attributed to this request. Shared by
    /// tracker hits and short link clicks. Gives its id and visitor.
    #[allow(clippy::too_many_arguments)]
    async fn session_for(
        &self,
        site: &SiteRow,
        request: &Request,
        page: &Page,
        referrer: &str,
        now: i64,
        screen_width: Option<f64>,
        screen: &str,
        language: &str,
    ) -> Result<(String, String), Error> {
        let ua = request.headers.get("user-agent").unwrap_or_default();
        let ip = self.client_ip(request);
        let (today_salt, yesterday_salt) = self.current_salts(now, &site.timezone).await?;
        let today = visitor_hash(&today_salt, &site.id, &ip, &ua);
        let mut candidates = vec![today.clone()];
        if let Some(y) = yesterday_salt {
            candidates.push(visitor_hash(&y, &site.id, &ip, &ua));
        }
        // One visitor's requests often arrive together (a pageview and the event right after it). Taking
        // turns per visitor means only the first opens a session and the rest find it.
        let key = format!("{}:{today}", site.id);
        let turn = {
            let mut turns = self.0.turns.lock().unwrap_or_else(|e| e.into_inner());
            turns.entry(key.clone()).or_default().clone()
        };
        let guard = turn.lock().await;
        let result = async {
            let store = &self.0.store;
            if let Some(open) = store.open_session(&site.id, &candidates, now - SESSION_IDLE_MS).await? {
                return Ok(open);
            }
            let id = new_id();
            let attribution = attribute(page, referrer, &site.hostnames);
            let parsed = parse_client(
                &ua,
                &ClientHints {
                    brands: request.headers.get("sec-ch-ua"),
                    mobile: request.headers.get("sec-ch-ua-mobile"),
                    platform: request.headers.get("sec-ch-ua-platform"),
                },
                screen_width,
            );
            let location = locate(&request.headers, &ip, self.0.geo.as_ref()).await;
            store
                .insert_session(&SessionRow {
                    id: id.clone(),
                    site: site.id.clone(),
                    visitor: today.clone(),
                    started_at: now,
                    hostname: page.hostname.clone(),
                    referrer_host: attribution.referrer_host,
                    referrer_path: attribution.referrer_path,
                    source: attribution.source,
                    channel: attribution.channel.into(),
                    utm_source: page.utm.source.clone(),
                    utm_medium: page.utm.medium.clone(),
                    utm_campaign: page.utm.campaign.clone(),
                    utm_term: page.utm.term.clone(),
                    utm_content: page.utm.content.clone(),
                    country: location.country,
                    region: location.region,
                    city: location.city,
                    browser: parsed.browser,
                    browser_version: parsed.browser_version,
                    os: parsed.os,
                    os_version: parsed.os_version,
                    device: parsed.device.into(),
                    screen: screen.into(),
                    language: language.into(),
                })
                .await?;
            Ok::<(String, String), Error>((id, today.clone()))
        }
        .await;
        drop(guard);
        let mut turns = self.0.turns.lock().unwrap_or_else(|e| e.into_inner());
        if turns.get(&key).is_some_and(|t| Arc::strong_count(t) <= 2) {
            turns.remove(&key);
        }
        result
    }

    /// The link domains, read at most every 30 seconds.
    async fn link_domain_set(&self) -> Result<HashSet<String>, Error> {
        let now = self.now();
        if let Some((at, domains)) = &self.state().link_domains
            && now - at < 30_000
        {
            return Ok(domains.clone());
        }
        self.init().await?;
        let domains: HashSet<String> = self.0.store.link_domains().await?.into_iter().map(|(d, _)| d).collect();
        self.state().link_domains = Some((now, domains.clone()));
        Ok(domains)
    }

    /// Clears the cached link domains after one is added or removed.
    pub fn forget_link_domains(&self) {
        self.state().link_domains = None;
    }

    /// Handles `{link_path}/{slug}` on the app's own domain.
    pub async fn link_response(&self, request: &Request) -> Result<Response, Error> {
        let path = request.parsed_url().pathname();
        let prefix = format!("{}/", self.0.link_path);
        let slug = match path.strip_prefix(&prefix) {
            Some(rest) => decode_uri_component(rest).ok_or_else(|| Error::Other("URIError: URI malformed".into()))?,
            None => String::new(),
        };
        let found = if !slug.is_empty() && !slug.contains('/') { self.redirect(request, &slug, "").await? } else { None };
        Ok(found.unwrap_or_else(not_found))
    }

    /// For middleware: when a request arrives on a link domain added in Settings (such as
    /// t.example.com), answers `/{slug}` there with the redirect, and anything else with a 404. `None`
    /// for every other host, so the app carries on as normal, and for the dashboard's own paths.
    pub async fn link_domain_response(&self, request: &Request) -> Result<Option<Response>, Error> {
        let url = request.parsed_url();
        // A forwarded host only counts behind a proxy that sets it; otherwise any client could pick one.
        let given = self.forwarded_host(request).or_else(|| request.headers.get("host")).unwrap_or_else(|| url.host());
        let first = js::trim(given.split(',').next().unwrap_or("")).to_string();
        let host = strip_www(first.split(':').next().unwrap_or(""));
        if !self.link_domain_set().await?.contains(&host) {
            return Ok(None);
        }
        let pathname = url.pathname();
        // Lets the dashboard confirm that requests to this domain reach Runlight.
        if pathname == LINK_DOMAIN_CHECK {
            return Ok(Some(Response::new(
                crate::obj! { "runlight" => true, "domain" => host }.to_json(),
                200,
                Headers::new().with("content-type", "application/json").with("cache-control", "no-store"),
            )));
        }
        let bases = {
            let b = self.0.route_bases.lock().unwrap_or_else(|e| e.into_inner()).clone();
            if b.is_empty() { vec!["/runlight".to_string()] } else { b }
        };
        for base in bases {
            if base != "/" && (pathname == base || pathname.starts_with(&format!("{base}/"))) {
                return Ok(None);
            }
        }
        let slug = decode_uri_component(&pathname[1.min(pathname.len())..]).ok_or_else(|| Error::Other("URIError: URI malformed".into()))?;
        let found = if !slug.is_empty() && !slug.contains('/') { self.redirect(request, &slug, &host).await? } else { None };
        Ok(Some(found.unwrap_or_else(not_found)))
    }

    /// Answers a request for a short link: a redirect to its destination, with the click recorded like
    /// a visit but kept out of visitor and pageview counts. `None` when no link fits.
    pub async fn redirect(&self, request: &Request, slug: &str, domain: &str) -> Result<Option<Response>, Error> {
        self.init().await?;
        let url = request.parsed_url();
        let given = self.forwarded_host(request).or_else(|| request.headers.get("host")).unwrap_or_else(|| url.host());
        let host = strip_www(given.split(':').next().unwrap_or(""));
        let Some(link) = self.0.store.link_by_slug(slug).await? else { return Ok(None) };
        // The app's own link path answers for every link; a link domain answers only for its own links.
        if !domain.is_empty() && link.domain != domain {
            return Ok(None);
        }
        let site = self.site(Some(&link.site)).or_else(|| self.sites().into_iter().next());
        let ua = request.headers.get("user-agent").unwrap_or_default();
        if let Some(site) = site
            && ai_agent(&ua).is_none()
            && !is_bot(&ua)
            && request.method == "GET"
        {
            let recorded = async {
                let now = self.now();
                let accept = request.headers.get("accept-language").unwrap_or_default();
                let first = accept.split(',').next().unwrap_or("").split(';').next().unwrap_or("");
                let language = js::head16(js::trim(first), 35);
                let referer = request.headers.get("referer").unwrap_or_default();
                let (id, visitor) = self.session_for(&site, request, &parse_page(&url), &referer, now, None, "", &language).await?;
                let pathname = url.pathname();
                self.0.store.touch_session(&id, now, "click", &pathname, true).await?;
                self.0
                    .store
                    .insert_event(&EventRow {
                        site: site.id.clone(),
                        ts: now,
                        kind: "click".into(),
                        visitor,
                        session: id,
                        pageview: String::new(),
                        path: js::head16(&pathname, 1000),
                        hostname: host.clone(),
                        title: String::new(),
                        name: link.slug.clone(),
                        props: None,
                        engaged_ms: 0,
                        scroll: None,
                        link: link.id.clone(),
                    })
                    .await?;
                Ok::<(), Error>(())
            }
            .await;
            // A failed count must never break the redirect.
            if let Err(error) = recorded {
                eprintln!("Runlight: could not record a link click {error}");
            }
        }
        Ok(Some(Response::new(
            Vec::new(),
            302,
            Headers::new().with("location", &link.url).with("cache-control", "no-store").with("referrer-policy", "no-referrer-when-downgrade"),
        )))
    }

    async fn engagement(&self, site: &SiteRow, payload: &Payload, now: i64) -> Result<(), Error> {
        if payload.engaged_ms <= 0 {
            return Ok(());
        }
        let store = &self.0.store;
        let Some(pageview) = store.pageview(&site.id, &payload.pageview_id).await? else { return Ok(()) };
        // Reports look for a visit's rows only so long after it began, so later time on it is let go.
        if now - pageview.started_at >= EVENT_TAIL_MS {
            return Ok(());
        }
        store.add_engagement(&pageview.session, payload.engaged_ms).await?;
        // Only a visit that began more than an hour ago can belong to a day that is already added up.
        if now - pageview.started_at > 3_600_000 {
            store.touched_old_visit(&site.id, pageview.started_at, now - ROLLUP_DELAY_MS + 3_600_000).await?;
        }
        store
            .insert_event(&EventRow {
                site: site.id.clone(),
                ts: now,
                kind: "engagement".into(),
                visitor: pageview.visitor,
                session: pageview.session,
                pageview: payload.pageview_id.clone(),
                path: pageview.path,
                hostname: pageview.hostname,
                title: String::new(),
                name: String::new(),
                props: None,
                engaged_ms: payload.engaged_ms,
                scroll: payload.scroll,
                link: String::new(),
            })
            .await?;
        Ok(())
    }

    /// Records a request from a known AI agent. Call it from middleware for every page request; it
    /// ignores everything else and never fails. `at` is when a log reader saw the page served.
    pub async fn observe(&self, request: &Request, at: Option<f64>) -> bool {
        match self.observe_inner(request, at).await {
            Ok(done) => done,
            Err(error) => {
                // Analytics must never break the page it watches, but a failure should still be seen.
                eprintln!("Runlight: could not record an AI agent fetch {error}");
                false
            }
        }
    }

    async fn observe_inner(&self, request: &Request, at: Option<f64>) -> Result<bool, Error> {
        if request.method != "GET" {
            return Ok(false);
        }
        let Some(agent) = ai_agent(&request.headers.get("user-agent").unwrap_or_default()) else { return Ok(false) };
        let Some(url) = Url::parse(&request.url) else { return Err(Error::Other("TypeError: Invalid URL".into())) };
        // Pages, not their assets.
        let pathname = url.pathname();
        if let Some(ext) = crate::re::group(js_re!(r"(?i)\.([a-z0-9]+)$"), &pathname, 1)
            && !["html", "htm", "md", "txt", "php"].contains(&ext.to_lowercase().as_str())
        {
            return Ok(false);
        }
        let host = self.forwarded_host(request).or_else(|| request.headers.get("host")).unwrap_or_else(|| url.hostname());
        self.init().await?;
        let Some(site) = self.site_for(host.split(':').next().unwrap_or(&host), None) else { return Ok(false) };
        // A log reader sends when the page was served. Older than a week is dropped; ahead of now counts as now.
        let now = self.now();
        if let Some(at) = at
            && at.is_finite()
            && at < (now - 7 * 86_400_000) as f64
        {
            return Ok(false);
        }
        let ts = match at {
            Some(at) if at.is_finite() && at <= now as f64 => at.floor() as i64,
            _ => now,
        };
        let mut props = Object::new();
        props.set("company", agent.company);
        props.set("kind", agent.kind);
        self.0
            .store
            .insert_event(&EventRow {
                site: site.id,
                ts,
                kind: "fetch".into(),
                visitor: String::new(),
                session: String::new(),
                pageview: String::new(),
                path: js::head16(&pathname, 1000),
                hostname: strip_www(&url.hostname()),
                title: String::new(),
                name: agent.name.into(),
                props: Some(props),
                engaged_ms: 0,
                scroll: None,
                link: String::new(),
            })
            .await?;
        Ok(true)
    }

    /// Scheduled upkeep, safe to run every minute: salts, retention, rollups, and the email reports
    /// that are due. Also rereads sites and their dashboard settings, so a change made by another
    /// process sharing the database shows up here too.
    pub async fn check(&self) -> Result<Value, Error> {
        // A check still running when the next is due is waited for, never run twice at once.
        let _turn = self.0.checking.lock().await;
        self.init().await?;
        let store = &self.0.store;
        if self.0.managed_sites {
            let sites = store.sites().await?;
            self.state().configured = sites;
            self.load_remotes().await?;
        }
        // A name or timezone changed in the dashboard by another process reaches this one too.
        let overrides = store.site_overrides().await?;
        {
            let mut state = self.state();
            state.overrides = overrides;
            state.salts.clear();
        }
        let mut zones: Vec<String> = Vec::new();
        for site in self.sites() {
            if !zones.contains(&site.timezone) {
                zones.push(site.timezone);
            }
        }
        for zone in zones {
            self.current_salts(self.now(), &zone).await?;
        }
        self.drop_old_salts(self.now()).await?;
        self.idle().await;
        {
            let _turn = self.0.prune_turn.lock().await;
            if let Err(error) = self.apply_retention(None).await {
                eprintln!("Runlight: could not apply retention {error}");
            }
        }
        let due = {
            let mut state = self.state();
            let due = self.now() - state.optimized_at >= 86_400_000;
            if due {
                state.optimized_at = self.now();
            }
            due
        };
        if due {
            store.optimize(false).await;
        }
        self.build_rollups().await?;
        let reports = self.send_reports().await?;
        Ok(crate::obj! { "ok" => true, "reports" => crate::obj! { "sent" => reports.0, "failed" => reports.1 } })
    }
}

fn obj_zone(zone: &str, since: i64) -> String {
    crate::obj! { "zone" => zone, "since" => since }.to_json()
}

fn site_among(sites: &[SiteRow], host: &str, id: Option<&str>) -> Option<SiteRow> {
    if let Some(id) = id {
        let site = sites.iter().find(|s| s.id == id)?;
        return (site.hostnames.is_empty() || site.hostnames.iter().any(|h| h == host)).then(|| site.clone());
    }
    if sites.len() == 1 {
        let only = &sites[0];
        return (only.hostnames.is_empty() || only.hostnames.iter().any(|h| h == host)).then(|| only.clone());
    }
    sites.iter().find(|s| s.hostnames.iter().any(|h| h == host)).cloned()
}

/// A domain name, such as go.example.com.
pub fn is_domain(host: &str) -> bool {
    let len = host.chars().count();
    (1..=253).contains(&len) && test(js_re!(r"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"), host)
}

/// `new Date(now)` moved `months` back with `setUTCMonth`, which lets the day overflow into the next month.
fn minus_months(now: i64, months: i64) -> i64 {
    let days = now.div_euclid(86_400_000);
    let rest = now.rem_euclid(86_400_000);
    let (y, m, d) = js::civil_from_days(days);
    js::date_utc(y, m - 1 - months, d, 0, 0, 0, 0) + rest
}

fn not_found() -> Response {
    Response::new("Not found", 404, Headers::new().with("content-type", "text/plain; charset=utf-8"))
}

/// True for a database that could not take a statement just now and may a moment later.
fn busy(error: &Error) -> bool {
    test(
        js_re!(r"(?i)timeout exceeded when trying to connect|connection timeout|no MySQL connection was free|SQLITE_BUSY|database is locked"),
        error.message(),
    )
}
