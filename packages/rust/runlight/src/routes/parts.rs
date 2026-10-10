//! The parts of the API that live on their own: links and link domains, goals, mail and reports,
//! shares, tokens, the pass-through to a connected install, and reading a view's query.

use super::*;
use crate::error::Error;
use crate::query::{Filter, MAX_FILTERS, Query, is_session_dimension, parse_filter};
use crate::store::{ReportRow, ShareRow, SiteRow};
use crate::time::{Range, RangeInput, compare_range, local_date, local_weekday_hour, resolve_range};

pub(crate) type R = Result<Response, Error>;

/// A view's query: its site, range, and filters, the range itself, and the range it is compared with.
pub(crate) struct Read {
    pub query: Query,
    pub range: Range,
    pub compared: Option<Range>,
}

impl Routes {
    /// The site a request names, or the first.
    pub(crate) fn query_site(&self, url: &Url) -> Result<SiteRow, Response> {
        self.rl().site(url.search_params().get("site")).ok_or_else(|| coded("Unknown site", "unknown_site", 404, None))
    }

    /// The query a view's URL asks for, or the answer refusing it.
    pub(crate) async fn read_query(&self, url: &Url, site: &SiteRow) -> Result<Result<Read, Response>, Error> {
        let params = url.search_params();
        let raw_filters = params.get_all("filter");
        if raw_filters.len() > MAX_FILTERS {
            return Ok(Err(coded(
                &format!("Use at most {MAX_FILTERS} filters at once."),
                "filters_max",
                400,
                Some(&[("max", &MAX_FILTERS.to_string())]),
            )));
        }
        let mut filters: Vec<Filter> = Vec::new();
        for raw in &raw_filters {
            match parse_filter(raw) {
                Some(f) => filters.push(f),
                None => {
                    return Ok(Err(coded(
                        &format!("Bad filter \"{raw}\". Use dimension:is|not|contains:value."),
                        "filter_bad",
                        400,
                        Some(&[("filter", raw)]),
                    )));
                }
            }
        }
        let now = self.rl().now();
        let mut first_date = None;
        if params.get("period") == Some("all")
            && let Some(first) = self.rl().store().first_seen(&site.id).await?
        {
            first_date = Some(local_date(first, &site.timezone));
        }
        let input = RangeInput {
            period: params.get("period").map(str::to_string),
            from: params.get("from").map(str::to_string),
            to: params.get("to").map(str::to_string),
            interval: params.get("interval").map(str::to_string),
        };
        let Some(range) = resolve_range(&input, &site.timezone, now, first_date.as_deref()) else {
            return Ok(Err(coded("Bad date range. Use period, or from and to as YYYY-MM-DD.", "range_bad", 400, None)));
        };
        let query = Query { site: site.id.clone(), from: range.from, to: range.to, filters };
        // compare=false is the older spelling of off.
        let raw = params.get("compare").unwrap_or("previous").to_string();
        let mode = if raw == "false" { "off".to_string() } else { raw.clone() };
        if !["previous", "year", "custom", "off"].contains(&mode.as_str()) {
            return Ok(Err(coded(
                &format!("Bad compare \"{raw}\". Use previous, year, custom, or off."),
                "compare_bad",
                400,
                Some(&[("compare", &raw)]),
            )));
        }
        let compared =
            compare_range(&range, &mode, &site.timezone, params.get("compare_from"), params.get("compare_to"));
        if mode == "custom" && compared.is_none() {
            return Ok(Err(coded(
                "Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.",
                "compare_range_bad",
                400,
                None,
            )));
        }
        Ok(Ok(Read { query, range, compared }))
    }

    pub(crate) fn origin_needed(&self) -> Response {
        coded(
            "Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.",
            "origin_needed",
            400,
            None,
        )
    }

    /// Short links and link domains.
    pub(crate) async fn links_api(&self, request: &Request, path: &str, url: &Url, call: &Call) -> R {
        self.rl().init().await?;
        let site = match self.query_site(url) {
            Ok(s) => s,
            Err(r) => return Ok(r),
        };
        match self.links_inner(request, path, url, call, &site).await {
            Err(Error::Link(e)) => Ok(coded_error(&e, 400)),
            Err(Error::Range(m)) | Err(Error::Settings(CodedError { message: m, .. })) => {
                Ok(coded(&m, "unknown_link", 404, None))
            }
            other => other,
        }
    }

    async fn links_inner(&self, request: &Request, path: &str, url: &Url, call: &Call, site: &SiteRow) -> R {
        let rl = self.rl();
        let store = rl.store();
        let method = request.method.as_str();
        if path == "/api/link-domains" {
            if method == "GET" {
                let domains: Vec<Value> = store
                    .link_domains()
                    .await?
                    .into_iter()
                    .filter(|(_, s)| *s == site.id)
                    .map(|(d, _)| Value::from(d))
                    .collect();
                return Ok(json(&obj! { "domains" => Value::Array(domains) }, 200, &[]));
            }
            if method == "POST" {
                let body = match read_json(request) {
                    Ok(b) => Value::Object(b),
                    Err(r) => return Ok(r),
                };
                let raw = js::trim(&js::str_or_empty(body.get("domain"))).to_lowercase();
                let domain = crate::re::replace_first(js_re!(r"^https?://"), &raw, "");
                let domain = crate::re::replace_first(js_re!(r"/[^\n\r]*$"), &domain, "");
                let domain = domain.trim_end_matches('.').to_string();
                let domain = domain.strip_prefix("www.").map(str::to_string).unwrap_or(domain);
                if !crate::runlight::is_domain(&domain) {
                    return Ok(coded("That is not a domain name", "domain_invalid", 400, None));
                }
                if private_name(&domain) || glue::resolves_privately(rl, &domain).await {
                    return Ok(coded(
                        &format!("{domain} is not a public domain name. Use one that browsers anywhere can reach."),
                        "domain_not_public",
                        400,
                        Some(&[("domain", &domain)]),
                    ));
                }
                // A link domain answers every path on it, so it must never be where the dashboard or a counted site lives.
                if call.is_managed() && self.0.origin.is_none() {
                    return Ok(self.origin_needed());
                }
                let mut own: Vec<String> = Vec::new();
                if let Some(o) = &self.0.origin {
                    own.push(Url::parse(o).map(|u| u.host()).unwrap_or_default());
                }
                for h in [request.headers.get("host"), request.headers.get("x-forwarded-host"), Some(url.host())]
                    .into_iter()
                    .flatten()
                {
                    if !h.is_empty() {
                        own.push(h);
                    }
                }
                own.extend(glue::own_hosts(self).await);
                let mut taken: Vec<String> = own.iter().map(|h| host_name(h)).collect();
                for s in rl.sites() {
                    taken.extend(s.hostnames.clone());
                    if let Some(r) = rl.remote(&s.id) {
                        taken.extend(r.hostnames);
                    }
                }
                if taken.contains(&domain) {
                    return Ok(coded(
                        &format!(
                            "{domain} is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go.{domain}."
                        ),
                        "domain_in_use",
                        400,
                        Some(&[("domain", &domain)]),
                    ));
                }
                if let Some((_, owner)) = store.link_domains().await?.into_iter().find(|(d, _)| *d == domain)
                    && owner != site.id
                {
                    return Ok(coded(
                        &format!("{domain} already belongs to another site"),
                        "domain_taken",
                        409,
                        Some(&[("domain", &domain)]),
                    ));
                }
                store.add_link_domain(&domain, &site.id, rl.now()).await?;
                rl.forget_link_domains();
                return Ok(json(&obj! { "domain" => domain }, 201, &[]));
            }
        }
        if let Some(raw) = crate::re::group(js_re!(r"^/api/link-domains/([^/]+)/check$"), path, 1)
            && method == "GET"
        {
            let domain = crate::sources::decode_uri_component(&raw)
                .ok_or_else(|| Error::Other("URIError: URI malformed".into()))?;
            if !store.link_domains().await?.iter().any(|(d, s)| *d == domain && *s == site.id) {
                return Ok(coded("Unknown domain", "unknown_domain", 404, None));
            }
            let own = match &self.0.origin {
                Some(o) => Url::parse(o).map(|u| u.hostname()).unwrap_or_default(),
                None => url.hostname(),
            };
            let addresses = glue::public_addresses(rl, &own).await;
            let target = obj! { "host" => own.clone(), "addresses" => Value::Array(addresses.into_iter().map(Value::from).collect()) };
            let result = |code: &str, reason: &str, params: Option<(&str, &str)>| {
                let mut o = js::Object::new();
                o.set("domain", domain.clone());
                o.set("working", code.is_empty());
                o.set("reason", reason);
                o.set("target", target.clone());
                if !code.is_empty() {
                    o.set("code", code);
                    if let Some((k, v)) = params {
                        o.set("params", obj! { k => v });
                    }
                }
                json(&Value::Object(o), 200, &[])
            };
            if !crate::runlight::is_domain(&domain) || private_name(&domain) {
                return Ok(result("check_not_public", "is not a public domain name", None));
            }
            return Ok(
                match glue::public_fetch(rl, &format!("https://{domain}{}", crate::runlight::LINK_DOMAIN_CHECK), 5000)
                    .await
                {
                    Ok(answer) => {
                        let body = answer.json_body().ok();
                        let ok = body.as_ref().is_some_and(|b| {
                            b.get("runlight") == Some(&Value::Bool(true))
                                && b.get("domain").and_then(Value::as_str) == Some(domain.as_str())
                        });
                        if answer.ok() && ok {
                            result("", "", None)
                        } else if answer.ok() {
                            result("check_not_runlight", "answered, but not from Runlight", None)
                        } else {
                            let status = answer.status.to_string();
                            result("check_status", &format!("answered {status}"), Some(("status", &status)))
                        }
                    }
                    Err(timed_out) => {
                        if timed_out {
                            result("check_timeout", "timed out", None)
                        } else {
                            result("check_https", "could not connect over HTTPS", None)
                        }
                    }
                },
            );
        }
        if let Some(raw) = crate::re::group(js_re!(r"^/api/link-domains/([^/]+)$"), path, 1)
            && method == "DELETE"
        {
            let domain = crate::sources::decode_uri_component(&raw)
                .ok_or_else(|| Error::Other("URIError: URI malformed".into()))?;
            if !store.link_domains().await?.iter().any(|(d, s)| *d == domain && *s == site.id) {
                return Ok(coded("Unknown domain", "unknown_domain", 404, None));
            }
            store.remove_link_domain(&domain).await?;
            rl.forget_link_domains();
            return Ok(json(&obj! { "ok" => true }, 200, &[]));
        }
        if path == "/api/links" {
            if method == "GET" {
                let read = match self.read_query(url, site).await? {
                    Ok(r) => r,
                    Err(r) => return Ok(r),
                };
                let links: Vec<Value> = store
                    .links(&site.id, read.range.from, read.range.to)
                    .await?
                    .into_iter()
                    .map(|(link, clicks, visitors)| {
                        let mut o = link.to_object();
                        o.set("clicks", clicks);
                        o.set("visitors", visitors);
                        Value::Object(o)
                    })
                    .collect();
                // Links on a removed domain are served from the app's own path until it is added back.
                let domains: Vec<Value> = store
                    .link_domains()
                    .await?
                    .into_iter()
                    .filter(|(_, s)| *s == site.id)
                    .map(|(d, _)| Value::from(d))
                    .collect();
                return Ok(json(
                    &obj! { "prefix" => format!("{}{}", url.origin(), rl.link_path()), "domains" => Value::Array(domains), "links" => Value::Array(links) },
                    200,
                    &[],
                ));
            }
            if method == "POST" {
                let body = match read_json(request) {
                    Ok(b) => Value::Object(b),
                    Err(r) => return Ok(r),
                };
                let opt = |k: &str| body.get(k).map(js::js_string);
                let link = rl
                    .links()
                    .create(
                        &site.id,
                        &crate::links::LinkInput {
                            url: js::str_or_empty(body.get("url")),
                            name: opt("name"),
                            slug: opt("slug"),
                            domain: opt("domain"),
                        },
                    )
                    .await?;
                return Ok(json(&obj! { "link" => Value::Object(link.to_object()) }, 201, &[]));
            }
        }
        // One step of an import from another shortener; the page calls again with the cursor.
        if let Some(source) = crate::re::group(js_re!(r"^/api/links/import/([a-z]+)$"), path, 1)
            && method == "POST"
        {
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            return glue::import_step(self, &site.id, &source, &body).await;
        }
        if path == "/api/links/import" && method == "POST" {
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            // Rows that are not objects (null, a number) are dropped rather than failing the import.
            let Some(Value::Array(rows)) = body.get("rows") else {
                return Ok(coded("Send rows as a list", "rows_needed", 400, None));
            };
            let rows: Vec<Value> = rows.iter().filter(|r| r.is_object()).take(5000).cloned().collect();
            return Ok(json(&rl.links().import(&site.id, &rows).await?, 200, &[]));
        }
        if let Some(id) = crate::re::group(js_re!(r"^/api/links/([a-f0-9]+)$"), path, 1) {
            if method == "GET" {
                let link = store.link_by_id(&id).await?;
                let Some(link) = link.filter(|l| l.site == site.id) else {
                    return Ok(coded("Unknown link", "unknown_link", 404, None));
                };
                let read = match self.read_query(url, site).await? {
                    Ok(r) => r,
                    Err(r) => return Ok(r),
                };
                let range = &read.range;
                let series = store.link_series(&site.id, &id, &crate::time::buckets(range, &site.timezone)).await?;
                let mut by = Vec::new();
                for dimension in ["source", "referrer", "country", "device", "browser"] {
                    by.push(if is_session_dimension(dimension) {
                        store.link_breakdown(&site.id, &id, range.from, range.to, dimension, 10).await?
                    } else {
                        vec![]
                    });
                }
                let clicks: f64 = series.iter().map(|p| p.1).sum();
                let series: Vec<Value> = series.into_iter().map(|(start, clicks, visitors)| obj! { "start" => start, "clicks" => clicks, "visitors" => visitors }).collect();
                let mut by = by.into_iter().map(Value::Array);
                return Ok(json(
                    &obj! {
                        "link" => Value::Object(link.to_object()),
                        "range" => obj! { "from" => range.from_date.clone(), "to" => range.to_date.clone(), "interval" => range.interval, "timezone" => site.timezone.clone() },
                        "clicks" => clicks,
                        "series" => Value::Array(series),
                        "sources" => by.next().unwrap_or_default(),
                        "referrers" => by.next().unwrap_or_default(),
                        "countries" => by.next().unwrap_or_default(),
                        "devices" => by.next().unwrap_or_default(),
                        "browsers" => by.next().unwrap_or_default(),
                    },
                    200,
                    &[],
                ));
            }
            let owned = store.link_by_id(&id).await?;
            if owned.is_none_or(|l| l.site != site.id) {
                return Ok(coded("Unknown link", "unknown_link", 404, None));
            }
            if method == "PATCH" {
                let body = match read_json(request) {
                    Ok(b) => Value::Object(b),
                    Err(r) => return Ok(r),
                };
                let pick = |k: &str| body.get(k).map(js::js_string);
                let input = crate::links::LinkPatch {
                    url: pick("url"),
                    name: pick("name"),
                    slug: pick("slug"),
                    domain: pick("domain"),
                };
                let link = rl.links().update(&id, &input).await?;
                return Ok(json(&obj! { "link" => Value::Object(link.to_object()) }, 200, &[]));
            }
            if method == "DELETE" {
                rl.links().remove(&id).await?;
                return Ok(json(&obj! { "ok" => true }, 200, &[]));
            }
        }
        Ok(coded("Not found", "not_found", 404, None))
    }

    /// Making, changing, and deleting goals.
    pub(crate) async fn goal_writes(&self, request: &Request, path: &str, url: &Url) -> R {
        let rl = self.rl();
        rl.init().await?;
        let site = match self.query_site(url) {
            Ok(s) => s,
            Err(r) => return Ok(r),
        };
        let existing = rl.store().goals(Some(&site.id)).await?;
        let id = if path == "/api/goals" {
            None
        } else {
            Some(
                crate::sources::decode_uri_component(&path["/api/goals/".len()..])
                    .ok_or_else(|| Error::Other("URIError: URI malformed".into()))?,
            )
        };
        if let Some(id) = &id
            && !existing.iter().any(|g| &g.id == id)
        {
            return Ok(coded("Unknown goal", "unknown_goal", 404, None));
        }
        self.forget_trackers();
        if request.method == "DELETE" {
            rl.store().delete_goal(id.as_deref().unwrap_or("")).await?;
            return Ok(json(&obj! { "ok" => true }, 200, &[]));
        }
        let body = match read_json(request) {
            Ok(b) => Value::Object(b),
            Err(r) => return Ok(r),
        };
        match crate::goals::goal_from(&body, &site.id, &existing, rl.now(), id.as_deref()) {
            Ok(goal) => {
                rl.store().save_goal(&goal, existing.iter().find(|g| Some(&g.id) == id.as_ref())).await?;
                Ok(json(&obj! { "goal" => goal.to_value() }, if id.is_some() { 200 } else { 201 }, &[]))
            }
            Err(e) => Ok(refused(&e, 400)),
        }
    }

    pub(crate) fn report_view(r: &ReportRow) -> Value {
        obj! {
            "id" => r.id.clone(), "site" => r.site.clone(), "email" => r.email.clone(), "frequency" => r.frequency.clone(),
            "lang" => r.lang.clone(), "lastSentAt" => r.last_sent_at, "createdAt" => r.created_at,
        }
    }

    /// The mail service, and the email reports.
    pub(crate) async fn mail_api(&self, request: &Request, path: &str, url: &Url, call: &Call) -> R {
        self.rl().init().await?;
        match self.mail_inner(request, path, url, call).await {
            Err(Error::Mail(e)) => Ok(coded_error(&e, 400)),
            other => other,
        }
    }

    async fn mail_inner(&self, request: &Request, path: &str, url: &Url, call: &Call) -> R {
        let rl = self.rl();
        let method = request.method.as_str();
        if path == "/api/mail" {
            return match method {
                "GET" => Ok(json(&glue::mail_view(rl, call.is_managed()).await?, 200, &[])),
                "PUT" => {
                    let body = match read_json(request) {
                        Ok(b) => Value::Object(b),
                        Err(r) => return Ok(r),
                    };
                    glue::save_mail_settings(rl, Some(&body)).await?;
                    Ok(json(&obj! { "ok" => true }, 200, &[]))
                }
                "DELETE" => {
                    glue::save_mail_settings(rl, None).await?;
                    Ok(json(&obj! { "ok" => true }, 200, &[]))
                }
                _ => Ok(coded("Method not allowed", "method_not_allowed", 405, None)),
            };
        }
        if path == "/api/mail/test" && method == "POST" {
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            let to = js::trim(&js::str_or_empty(body.get("to"))).to_string();
            if !crate::runlight::is_email(&to) {
                return Ok(coded("Enter an email address to send the test to", "test_email", 400, None));
            }
            let lang = body.get("lang").filter(|v| !v.is_null()).map_or_else(|| "en".to_string(), js::js_string);
            return glue::send_test_mail(rl, &to, &lang).await;
        }
        let site = match self.query_site(url) {
            Ok(s) => s,
            Err(r) => return Ok(r),
        };
        let store = rl.store();
        if path == "/api/reports" {
            if method == "GET" {
                let reports: Vec<Value> = store.reports(Some(&site.id)).await?.iter().map(Self::report_view).collect();
                let languages: Vec<Value> = glue::languages().into_iter().map(Value::from).collect();
                return Ok(json(
                    &obj! { "reports" => Value::Array(reports), "languages" => Value::Array(languages) },
                    200,
                    &[],
                ));
            }
            if method == "POST" {
                let body = match read_json(request) {
                    Ok(b) => Value::Object(b),
                    Err(r) => return Ok(r),
                };
                let email = js::trim(&js::str_or_empty(body.get("email"))).to_lowercase();
                if !crate::runlight::is_email(&email) {
                    return Ok(coded("Enter an email address", "email_invalid", 400, None));
                }
                let frequency =
                    if body.get("frequency").and_then(Value::as_str) == Some("monthly") { "monthly" } else { "weekly" };
                let existing = store.reports(Some(&site.id)).await?;
                if existing.iter().any(|r| r.email == email && r.frequency == frequency) {
                    return Ok(coded(
                        &format!("{email} already gets the {frequency} report"),
                        "report_exists",
                        400,
                        Some(&[("email", &email)]),
                    ));
                }
                if existing.len() >= 50 {
                    return Ok(coded("A site can send to at most 50 addresses", "report_limit", 400, None));
                }
                if call.is_managed() && self.0.origin.is_none() {
                    return Ok(self.origin_needed());
                }
                let given = if self.0.origin.is_some() { String::new() } else { js::str_or_empty(body.get("origin")) };
                let home = if test(js_re!(r"^https?://[^\s]+$"), &given) && !given.chars().any(js::is_space) {
                    given.trim_end_matches('/').to_string()
                } else {
                    format!("{}{}", self.0.origin.clone().unwrap_or_else(|| url.origin()), self.0.base)
                };
                // A period already due counts as sent, so a report added mid-week first goes out on the next Monday.
                let (due_key, due_at) = glue::last_period(frequency, rl.now(), &site.timezone);
                let lang = body.get("lang").map_or_else(|| "undefined".to_string(), js::js_string);
                let report = ReportRow {
                    id: random_id(12),
                    site: site.id.clone(),
                    email,
                    frequency: frequency.into(),
                    lang: if glue::languages().contains(&lang) { lang } else { "en".into() },
                    token: random_id(16),
                    origin: home,
                    last_period: if rl.now() >= due_at { due_key } else { String::new() },
                    last_sent_at: None,
                    created_at: rl.now(),
                };
                store.insert_report(&report).await?;
                return Ok(json(&obj! { "report" => Self::report_view(&report) }, 201, &[]));
            }
            return Ok(coded("Method not allowed", "method_not_allowed", 405, None));
        }
        let caps = js_re!(r"^/api/reports/([a-f0-9]{24})(/send)?$").captures(path.as_bytes());
        let (id, send) = match &caps {
            Some(c) => (String::from_utf8_lossy(&c[1]).into_owned(), c.get(2).is_some()),
            None => (String::new(), false),
        };
        let report = if caps.is_some() { store.report_by(false, &id).await? } else { None };
        let Some(report) = report.filter(|r| r.site == site.id) else {
            return Ok(coded("Unknown report", "unknown_report", 404, None));
        };
        if send && method == "POST" {
            // A sample at most once a minute per report, so the send button cannot be used to flood an inbox.
            let managed = call.is_managed();
            let key = if managed { format!("site:{}", site.id) } else { report.id.clone() };
            let wait = if managed { 600_000 } else { 60_000 };
            {
                let mut sent = self.0.sample_sent.lock().unwrap_or_else(|e| e.into_inner());
                let last = sent.get(&key).copied().unwrap_or(0);
                if rl.now() - last < wait {
                    return Ok(if managed {
                        coded(
                            "A connected hub can send one sample every ten minutes. Wait a few minutes and try again.",
                            "sample_soon_hub",
                            429,
                            None,
                        )
                    } else {
                        coded("A sample went out a moment ago. Wait a minute and try again.", "sample_soon", 429, None)
                    });
                }
                sent.insert(key, rl.now());
            }
            glue::deliver_report(rl, &report, &site).await?;
            return Ok(json(&obj! { "ok" => true }, 200, &[]));
        }
        if !send && method == "DELETE" {
            store.delete_report(&report.id).await?;
            return Ok(json(&obj! { "ok" => true }, 200, &[]));
        }
        Ok(coded("Method not allowed", "method_not_allowed", 405, None))
    }

    /// A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing.
    pub(crate) async fn unsubscribe_page(&self, request: &Request, token: &str) -> R {
        let rl = self.rl();
        rl.init().await?;
        let report =
            if test(js_re!(r"^[a-f0-9]{32}$"), token) { rl.store().report_by(true, token).await? } else { None };
        let site = report.as_ref().and_then(|r| rl.site(Some(&r.site)));
        let (t, lang) = glue::translator(report.as_ref().map_or("en", |r| r.lang.as_str()));
        let (Some(report), Some(site)) = (report, site) else {
            return Ok(small_page(
                &lang,
                &format!(
                    "<h1>{}</h1><p>{}</p>",
                    escape_html(&t("email.unsub.goneTitle", &[])),
                    escape_html(&t("email.unsub.gone", &[]))
                ),
                404,
            ));
        };
        if request.method == "POST" {
            rl.store().delete_report(&report.id).await?;
            return Ok(small_page(
                &lang,
                &format!(
                    "<h1>{}</h1><p>{}</p>",
                    escape_html(&t("email.unsub.doneTitle", &[])),
                    escape_html(&t("email.unsub.done", &[("site", &site.name), ("email", &report.email)]))
                ),
                200,
            ));
        }
        Ok(small_page(
            &lang,
            &format!(
                "<h1>{}</h1><p>{}</p><form method=\"post\"><button type=\"submit\">{}</button></form>",
                escape_html(&t("email.unsub.title", &[("site", &site.name)])),
                escape_html(&t("email.unsub.body", &[("email", &report.email)])),
                escape_html(&t("email.unsubscribe", &[]))
            ),
            200,
        ))
    }

    /// Share links.
    pub(crate) async fn shares_api(&self, request: &Request, path: &str, url: &Url) -> R {
        let rl = self.rl();
        rl.init().await?;
        let site = match self.query_site(url) {
            Ok(s) => s,
            Err(r) => return Ok(r),
        };
        let base = self.0.base.clone();
        let view = |share: &ShareRow| {
            let Value::Object(mut o) = share.to_value() else { unreachable!() };
            o.set("path", format!("{base}/share/{}", share.id));
            Value::Object(o)
        };
        let method = request.method.as_str();
        if path == "/api/shares" {
            if method == "GET" {
                let shares: Vec<Value> = rl.store().shares(&site.id).await?.iter().map(view).collect();
                return Ok(json(&obj! { "shares" => Value::Array(shares) }, 200, &[]));
            }
            if method == "POST" {
                let body = match read_json(request) {
                    Ok(b) => Value::Object(b),
                    Err(r) => return Ok(r),
                };
                let share = ShareRow {
                    id: random_id(16),
                    site: site.id.clone(),
                    name: js::head16(js::trim(&js::str_or_empty(body.get("name"))), 100),
                    created_at: rl.now(),
                };
                rl.store().insert_share(&share).await?;
                return Ok(json(&obj! { "share" => view(&share) }, 201, &[]));
            }
            return Ok(coded("Method not allowed", "method_not_allowed", 405, None));
        }
        let id = crate::sources::decode_uri_component(&path["/api/shares/".len()..])
            .ok_or_else(|| Error::Other("URIError: URI malformed".into()))?;
        let share = if test(js_re!(r"^[a-f0-9]{32}$"), &id) { rl.store().share_by_id(&id).await? } else { None };
        let Some(share) = share.filter(|s| s.site == site.id) else {
            return Ok(coded("Unknown share", "unknown_share", 404, None));
        };
        if method == "PATCH" {
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            let name = js::head16(js::trim(&js::str_or_empty(body.get("name"))), 100);
            rl.store().rename_share(&share.id, &name).await?;
            return Ok(json(&obj! { "share" => view(&ShareRow { name, ..share }) }, 200, &[]));
        }
        if method == "DELETE" {
            rl.store().delete_share(&share.id).await?;
            return Ok(json(&obj! { "ok" => true }, 200, &[]));
        }
        Ok(coded("Method not allowed", "method_not_allowed", 405, None))
    }

    /// API tokens: only the owner makes and revokes them.
    pub(crate) async fn tokens_api(&self, request: &Request, path: &str) -> R {
        let rl = self.rl();
        rl.init().await?;
        let view = |t: &TokenRow| {
            obj! {
                "id" => t.id.clone(), "name" => t.name.clone(), "site" => t.site.clone(), "scope" => t.scope.clone(),
                "hint" => t.hint.clone(), "createdAt" => t.created_at, "lastUsedAt" => t.last_used_at,
            }
        };
        let method = request.method.as_str();
        if path == "/api/tokens" && method == "GET" {
            let tokens: Vec<Value> = rl.store().tokens().await?.iter().map(view).collect();
            return Ok(json(&obj! { "tokens" => Value::Array(tokens) }, 200, &[]));
        }
        if path == "/api/tokens" && method == "POST" {
            let body = match read_json(request) {
                Ok(b) => Value::Object(b),
                Err(r) => return Ok(r),
            };
            let name = js::head16(js::trim(&js::str_or_empty(body.get("name"))), 100);
            if name.is_empty() {
                return Ok(coded("Name the token", "token_name", 400, None));
            }
            let site = js::str_or_empty(body.get("site"));
            if !site.is_empty() && !rl.sites().iter().any(|s| s.id == site) {
                return Ok(coded("Unknown site", "unknown_site", 404, None));
            }
            let scope = match body.get("scope").and_then(Value::as_str) {
                Some("manage") => "manage",
                Some("embed") => "embed",
                _ => "read",
            };
            if scope == "manage" && site.is_empty() {
                return Ok(coded(
                    "A token that changes settings is for one site. Pick the site.",
                    "token_site",
                    400,
                    None,
                ));
            }
            if scope == "embed" && site.is_empty() {
                return Ok(coded(
                    "A key for the dashboard in a CMS is for one site. Pick the site.",
                    "embed_site",
                    400,
                    None,
                ));
            }
            let secret = format!("{TOKEN_PREFIX}{}", random_id(20));
            let row = TokenRow {
                id: random_id(12),
                name,
                site,
                scope: scope.into(),
                hash: sha256(&secret),
                hint: js::slice16(&secret, -4, i64::MAX),
                created_at: rl.now(),
                last_used_at: None,
            };
            rl.store().insert_token(&row).await?;
            if !glue::token_made(self, request, &row).await? {
                rl.store().delete_token(&row.id).await?;
                return Ok(self.denied(CanRead::Read));
            }
            // The only time the token is ever shown.
            return Ok(json(&obj! { "token" => view(&row), "secret" => secret }, 201, &[]));
        }
        if let Some(id) = crate::re::group(js_re!(r"^/api/tokens/([a-f0-9]{24})$"), path, 1)
            && method == "DELETE"
        {
            return Ok(if rl.store().delete_token(&id).await? {
                json(&obj! { "ok" => true }, 200, &[])
            } else {
                coded("Unknown token", "unknown_token", 404, None)
            });
        }
        Ok(coded("Not found", "not_found", 404, None))
    }

    /// Answers a read for a site counted by another install by asking that install, with its token and
    /// its own id for the site, and handing back what it says.
    pub(crate) async fn pass_through(
        &self,
        remote: &crate::runlight::Remote,
        path: &str,
        url: &Url,
        request: Option<&Request>,
    ) -> R {
        let Some(mut target) = Url::parse(&format!("{}{path}", remote.url)) else {
            return Err(Error::Other("TypeError: Invalid URL".into()));
        };
        let mut params = target.search_params();
        for (k, v) in url.search_params().pairs() {
            params.append(k, v);
        }
        params.set("site", &remote.site);
        target.set_search_params(&params);
        // A change made from the hub goes on to the install with its JSON body; reads carry none.
        let write = request.is_some_and(|r| r.method != "GET" && r.method != "HEAD");
        let mut init =
            crate::http::FetchInit::method(if write { request.map_or("GET", |r| r.method.as_str()) } else { "GET" })
                .header("authorization", format!("Bearer {}", remote.token))
                .timeout(if write { 30_000 } else { 120_000 });
        init.manual_redirect = true;
        if write && let Some(r) = request {
            if let Some(ct) = r.headers.get("content-type").filter(|c| !c.is_empty()) {
                init.headers.set("content-type", &ct);
            }
            init.body = Some(r.body.clone());
        }
        let host = Url::parse(&remote.url).map(|u| u.host()).unwrap_or_default();
        let answer = match self.rl().fetch_install(&target.href(), init).await {
            Ok(a) => a,
            Err(crate::http::FetchError::TimedOut) => {
                return Ok(coded(
                    &format!("{host} took too long to answer. Try a shorter range."),
                    "remote_slow",
                    504,
                    Some(&[("host", &host)]),
                ));
            }
            Err(_) => {
                return Ok(coded(&format!("Could not reach {host}"), "unreachable", 502, Some(&[("host", &host)])));
            }
        };
        // What comes back is shown from this server's origin, so it is never taken as a page.
        let download =
            path == "/api/export" || (path == "/api/breakdown" && url.search_params().get("format") == Some("csv"));
        let content_type = if download {
            if answer.headers.get("content-type").unwrap_or_default().starts_with("text/csv") {
                "text/csv; charset=utf-8"
            } else {
                "application/zip"
            }
        } else {
            "application/json; charset=utf-8"
        };
        let mut back = Headers::new()
            .with("cache-control", "private, no-store")
            .with("x-content-type-options", "nosniff")
            .with("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
            .with("content-type", content_type);
        if download {
            let name = crate::re::group(
                js_re!(r#"filename="([A-Za-z0-9._-]+)""#),
                &answer.headers.get("content-disposition").unwrap_or_default(),
                1,
            )
            .unwrap_or_else(|| "runlight-export".into());
            back.set("content-disposition", &format!("attachment; filename=\"{name}\""));
        }
        if (300..400).contains(&answer.status) {
            return Ok(coded(&format!("{host} answered with a redirect"), "redirected", 502, Some(&[("host", &host)])));
        }
        // The install's own errors say what went wrong there; a refused token is this server's problem to report.
        if answer.status == 401 {
            return Ok(coded(
                &format!("{host} refused the token. Connect it again from the site's settings."),
                "token_refused",
                502,
                Some(&[("host", &host)]),
            ));
        }
        if answer.status >= 400 && !download {
            let text = answer.text();
            let body = if js::len16(&text) <= 65_536 { js::parse(&text).ok() } else { None };
            let mut o = js::Object::new();
            let error = match body.as_ref().and_then(|b| b.get("error")) {
                Some(Value::String(e)) => js::head16(e, 300),
                _ => format!("answered {}", answer.status),
            };
            o.set("error", format!("{host}: {error}"));
            if let Some(Value::String(code)) = body.as_ref().and_then(|b| b.get("code"))
                && test(js_re!(r"^[a-z_]{1,40}$"), code)
            {
                o.set("code", code.clone());
                let mut params = js::Object::new();
                if let Some(Value::Object(p)) = body.as_ref().and_then(|b| b.get("params")) {
                    for (k, v) in p.iter().filter(|(_, v)| v.is_string()).take(10) {
                        params.set(js::head16(k, 40), js::head16(v.as_str().unwrap_or(""), 200));
                    }
                }
                o.set("params", params);
            }
            let mut response = json(&Value::Object(o), answer.status, &[]);
            for (k, v) in back.entries() {
                response.headers.set(&k, &v);
            }
            return Ok(response);
        }
        Ok(Response::new(answer.body, answer.status, back))
    }
}

/// Rows of objects as CSV, with a column for every key the first row has, in the units a spreadsheet reads.
pub(crate) fn rows_csv(rows: &[Value], timezone: &str, interval: Option<&str>, dimension: Option<&str>) -> String {
    let readable: Vec<js::Object> = rows.iter().map(|r| sheet_row(r, timezone, interval, dimension)).collect();
    let header: Vec<String> =
        readable.first().map_or_else(|| vec!["value".to_string()], |r| r.keys().map(str::to_string).collect());
    let header_refs: Vec<&str> = header.iter().map(String::as_str).collect();
    let body: Vec<Vec<String>> = readable
        .iter()
        .map(|r| header.iter().map(|k| r.get(k).map_or_else(String::new, crate::zip::cell)).collect())
        .collect();
    crate::zip::csv(&header_refs, &body)
}

/// One row for a spreadsheet: a bucket's start as the site's local date (and hour), rates as percents,
/// durations in seconds, and paths as people write them.
pub(crate) fn sheet_row(row: &Value, timezone: &str, interval: Option<&str>, dimension: Option<&str>) -> js::Object {
    let mut out = js::Object::new();
    let Some(o) = row.as_object() else { return out };
    for (key, value) in o.iter() {
        match (key, value) {
            ("start", Value::Number(n)) => {
                let ts = *n as i64;
                let hour = if interval == Some("hour") {
                    format!(" {:02}:00", local_weekday_hour(ts, timezone).1)
                } else {
                    String::new()
                };
                out.set("date", format!("{}{hour}", local_date(ts, timezone)));
            }
            ("bounceRate", Value::Number(n)) => out.set("bounceRatePercent", js::round(n * 1000.0) / 10.0),
            ("visitDuration" | "timeOnPage", Value::Number(n)) => {
                out.set(format!("{key}Seconds"), js::round(n / 1000.0))
            }
            ("value", Value::String(s))
                if dimension.is_some_and(|d| ["page", "entry", "exit", "ai_page"].contains(&d)) =>
            {
                out.set("value", crate::sources::readable_path(s))
            }
            _ => out.set(key, value.clone()),
        }
    }
    out
}
