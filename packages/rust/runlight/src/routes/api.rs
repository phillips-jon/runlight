//! The HTTP API's dispatch: who may do what, then each endpoint.

use super::parts::{R, rows_csv, sheet_row};
use super::*;
use crate::error::Error;
use crate::query::{Query, dimensions, is_dimension};
use crate::runlight::RETENTION_MONTHS;
use crate::store::ShareRow;
use crate::time::{buckets, is_timezone, local_weekday_hour};

impl Routes {
    pub(crate) async fn api(&self, request: &Request, path: &str, url: &mut Url, call: &Call) -> R {
        let rl = self.rl().clone();
        let method = request.method.as_str();
        // An embedded dashboard reads what a share link shows and nothing else, whoever else the request comes from.
        if request.headers.get(EMBED_HEADER).is_some() && !(method == "GET" && shared_path(path)) {
            return Ok(coded("Not available on a shared dashboard", "share_not_available", 403, None));
        }
        // A write must be JSON, which a form on another page cannot send, even the writes that carry no body.
        if !["GET", "HEAD", "OPTIONS", "DELETE"].contains(&method) && bearer(request).is_empty() && !is_json(request) {
            return Ok(coded("Send JSON", "send_json", 415, None));
        }
        if path == "/api" && method == "GET" {
            return Ok(json(
                &obj! { "name" => "runlight", "version" => glue::VERSION, "api" => glue::API_VERSION, "library" => "runlight", "language" => "rust" },
                200,
                &[],
            ));
        }
        // A hub asks what its token may do before offering to change anything.
        if path == "/api/token" && method == "GET" {
            let Some(token) = self.api_token(request).await? else { return Ok(self.denied(CanRead::No)) };
            return Ok(json(&obj! { "scope" => token.scope, "site" => token.site }, 200, &[]));
        }
        // A token can delete itself, which a hub does when it disconnects a site or gets a new token.
        if path == "/api/token" && method == "DELETE" {
            let Some(token) = self.api_token(request).await? else { return Ok(self.denied(CanRead::No)) };
            rl.store().delete_token(&token.id).await?;
            return Ok(json(&obj! { "ok" => true }, 200, &[]));
        }

        // Connecting another Runlight through its consent page, so nobody copies a token.
        if path == "/api/sites/connect" && method == "POST" {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            rl.init().await?;
            if !rl.managed_sites() {
                return Ok(coded("Sites are set in code", "sites_in_code", 400, None));
            }
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            let done = format!("{}{}/api/sites/connect/done", url.origin(), self.0.base);
            return glue::start_connect(self, &body, &done).await;
        }
        if path == "/api/sites/connect/done" && method == "GET" {
            let home = if self.0.base.is_empty() { "/".to_string() } else { self.0.base.clone() };
            let access = self.can_read(request, call).await;
            let see_other = |to: String| {
                Response::new(Vec::new(), 303, Headers::new().with("location", to).with("cache-control", "no-store"))
            };
            if access != CanRead::Yes {
                return Ok(see_other(home));
            }
            rl.init().await?;
            let to = match glue::finish_connect(self, url).await? {
                Ok(id) => {
                    format!("{home}?site={}&settings=general&connected=1", crate::sources::encode_uri_component(&id))
                }
                // A code, never the message: the dashboard shows its own words for it.
                Err(code) => format!("{home}?connect_error={code}"),
            };
            return Ok(see_other(to));
        }

        // A ticket for one load of the dashboard inside a CMS's admin pages. The plugin's server asks with its embed
        // token on each page view and names the admin's origin, which must be one of the site's domains and alone
        // may frame the page the ticket opens.
        if path == "/api/embed" && method == "POST" {
            let Some(token) = self.api_token(request).await? else { return Ok(self.denied(CanRead::No)) };
            if token.scope != "embed" {
                return Ok(coded(
                    "Use a key for the dashboard in a CMS, made in Settings, Install",
                    "embed_token",
                    403,
                    None,
                ));
            }
            let Some(site) = rl.site(Some(&token.site)) else {
                return Ok(coded("Unknown site", "unknown_site", 404, None));
            };
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            let origin = js::str_or_empty(body.get("origin"));
            let parsed = (test(js_re!(r"^https?://[^/?#\s]+$"), &origin)
                && !origin.chars().any(js::is_space)
                && js::len16(&origin) <= 200)
                .then(|| Url::parse(&origin))
                .flatten()
                .filter(|u| u.origin() == origin);
            let Some(parsed) = parsed else {
                return Ok(coded(
                    "Send the admin page's origin, such as https://example.com",
                    "embed_origin",
                    400,
                    None,
                ));
            };
            let host = host_name(&parsed.host());
            let domains = rl.remote(&site.id).map_or(site.hostnames.clone(), |r| r.hostnames);
            if !domains.iter().any(|d| host_name(d) == host) {
                return Ok(coded(
                    &format!(
                        "{host} is not one of this site's domains. Add it to the site's domains in Runlight's settings."
                    ),
                    "embed_host",
                    400,
                    Some(&[("host", host.as_str())]),
                ));
            }
            let (ticket, expires_at) = self.embed_ticket(&origin, &token.id).await?;
            let path = format!("{}/embed?ticket={ticket}", self.0.base);
            return Ok(json(
                &obj! { "ticket" => ticket, "site" => site.id.clone(), "expiresAt" => expires_at, "path" => path },
                201,
                &[],
            ));
        }

        let token = if bearer(request).starts_with(TOKEN_PREFIX) { self.api_token(request).await? } else { None };
        // An embed token gets tickets and reads nothing itself.
        if token.as_ref().is_some_and(|t| t.scope == "embed") {
            return Ok(coded("This key only opens the dashboard inside a CMS", "token_embed_only", 403, None));
        }
        if let Some(t) = &token
            && t.scope == "manage"
            && manage_path(method, path)
        {
            let asked = url.search_params().get("site").map(str::to_string);
            let site_match = crate::re::group(js_re!(r"^/api/sites/([^/]+)$"), path, 1);
            let named = site_match.as_deref().map(|s| crate::sources::decode_uri_component(s).unwrap_or_default());
            if asked.as_deref().is_some_and(|a| !a.is_empty() && a != t.site)
                || named.as_deref().is_some_and(|n| n != t.site)
            {
                return Ok(coded("Unknown site", "unknown_site", 404, None));
            }
            if site_match.is_some()
                && is_json(request)
                && let Ok(body) = request.json()
                && body.is_object()
                && body.get("hostnames").is_some()
            {
                // Where a site lives stays with its owner: a hub may rename it, never move it.
                return Ok(coded("A connected hub cannot change a site's domains", "hub_domains", 403, None));
            }
            let mut params = url.search_params();
            params.set("site", &t.site);
            url.set_search_params(&params);
            *call.managed.lock().unwrap_or_else(|e| e.into_inner()) = Some(t.clone());
        }
        // A token this install made that tries a change it may not make is known, just not allowed, as for a viewer.
        if let Some(t) = &token
            && !call.is_managed()
            && !["GET", "HEAD", "OPTIONS"].contains(&method)
        {
            return Ok(if t.scope == "manage" {
                coded("A manage token changes only its own site's settings", "token_manage_only", 403, None)
            } else {
                coded("API tokens can only read", "token_read_only", 403, None)
            });
        }

        // A page another site served to an AI agent, reported by a CMS plugin.
        if path == "/api/observe" && method == "POST" {
            return self.observe_api(request, call).await;
        }

        // GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
        if path == "/api/check" && (method == "POST" || method == "GET") {
            let given = bearer(request);
            let by_secret =
                self.0.cron_secret.as_deref().is_some_and(|s| !given.is_empty() && constant_time_equal(&given, s));
            if !by_secret && self.can_read(request, call).await != CanRead::Yes {
                return Ok(coded("Unauthorized", "unauthorized", 401, None));
            }
            return Ok(json(&rl.check().await?, 200, &[]));
        }

        // A site counted by another install is read there.
        let asked = url.search_params().get("site").map(str::to_string);
        let connected = asked.as_deref().filter(|a| !a.is_empty()).and_then(|a| rl.remote(a));
        if let Some(remote) = &connected {
            if remote.scope.as_deref() == Some("manage")
                && manage_path(method, path)
                && !(method == "GET" && shared_path(path))
            {
                let access = self.can_read(request, call).await;
                if access != CanRead::Yes {
                    return Ok(self.denied(access));
                }
                if method != "GET" {
                    rl.forget_remote_info(asked.as_deref().unwrap_or(""));
                }
                return self.pass_through(remote, path, url, Some(request)).await;
            }
            if !(method == "GET" && (shared_path(path) || path == "/api/links")) {
                return Ok(coded(
                    "This site is counted by its own Runlight. Connect it again from its settings to change it from here.",
                    "site_remote",
                    400,
                    None,
                ));
            }
        }

        // Visit history from Umami: list the account's websites, then import one a step at a time.
        if (path == "/api/import/umami/websites" || path == "/api/import/umami/visits") && method == "POST" {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            return glue::umami_import(self, path, url, &body).await;
        }
        // Visit history from a CSV file, a batch at a time.
        if path == "/api/import/csv/visits" && method == "POST" {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            rl.init().await?;
            let site = match self.query_site(url) {
                Ok(s) => s,
                Err(r) => return Ok(r),
            };
            return glue::csv_import(self, &site.id, &body).await;
        }

        // Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on request.
        if (path == "/api/observe-key" && method == "GET") || (path == "/api/observe-key/new" && method == "POST") {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            rl.init().await?;
            let site = match self.query_site(url) {
                Ok(s) => s,
                Err(r) => return Ok(r),
            };
            let name = format!("observe-key:{}", site.id);
            let mut key =
                if path.ends_with("/new") { None } else { rl.store().setting(&name).await?.filter(|k| !k.is_empty()) };
            if key.is_none() {
                let made = format!("rlo_{}", random_id(20));
                rl.store().set_setting(&name, Some(&made)).await?;
                key = Some(made);
            }
            return Ok(json(&obj! { "key" => key }, 200, &[]));
        }

        // Making, changing, and deleting funnels; reading them is with the other reports.
        if (path == "/api/funnels" && method == "POST")
            || (test(js_re!(r"^/api/funnels/[a-f0-9]{24}$"), path) && (method == "PATCH" || method == "DELETE"))
        {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            rl.init().await?;
            let site = match self.query_site(url) {
                Ok(s) => s,
                Err(r) => return Ok(r),
            };
            let existing = rl.store().funnels(&site.id).await?;
            let id = if path == "/api/funnels" { None } else { Some(path["/api/funnels/".len()..].to_string()) };
            if let Some(id) = &id
                && !existing.iter().any(|f| &f.id == id)
            {
                return Ok(coded("Unknown funnel", "unknown_funnel", 404, None));
            }
            if method == "DELETE" {
                rl.store().delete_funnel(id.as_deref().unwrap_or("")).await?;
                return Ok(json(&obj! { "ok" => true }, 200, &[]));
            }
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            return Ok(match crate::funnels::funnel_from(&body, &site.id, &existing, rl.now(), id.as_deref()) {
                Ok(funnel) => {
                    rl.store().save_funnel(&funnel).await?;
                    json(&obj! { "funnel" => funnel.to_value() }, if id.is_some() { 200 } else { 201 }, &[])
                }
                Err(e) => refused(&e, 400),
            });
        }

        // The assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
        if path.starts_with("/api/assistant")
            && let Some(answer) = glue::assistant_api(self, request, path, url, call).await?
        {
            return Ok(answer);
        }

        // Only the owner manages tokens: an API token cannot make or revoke one.
        if path == "/api/tokens" || path.starts_with("/api/tokens/") {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            return self.tokens_api(request, path).await;
        }

        if let Some(remote) = &connected
            && path == "/api/links"
        {
            let reader = self.reader(request, call).await?;
            if matches!(reader, Reader::No | Reader::Unconfigured) {
                return Ok(self.denied_reader(&reader));
            }
            // A token limited to one site reads only that site's links, here as everywhere else.
            if let Reader::Token(t) = &reader
                && !t.site.is_empty()
                && Some(t.site.as_str()) != asked.as_deref()
            {
                return Ok(coded("Unknown site", "unknown_site", 404, None));
            }
            return self.pass_through(remote, path, url, None).await;
        }

        // An API token, or someone signed in to read, may list links and see each one's clicks, but not change them.
        if method == "GET" && (path == "/api/links" || test(js_re!(r"^/api/links/[a-f0-9]+$"), path)) {
            let reader = self.reader(request, call).await?;
            if matches!(reader, Reader::No | Reader::Unconfigured) {
                return Ok(self.denied_reader(&reader));
            }
            if let Reader::Token(t) = &reader {
                rl.init().await?;
                let wanted = url
                    .search_params()
                    .get("site")
                    .map(str::to_string)
                    .or_else(|| (!t.site.is_empty()).then(|| t.site.clone()));
                let site = rl.site(wanted.as_deref());
                let Some(site) = site.filter(|s| t.site.is_empty() || s.id == t.site) else {
                    return Ok(coded("Unknown site", "unknown_site", 404, None));
                };
                let mut scoped = url.clone();
                let mut params = scoped.search_params();
                params.set("site", &site.id);
                scoped.set_search_params(&params);
                return self.links_api(request, path, &scoped, call).await;
            }
        }

        if path == "/api/links"
            || path.starts_with("/api/links/")
            || path == "/api/link-domains"
            || path.starts_with("/api/link-domains/")
        {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            return self.links_api(request, path, url, call).await;
        }

        if path == "/api/mail"
            || path == "/api/mail/test"
            || path == "/api/reports"
            || path.starts_with("/api/reports/")
        {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            return self.mail_api(request, path, url, call).await;
        }

        // A ticket for the element picker, naming the dashboard it may send its choice to.
        if path == "/api/pick" && method == "POST" {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            rl.init().await?;
            let site = match self.query_site(url) {
                Ok(s) => s,
                Err(r) => return Ok(r),
            };
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            let origin = js::str_or_empty(body.get("origin"));
            if !test(js_re!(r"^https?://[^/?#\s]+$"), &origin) || origin.chars().any(js::is_space) {
                return Ok(coded(
                    "Send the dashboard's origin, such as https://stats.example.com",
                    "pick_origin",
                    400,
                    None,
                ));
            }
            // A hub's ticket only ever sends to the hub it connected from, never to an origin it names now.
            if let Some(hub) = call.managed()
                && rl.store().setting(&format!("token-origin:{}", hub.id)).await?.as_deref() != Some(origin.as_str())
            {
                return Ok(coded(
                    "This hub's address is not the one it connected from. Connect the site again from here.",
                    "pick_hub",
                    403,
                    None,
                ));
            }
            return Ok(json(&obj! { "ticket" => self.pick_ticket(&origin, &site.id).await? }, 200, &[]));
        }

        if (path == "/api/goals" && method == "POST")
            || (test(js_re!(r"^/api/goals/[^/]+$"), path) && (method == "PATCH" || method == "DELETE"))
        {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            return self.goal_writes(request, path, url).await;
        }

        if path == "/api/shares" || path.starts_with("/api/shares/") {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            return self.shares_api(request, path, url).await;
        }

        // Adding and deleting sites, when they are managed in the dashboard.
        if path == "/api/sites" && method == "POST" {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            return Ok(match rl.add_site(&body).await {
                Ok(site) => json(&obj! { "site" => site.to_value() }, 201, &[]),
                Err(Error::Settings(e)) => refused(&e, 400),
                Err(Error::Range(m)) => refused_plain(&m, "site_invalid", 400),
                Err(e) => return Err(e),
            });
        }

        let site_match = crate::re::group(js_re!(r"^/api/sites/([^/]+)$"), path, 1);
        if let Some(raw) = &site_match
            && method == "DELETE"
        {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            let id = crate::sources::decode_uri_component(raw)
                .ok_or_else(|| Error::Other("URIError: URI malformed".into()))?;
            return Ok(match rl.delete_site(&id).await {
                Ok(()) => json(&obj! { "ok" => true }, 200, &[]),
                Err(Error::Settings(e)) if e.message == "Unknown site" => coded(&e.message, "unknown_site", 404, None),
                Err(Error::Settings(e)) => refused(&e, 400),
                Err(e) => return Err(e),
            });
        }
        if let Some(raw) = &site_match
            && method == "PATCH"
        {
            let access = self.can_read(request, call).await;
            if access != CanRead::Yes {
                return Ok(self.denied(access));
            }
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            return self.patch_site(request, raw, &body, url).await;
        }

        if method != "GET" {
            return Ok(coded("Method not allowed", "method_not_allowed", 405, None));
        }

        rl.init().await?;
        // A shared dashboard sees exactly what its visitors see, even for someone signed in.
        let share_id = request.headers.get(SHARE_HEADER);
        let mut shared: Option<ShareRow> = None;
        // The one site a share or a site's API token may read; None for every site.
        let mut only: Option<String> = None;
        if let Some(share_id) = share_id {
            shared = if test(js_re!(r"^[a-f0-9]{32}$"), &share_id) {
                rl.store().share_by_id(&share_id).await?
            } else {
                None
            };
            let Some(share) = &shared else {
                return Ok(coded("This share link no longer works", "share_gone", 404, None));
            };
            if !shared_path(path) {
                return Ok(coded("Not available on a shared dashboard", "share_not_available", 403, None));
            }
            only = Some(share.site.clone());
        } else if let Some(session) = request.headers.get(EMBED_HEADER) {
            let Some(token) = self.embed_reader(&session).await? else {
                return Ok(coded(
                    "This dashboard has expired. Reload the page to open it again.",
                    "embed_expired",
                    401,
                    None,
                ));
            };
            // An embedded dashboard sees what a share link of its token's site shows.
            shared = Some(ShareRow { id: String::new(), site: token.site.clone(), name: String::new(), created_at: 0 });
            only = Some(token.site);
        } else {
            let reader = self.reader(request, call).await?;
            match &reader {
                Reader::No | Reader::Unconfigured => return Ok(self.denied_reader(&reader)),
                Reader::Token(t) => {
                    if !shared_path(path) {
                        return Ok(coded("API tokens can only read", "token_read_only", 403, None));
                    }
                    only = (!t.site.is_empty()).then(|| t.site.clone());
                }
                Reader::Owner => {}
            }
        }

        if path == "/api/sites" {
            return self.sites_list(only.as_deref(), shared.is_some()).await;
        }

        let site = if let Some(share) = &shared {
            rl.site(Some(&share.site))
        } else if let Some(only) = &only {
            rl.site(Some(url.search_params().get("site").unwrap_or(only)))
        } else {
            match self.query_site(url) {
                Ok(s) => Some(s),
                Err(r) => return Ok(r),
            }
        };
        let Some(site) = site.filter(|s| only.as_ref().is_none_or(|o| &s.id == o)) else {
            return Ok(coded("Unknown site", "unknown_site", 404, None));
        };
        if let Some(remote) = rl.remote(&site.id) {
            return self.pass_through(&remote, path, url, Some(request)).await;
        }

        if path == "/api/icon" {
            // Only a site's own domain, never the request's Host header, which a caller can write.
            let icon = match site.hostnames.first() {
                Some(host) => glue::fetch_icon(&rl, &format!("https://{host}")).await,
                None => None,
            };
            let Some((body, kind)) = icon else {
                return Ok(coded_with(
                    "No icon",
                    "icon_none",
                    404,
                    None,
                    &[("cache-control", "private, max-age=3600")],
                ));
            };
            return Ok(Response::new(
                body,
                200,
                Headers::new()
                    .with("content-type", kind)
                    .with("cache-control", "private, max-age=86400")
                    // An SVG served from this origin must never run script.
                    .with("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox")
                    .with("x-content-type-options", "nosniff"),
            ));
        }

        if path == "/api/realtime" {
            return Ok(json(&rl.store().realtime(&site.id, rl.now()).await?, 200, &[]));
        }

        let read = match self.read_query(url, &site).await? {
            Ok(r) => r,
            Err(r) => return Ok(r),
        };
        let query = &read.query;
        let range = &read.range;
        let compared = &read.compared;
        let range_out = obj! { "from" => range.from_date.clone(), "to" => range.to_date.clone(), "interval" => range.interval, "timezone" => site.timezone.clone() };
        let compare_out = compared.as_ref().map(|c| obj! { "from" => c.from_date.clone(), "to" => c.to_date.clone() });
        let before = |c: &crate::time::Range| Query { from: c.from, to: c.to, ..query.clone() };
        let store = rl.store();

        if path == "/api/stats" {
            let stats = store.stats(query).await?;
            let previous = match compared {
                Some(c) => Some(store.stats(&before(c)).await?),
                None => None,
            };
            return Ok(json(
                &with_optional(
                    &site.id,
                    range_out,
                    compare_out,
                    vec![("stats", Some(stats.to_value())), ("previous", previous.map(|p| p.to_value()))],
                ),
                200,
                &[],
            ));
        }

        if path == "/api/goals" {
            let goals = store.goals(Some(&site.id)).await?;
            let visitors = store.visitors(query).await?;
            let previous_visitors = match compared {
                Some(c) => store.visitors(&before(c)).await?,
                None => 0.0,
            };
            // Every goal in one pass for the range, and one more for the comparison.
            let now_all = store.goal_totals_all(query, &goals).await?;
            let before_all = match compared {
                Some(c) => Some(store.goal_totals_all(&before(c), &goals).await?),
                None => None,
            };
            let rows: Vec<Value> = goals
                .iter()
                .map(|goal| {
                    let now = now_all.get(&goal.id).copied().unwrap_or_default();
                    let Value::Object(mut o) = goal.to_value() else { unreachable!() };
                    o.set("conversions", now.conversions);
                    o.set("visitors", now.visitors);
                    o.set("revenue", now.revenue);
                    o.set("rate", if visitors != 0.0 { now.visitors / visitors } else { 0.0 });
                    if let Some(b) = before_all.as_ref().and_then(|m| m.get(&goal.id)) {
                        o.set(
                            "previous",
                            obj! {
                                "conversions" => b.conversions, "visitors" => b.visitors, "revenue" => b.revenue,
                                "rate" => if previous_visitors != 0.0 { b.visitors / previous_visitors } else { 0.0 },
                            },
                        );
                    }
                    Value::Object(o)
                })
                .collect();
            let mut out = with_optional(&site.id, range_out, compare_out, vec![]);
            let o = out.as_object_mut().expect("an object");
            o.set("visitors", visitors);
            o.set("goals", Value::Array(rows));
            return Ok(json(&out, 200, &[]));
        }

        if let Some(goal_id) = crate::re::group(js_re!(r"^/api/goals/([a-f0-9]{24})$"), path, 1) {
            let goal = store.goal_by_id(&goal_id).await?;
            let Some(goal) = goal.filter(|g| g.site == site.id) else {
                return Ok(coded("Unknown goal", "unknown_goal", 404, None));
            };
            let visitors = store.visitors(query).await?;
            let totals = store.goal_totals(query, &goal).await?;
            let series = store.goal_series(&query.site, &query.filters, &goal, &buckets(range, &site.timezone)).await?;
            let by = |rows: Vec<(String, crate::store::GoalTotals)>| {
                Value::Array(
                    rows.into_iter()
                        .map(|(value, t)| obj! { "value" => value, "conversions" => t.conversions, "visitors" => t.visitors, "revenue" => t.revenue })
                        .collect(),
                )
            };
            let sources = by(store.goal_breakdown(query, &goal, "source", 10).await?);
            let channels = by(store.goal_breakdown(query, &goal, "channel", 10).await?);
            let pages = by(store.goal_breakdown(query, &goal, "path", 10).await?);
            return Ok(json(
                &obj! {
                    "site" => site.id.clone(),
                    "range" => range_out,
                    "goal" => goal.to_value(),
                    "totals" => obj! {
                        "conversions" => totals.conversions, "visitors" => totals.visitors, "revenue" => totals.revenue,
                        "rate" => if visitors != 0.0 { totals.visitors / visitors } else { 0.0 },
                    },
                    "series" => Value::Array(series.into_iter().map(|(start, conversions, revenue)| obj! { "start" => start, "conversions" => conversions, "revenue" => revenue }).collect()),
                    "sources" => sources,
                    "channels" => channels,
                    "pages" => pages,
                },
                200,
                &[],
            ));
        }

        if path == "/api/series" {
            let points = store.series(&query.site, &query.filters, &buckets(range, &site.timezone)).await?;
            // Comparison points line up with the main ones by position.
            let previous = match compared {
                Some(c) => {
                    let mut p = store.series(&query.site, &query.filters, &buckets(c, &site.timezone)).await?;
                    p.truncate(points.len());
                    Some(Value::Array(p))
                }
                None => None,
            };
            return Ok(json(
                &with_optional(
                    &site.id,
                    range_out,
                    compare_out,
                    vec![("points", Some(Value::Array(points))), ("previous", previous)],
                ),
                200,
                &[],
            ));
        }

        if path == "/api/rhythm" {
            // Visits per weekday and hour, plus each cell's details for its tooltip.
            let mut grid = [[0.0f64; 24]; 7];
            let mut cells = [[[0.0f64; 4]; 24]; 7];
            for (quarter, visits, visitors, pageviews, bounced) in store.hourly(query).await? {
                let (weekday, h) = local_weekday_hour(quarter * 900_000, &site.timezone);
                let (w, h) = (weekday as usize, h as usize);
                grid[w][h] += visits;
                cells[w][h][0] += visits;
                cells[w][h][1] += visitors;
                cells[w][h][2] += pageviews;
                cells[w][h][3] += bounced;
            }
            let grid: Vec<Value> =
                grid.iter().map(|day| Value::Array(day.iter().map(|n| Value::Number(*n)).collect())).collect();
            let details: Vec<Value> = cells
                .iter()
                .map(|day| {
                    Value::Array(
                        day.iter()
                            .map(|c| obj! { "visits" => c[0], "visitors" => c[1], "pageviews" => c[2], "bounceRate" => if c[0] != 0.0 { c[3] / c[0] } else { 0.0 } })
                            .collect(),
                    )
                })
                .collect();
            return Ok(json(
                &obj! { "site" => site.id.clone(), "range" => range_out, "grid" => Value::Array(grid), "cells" => Value::Array(details) },
                200,
                &[],
            ));
        }

        if path == "/api/journeys" {
            let q = url.search_params();
            let through = js_re!(r"^(\d+):([^\n\r]+)$").captures(q.get("through").unwrap_or("").as_bytes()).map(|c| {
                (js::text_number(&String::from_utf8_lossy(&c[1])), String::from_utf8_lossy(&c[2]).into_owned())
            });
            // Journeys reads the newest visits up to a cap; say when it was reached.
            let (rows, sampled) = store.journey_pages(query, crate::journeys::PAGES_PER_VISIT).await?;
            let options = crate::journeys::JourneyOptions {
                steps: q.get("steps").map_or(5.0, js::text_number),
                start: q.get("start").filter(|s| !s.is_empty()).map(str::to_string),
                end: q.get("end").filter(|s| !s.is_empty()).map(str::to_string),
                through,
            };
            let answer = crate::journeys::journeys(&rows, &options);
            let mut out = obj! { "site" => site.id.clone(), "range" => range_out };
            let o = out.as_object_mut().expect("an object");
            if let Some(a) = answer.as_object() {
                for (k, v) in a.iter() {
                    o.set(k, v.clone());
                }
            }
            if sampled {
                o.set("sampled", crate::store::JOURNEY_VISITS);
            }
            return Ok(json(&out, 200, &[]));
        }

        if path == "/api/funnels" {
            // One funnel at a time, so a page of funnels never takes every database connection at once.
            let mut rows = Vec::new();
            for funnel in store.funnels(&site.id).await? {
                let counts = store.funnel_counts(query, &funnel).await?;
                let steps: Vec<Value> = funnel
                    .steps
                    .iter()
                    .enumerate()
                    .map(|(i, s)| obj! { "kind" => s.kind.clone(), "match" => s.match_.clone(), "visits" => counts.get(i).copied() })
                    .collect();
                let Value::Object(mut o) = funnel.to_value() else { unreachable!() };
                o.set("steps", Value::Array(steps));
                rows.push(Value::Object(o));
            }
            return Ok(json(
                &obj! { "site" => site.id.clone(), "range" => range_out, "funnels" => Value::Array(rows) },
                200,
                &[],
            ));
        }

        if path == "/api/event-props" {
            let params = url.search_params();
            let event = params.get("event").unwrap_or("").to_string();
            if event.is_empty() {
                return Ok(coded("Name the event", "event_needed", 400, None));
            }
            let keys = store.event_prop_keys(query, &event).await?;
            let asked = params.get("key").map(str::to_string);
            // A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
            if asked.as_deref().is_some_and(|a| !(1..=64).contains(&js::len16(a)) || a.contains(['"', '\\'])) {
                return Ok(coded("Bad property name", "property_bad", 400, None));
            }
            let key = asked.or_else(|| keys.first().map(|k| k.0.clone()));
            let limit = clamp_number(params.get("limit"), 100.0);
            let rows = match &key {
                Some(k) if !k.is_empty() => store.event_prop_values(query, &event, k, limit as i64).await?,
                _ => vec![],
            };
            return Ok(json(
                &obj! {
                    "site" => site.id.clone(),
                    "range" => range_out,
                    "event" => event,
                    "keys" => Value::Array(keys.into_iter().map(|(key, events)| obj! { "key" => key, "events" => events }).collect()),
                    "key" => key,
                    "rows" => Value::Array(rows.into_iter().map(|(value, events, visitors)| obj! { "value" => value, "events" => events, "visitors" => visitors }).collect()),
                },
                200,
                &[],
            ));
        }

        if path == "/api/breakdown" {
            let params = url.search_params();
            let dimension = params.get("dimension").unwrap_or("").to_string();
            if !is_dimension(&dimension) {
                return Ok(coded(
                    &format!("Unknown dimension \"{dimension}\""),
                    "unknown_dimension",
                    400,
                    Some(&[("dimension", &dimension)]),
                ));
            }
            let limit = clamp_number(params.get("limit"), 10.0);
            let page = {
                let n = params.get("page").map_or(0.0, js::text_number);
                let n = if n == 0.0 || n.is_nan() { 1.0 } else { n };
                n.max(1.0)
            };
            let rows = store.breakdown(query, &dimension, limit as i64, ((page - 1.0) * limit) as i64).await?;
            if params.get("format") == Some("csv") {
                return Ok(download(
                    &format!("{}-{dimension}-{}-{}.csv", site.id, range.from_date, range.to_date),
                    rows_csv(&rows, &site.timezone, None, Some(&dimension)).into_bytes(),
                    "text/csv; charset=utf-8",
                ));
            }
            return Ok(json(
                &obj! { "site" => site.id.clone(), "range" => range_out, "dimension" => dimension, "rows" => Value::Array(rows) },
                200,
                &[],
            ));
        }

        // Everything the dashboard shows for a view, as a ZIP of CSV files.
        if path == "/api/export" {
            let mut files: Vec<(String, String)> = Vec::new();
            let stats = store.stats(query).await?;
            let previous = match compared {
                Some(c) => Some(store.stats(&before(c)).await?),
                None => None,
            };
            let now = sheet_row(&stats.to_value(), &site.timezone, None, None);
            let was = previous.map(|p| sheet_row(&p.to_value(), &site.timezone, None, None));
            let mut header = vec!["metric", "value"];
            if was.is_some() {
                header.push("previous");
            }
            let rows: Vec<Vec<String>> = now
                .iter()
                .map(|(m, v)| {
                    let mut row = vec![m.to_string(), crate::zip::cell(v)];
                    if let Some(w) = &was {
                        row.push(w.get(m).map_or_else(String::new, crate::zip::cell));
                    }
                    row
                })
                .collect();
            files.push(("overview.csv".into(), crate::zip::csv(&header, &rows)));
            let points = store.series(&query.site, &query.filters, &buckets(range, &site.timezone)).await?;
            files.push(("over-time.csv".into(), rows_csv(&points, &site.timezone, Some(range.interval), None)));
            for dimension in dimensions() {
                let rows = store.breakdown(query, dimension, 1000, 0).await?;
                if !rows.is_empty() {
                    files.push((format!("{dimension}.csv"), rows_csv(&rows, &site.timezone, None, Some(dimension))));
                }
            }
            let goals = store.goals(Some(&site.id)).await?;
            if !goals.is_empty() {
                let totals = store.goal_totals_all(query, &goals).await?;
                let rows: Vec<Vec<String>> = goals
                    .iter()
                    .map(|g| {
                        let t = totals.get(&g.id).copied().unwrap_or_default();
                        vec![
                            g.name.clone(),
                            js::format_number(t.conversions),
                            js::format_number(t.visitors),
                            js::format_number(t.revenue),
                            g.currency.clone(),
                        ]
                    })
                    .collect();
                files.push((
                    "goals.csv".into(),
                    crate::zip::csv(&["goal", "conversions", "visitors", "revenue", "currency"], &rows),
                ));
            }
            return Ok(download(
                &format!("{}-{}-{}.zip", site.id, range.from_date, range.to_date),
                crate::zip::zip(&files, rl.now()),
                "application/zip",
            ));
        }

        Ok(coded("Not found", "not_found", 404, None))
    }

    /// The sites a reader may see, with their last visit and retention.
    async fn sites_list(&self, only: Option<&str>, shared: bool) -> R {
        let rl = self.rl();
        let visible: Vec<crate::store::SiteRow> =
            rl.sites().into_iter().filter(|s| only.is_none_or(|o| s.id == o)).collect();
        let mut sites = Vec::new();
        for site in visible {
            let Value::Object(mut o) = site.to_value() else { unreachable!() };
            let remote = rl.remote(&site.id);
            // A connected install's address, so the dashboard can say where the site is counted.
            if let Some(r) = remote.as_ref().filter(|_| !shared) {
                o.set("remote", r.url.clone());
                o.set("remoteSite", r.site.clone());
                o.set("manage", r.scope.as_deref() == Some("manage"));
                o.set("hostnames", Value::Array(r.hostnames.iter().map(|h| Value::from(h.as_str())).collect()));
            }
            // Hostnames say where the site lives; a share shows only its name.
            if shared {
                o.set("hostnames", Value::Array(vec![]));
            }
            let last_seen: Value = if remote.is_some() {
                rl.remote_last_seen(&site.id).await.into()
            } else {
                rl.store().last_seen(&site.id).await?.into()
            };
            o.set("lastSeen", last_seen);
            // Left out for a connected install that cannot be reached, so nobody reads "forever" by mistake.
            if !shared {
                if remote.is_some() {
                    if let Some(Some(months)) = rl.remote_info(&site.id).await.and_then(|i| i.retention_months) {
                        o.set("retentionMonths", months);
                    } else if let Some(Some(None)) = rl.remote_info(&site.id).await.map(|i| i.retention_months) {
                        o.set("retentionMonths", Value::Null);
                    }
                } else {
                    o.set("retentionMonths", rl.retention(&site.id).await?);
                }
            }
            if remote.is_some()
                && !shared
                && let Some(info) = rl.remote_info(&site.id).await
            {
                o.set("connection", info.connection);
            }
            sites.push(Value::Object(o));
        }
        // A share never learns how the install is run.
        Ok(json(
            &if shared {
                obj! { "sites" => Value::Array(sites) }
            } else {
                obj! { "sites" => Value::Array(sites), "managed" => rl.managed_sites() }
            },
            200,
            &[],
        ))
    }

    /// PATCH /api/sites/:id.
    async fn patch_site(&self, request: &Request, raw: &str, body: &Value, url: &Url) -> R {
        let rl = self.rl();
        rl.init().await?;
        // Every field is checked before any changes, since a shorter retention deletes visits at once.
        if let Some(name) = body.get("name") {
            let n = js::trim(&js::js_string(name)).to_string();
            if n.is_empty() || js::len16(&n) > 80 {
                return Ok(coded("A site name is 1 to 80 characters", "site_name", 400, None));
            }
        }
        if let Some(tz) = body.get("timezone") {
            let tz = js::js_string(tz);
            if !is_timezone(&tz) {
                return Ok(coded(
                    &format!("Unknown timezone \"{tz}\""),
                    "unknown_timezone",
                    400,
                    Some(&[("timezone", &tz)]),
                ));
            }
        }
        let retention = body.get("retentionMonths");
        if let Some(r) = retention
            && !r.is_null()
            && !RETENTION_MONTHS.iter().any(|m| *m as f64 == js::js_number(r))
        {
            return Ok(coded(
                "Keep visits for 6, 12, 24, 36, 60 months, or forever",
                "retention_bad",
                400,
                Some(&[("months", "6, 12, 24, 36, 60")]),
            ));
        }
        let result = async {
            let id = crate::sources::decode_uri_component(raw)
                .ok_or_else(|| Error::Other("URIError: URI malformed".into()))?;
            let remote = rl.remote(&id);
            // How long a connected site keeps visits, and the timezone its days follow, are the install's settings.
            let mut forward = js::Object::new();
            if let Some(r) = retention {
                forward.set("retentionMonths", r.clone());
            }
            if let Some(tz) = body.get("timezone")
                && Some(js::js_string(tz)) != rl.site(Some(&id)).map(|s| s.timezone)
            {
                forward.set("timezone", js::js_string(tz));
            }
            if let Some(remote) = &remote
                && !forward.is_empty()
            {
                if remote.scope.as_deref() != Some("manage") {
                    return Ok(Err(coded(
                        "Connect this site again to change it from here",
                        "connect_again",
                        400,
                        None,
                    )));
                }
                let forwarded = Request::new("PATCH", request.url.clone())
                    .header("content-type", "application/json")
                    .body(forward.to_json());
                let answer = self
                    .pass_through(
                        remote,
                        &format!("/api/sites/{}", crate::sources::encode_uri_component(&remote.site)),
                        url,
                        Some(&forwarded),
                    )
                    .await?;
                if !answer.ok() {
                    return Ok(Err(answer));
                }
                rl.forget_remote_info(&id);
            } else if remote.is_none()
                && let Some(r) = retention
            {
                rl.set_retention(&id, if r.is_null() { None } else { Some(js::js_number(r) as i64) }).await?;
            }
            let mut patch = js::Object::new();
            if let Some(name) = body.get("name") {
                patch.set("name", js::js_string(name));
            }
            if let Some(tz) = body.get("timezone") {
                patch.set("timezone", js::js_string(tz));
            }
            if let Some(h) = body.get("hostnames")
                && rl.managed_sites()
            {
                patch.set("hostnames", h.clone());
            }
            let site = rl.update_site(&id, &Value::Object(patch)).await?;
            // A connected site answers as the list shows it, so the dashboard keeps its install and domains.
            let Value::Object(mut o) = site.to_value() else { unreachable!() };
            if let Some(r) = &remote {
                o.set("remote", r.url.clone());
                o.set("remoteSite", r.site.clone());
                o.set("manage", r.scope.as_deref() == Some("manage"));
                o.set("hostnames", Value::Array(r.hostnames.iter().map(|h| Value::from(h.as_str())).collect()));
            }
            Ok::<Result<Response, Response>, Error>(Ok(json(&obj! { "site" => Value::Object(o) }, 200, &[])))
        }
        .await;
        match result {
            Ok(Ok(r)) | Ok(Err(r)) => Ok(r),
            Err(Error::Settings(e)) if e.message == "Unknown site" => Ok(coded(&e.message, "unknown_site", 404, None)),
            Err(Error::Settings(e)) => Ok(refused(&e, 400)),
            Err(Error::Range(m)) if m == "Unknown site" => Ok(coded(&m, "unknown_site", 404, None)),
            Err(e) => Err(e),
        }
    }

    /// POST /api/observe: pages another site served to AI agents, reported by a CMS plugin or a log reader.
    async fn observe_api(&self, request: &Request, call: &Call) -> R {
        let rl = self.rl();
        let given = bearer(request);
        // The install-wide key and the owner's access can report for any site.
        let any_site =
            self.0.observe_key.as_deref().is_some_and(|k| !given.is_empty() && constant_time_equal(&given, k))
                || self.can_read(request, call).await == CanRead::Yes;
        if !any_site && given.is_empty() {
            return Ok(coded("Unauthorized", "unauthorized", 401, None));
        }
        let body = match read_json(request) {
            Ok(b) => Value::Object(b),
            Err(r) => return Ok(r),
        };
        // One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
        let batch = body.get("fetches").is_some_and(Value::is_array);
        let list: Vec<Value> = match body.get("fetches") {
            Some(Value::Array(a)) => a.clone(),
            _ => vec![body.clone()],
        };
        if list.len() > 500 {
            return Ok(coded("Send at most 500 fetches at a time", "observe_many", 413, None));
        }
        let mut pages: Vec<(Url, String, Option<f64>)> = Vec::new();
        for item in &list {
            if item.is_null() {
                return Ok(coded("Send the page's url", "observe_url", 400, None));
            }
            let Some(page) = Url::parse(&js::str_or_empty(item.get("url"))) else {
                return Ok(coded("Send the page's url", "observe_url", 400, None));
            };
            if page.protocol() != "https:" && page.protocol() != "http:" {
                return Ok(coded("Send the page's url", "observe_url", 400, None));
            }
            let at = match item.get("at") {
                Some(Value::Number(n)) => Some(*n),
                Some(Value::String(s)) => Some(date_parse(s)),
                _ => None,
            }
            .filter(|a| a.is_finite());
            pages.push((page, js::head16(&js::str_or_empty(item.get("userAgent")), 500), at));
        }
        rl.init().await?;
        let mut keep: Vec<&(Url, String, Option<f64>)> = pages.iter().collect();
        if !any_site {
            // A site's own key reports only pages on that site's domains.
            let mut key_site: Option<String> = None;
            for site in rl.sites() {
                if let Some(key) = rl.store().setting(&format!("observe-key:{}", site.id)).await?
                    && !key.is_empty()
                    && constant_time_equal(&given, &key)
                {
                    key_site = Some(site.id);
                }
            }
            let Some(key_site) = key_site else { return Ok(coded("Unauthorized", "unauthorized", 401, None)) };
            keep.retain(|p| rl.site_for(&p.0.hostname(), None).is_some_and(|s| s.id == key_site));
            // A single report for another site's page is a misconfigured plugin, which should hear about it.
            if !batch && keep.is_empty() {
                return Ok(coded("Unauthorized", "unauthorized", 401, None));
            }
        }
        let mut recorded = 0;
        for (page, ua, at) in keep {
            let observed = Request::get(page.href()).header("user-agent", ua);
            if rl.observe(&observed, *at).await {
                recorded += 1;
            }
        }
        // A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
        if !batch {
            return Ok(Response::status(204));
        }
        Ok(json(&obj! { "recorded" => recorded, "skipped" => pages.len() - recorded }, 200, &[]))
    }
}

/// `Math.min(1000, Math.max(1, Number(text) || fallback))`.
fn clamp_number(text: Option<&str>, fallback: f64) -> f64 {
    let n = text.map_or(0.0, js::text_number);
    let n = if n == 0.0 || n.is_nan() { fallback } else { n };
    n.clamp(1.0, 1000.0)
}

/// `{ site, range, compare?, ...rest }` with undefined values left out, as JSON.stringify leaves them.
fn with_optional(site: &str, range: Value, compare: Option<Value>, rest: Vec<(&str, Option<Value>)>) -> Value {
    let mut o = js::Object::new();
    o.set("site", site);
    o.set("range", range);
    if let Some(c) = compare {
        o.set("compare", c);
    }
    for (k, v) in rest {
        if let Some(v) = v {
            o.set(k, v);
        }
    }
    Value::Object(o)
}

/// `Date.parse` for the forms a log reader sends: ISO dates and times, with or without a zone.
pub(crate) fn date_parse(text: &str) -> f64 {
    let t = js::trim(text);
    if let Ok(ts) = t.parse::<jiff::Timestamp>() {
        return ts.as_millisecond() as f64;
    }
    if let Ok(dt) = t.parse::<jiff::civil::DateTime>() {
        // A date and time without a zone is local time in JavaScript; a date alone is UTC.
        let zone = if t.len() <= 10 { jiff::tz::TimeZone::UTC } else { jiff::tz::TimeZone::system() };
        if let Ok(z) = dt.to_zoned(zone) {
            return z.timestamp().as_millisecond() as f64;
        }
    }
    if let Ok(d) = t.parse::<jiff::civil::Date>()
        && let Ok(z) = d.to_zoned(jiff::tz::TimeZone::UTC)
    {
        return z.timestamp().as_millisecond() as f64;
    }
    f64::NAN
}
