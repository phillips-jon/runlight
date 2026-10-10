//! What the store keeps and gives back, in the SDK's shapes. `to_value`
//! writes each as the SDK's object, keys in its order.

use crate::js::{Object, Value};
use crate::obj;

/// A site.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SiteRow {
    /// Stable id, stored with every row.
    pub id: String,
    /// Its name.
    pub name: String,
    /// Hostnames that belong to it, without www.
    pub hostnames: Vec<String>,
    /// IANA timezone for reports.
    pub timezone: String,
}

impl SiteRow {
    /// `{ id, name, hostnames, timezone }`.
    pub fn to_value(&self) -> Value {
        obj! {
            "id" => self.id.clone(),
            "name" => self.name.clone(),
            "hostnames" => Value::Array(self.hostnames.iter().map(|h| Value::from(h.as_str())).collect()),
            "timezone" => self.timezone.clone(),
        }
    }
}

/// What the dashboard may change about a site, kept as the JSON object it
/// was saved as (`{ name?, timezone? }`).
pub type SiteOverrides = Object;

/// Something worth counting.
#[derive(Clone, Debug, PartialEq)]
pub struct GoalRow {
    /// Its id.
    pub id: String,
    /// The site's id.
    pub site: String,
    /// Its name.
    pub name: String,
    /// `event`, `page`, or `click`.
    pub kind: String,
    /// The event name, the path pattern, or for a click goal a CSS selector or URL pattern.
    pub match_: String,
    /// For click goals: `selector` or `link`; else empty.
    pub click_by: String,
    /// `none`, `fixed`, or `prop`.
    pub value_mode: String,
    /// The fixed amount.
    pub value: f64,
    /// The event property holding the amount.
    pub value_prop: String,
    /// The currency.
    pub currency: String,
    /// When it was made.
    pub created_at: i64,
}

impl GoalRow {
    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        obj! {
            "id" => self.id.clone(), "site" => self.site.clone(), "name" => self.name.clone(), "kind" => self.kind.clone(),
            "match" => self.match_.clone(), "clickBy" => self.click_by.clone(), "valueMode" => self.value_mode.clone(),
            "value" => self.value, "valueProp" => self.value_prop.clone(), "currency" => self.currency.clone(),
            "createdAt" => self.created_at,
        }
    }
}

/// Someone who gets a site's report by email. `token` is the unsubscribe key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReportRow {
    /// Its id.
    pub id: String,
    /// The site's id.
    pub site: String,
    /// Where it goes.
    pub email: String,
    /// `weekly` or `monthly`.
    pub frequency: String,
    /// Its language.
    pub lang: String,
    /// The unsubscribe key.
    pub token: String,
    /// Where the dashboard lives, for the links in the email.
    pub origin: String,
    /// The last period sent, like w:2026-09-28 or m:2026-09, so nothing goes out twice.
    pub last_period: String,
    /// When it was last sent.
    pub last_sent_at: Option<i64>,
    /// When it was made.
    pub created_at: i64,
}

impl ReportRow {
    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        obj! {
            "id" => self.id.clone(), "site" => self.site.clone(), "email" => self.email.clone(), "frequency" => self.frequency.clone(),
            "lang" => self.lang.clone(), "token" => self.token.clone(), "origin" => self.origin.clone(),
            "lastPeriod" => self.last_period.clone(), "lastSentAt" => self.last_sent_at, "createdAt" => self.created_at,
        }
    }
}

/// A goal's totals.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GoalTotals {
    /// Rows that converted.
    pub conversions: f64,
    /// Visitors who converted.
    pub visitors: f64,
    /// Money, to the cent.
    pub revenue: f64,
}

/// A public, read-only view of one site's stats, opened by its unguessable id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShareRow {
    /// Its id.
    pub id: String,
    /// The site's id.
    pub site: String,
    /// Its name.
    pub name: String,
    /// When it was made.
    pub created_at: i64,
}

impl ShareRow {
    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        obj! { "id" => self.id.clone(), "site" => self.site.clone(), "name" => self.name.clone(), "createdAt" => self.created_at }
    }
}

/// One step of a funnel: reaching a page (with * as a wildcard), or sending an event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FunnelStep {
    /// `page` or `event`.
    pub kind: String,
    /// The page or event.
    pub match_: String,
}

/// Steps a visit is expected to take in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FunnelRow {
    /// Its id.
    pub id: String,
    /// The site's id.
    pub site: String,
    /// Its name.
    pub name: String,
    /// Its steps.
    pub steps: Vec<FunnelStep>,
    /// When it was made.
    pub created_at: i64,
}

impl FunnelRow {
    /// The steps as stored: `[{ kind, match }]`.
    pub fn steps_value(&self) -> Value {
        Value::Array(
            self.steps.iter().map(|s| obj! { "kind" => s.kind.clone(), "match" => s.match_.clone() }).collect(),
        )
    }

    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        obj! { "id" => self.id.clone(), "site" => self.site.clone(), "name" => self.name.clone(), "steps" => self.steps_value(), "createdAt" => self.created_at }
    }
}

/// An API token. Only its hash is stored; the token itself is shown once.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TokenRow {
    /// Its id.
    pub id: String,
    /// Its name.
    pub name: String,
    /// "" reads every site; otherwise the one site it may read.
    pub site: String,
    /// `read`, `manage`, or `embed` (a CMS plugin's key, which only gets tickets that open its one site's
    /// read-only dashboard inside the CMS).
    pub scope: String,
    /// The token's hash.
    pub hash: String,
    /// The token's last four characters.
    pub hint: String,
    /// When it was made.
    pub created_at: i64,
    /// When it was last used.
    pub last_used_at: Option<i64>,
}

/// A short link.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkRow {
    /// Its id.
    pub id: String,
    /// The site's id.
    pub site: String,
    /// A custom link domain, or "" for the app's own.
    pub domain: String,
    /// Its slug.
    pub slug: String,
    /// Its name.
    pub name: String,
    /// Where it goes.
    pub url: String,
    /// When it was made.
    pub created_at: i64,
    /// When it last changed.
    pub updated_at: i64,
}

impl LinkRow {
    /// The SDK's object.
    pub fn to_object(&self) -> Object {
        let mut o = Object::new();
        o.set("id", self.id.clone());
        o.set("site", self.site.clone());
        o.set("domain", self.domain.clone());
        o.set("slug", self.slug.clone());
        o.set("name", self.name.clone());
        o.set("url", self.url.clone());
        o.set("createdAt", self.created_at);
        o.set("updatedAt", self.updated_at);
        o
    }
}

/// A visit, as recorded from its first request.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionRow {
    /// Its id.
    pub id: String,
    /// The site's id.
    pub site: String,
    /// The day's visitor hash.
    pub visitor: String,
    /// When it began.
    pub started_at: i64,
    /// Its host.
    pub hostname: String,
    /// Where it came from.
    pub referrer_host: String,
    /// The referrer's path.
    pub referrer_path: String,
    /// The source.
    pub source: String,
    /// The channel.
    pub channel: String,
    /// utm_source.
    pub utm_source: String,
    /// utm_medium.
    pub utm_medium: String,
    /// utm_campaign.
    pub utm_campaign: String,
    /// utm_term.
    pub utm_term: String,
    /// utm_content.
    pub utm_content: String,
    /// The country.
    pub country: String,
    /// The region.
    pub region: String,
    /// The city.
    pub city: String,
    /// The browser.
    pub browser: String,
    /// Its version.
    pub browser_version: String,
    /// The system.
    pub os: String,
    /// Its version.
    pub os_version: String,
    /// The device.
    pub device: String,
    /// The screen.
    pub screen: String,
    /// The language.
    pub language: String,
}

/// One recorded row: a pageview, event, engagement ping, link click, or AI agent fetch.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct EventRow {
    /// The site's id.
    pub site: String,
    /// When.
    pub ts: i64,
    /// `pageview`, `event`, `engagement`, `click`, or `fetch`.
    pub kind: String,
    /// The day's visitor hash.
    pub visitor: String,
    /// The visit's id.
    pub session: String,
    /// The pageview's id.
    pub pageview: String,
    /// The path.
    pub path: String,
    /// The host.
    pub hostname: String,
    /// The page's title.
    pub title: String,
    /// The event's name.
    pub name: String,
    /// The event's properties.
    pub props: Option<Object>,
    /// Engaged time.
    pub engaged_ms: i64,
    /// Deepest scroll.
    pub scroll: Option<i64>,
    /// The short link's id.
    pub link: String,
}

/// A range's totals.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Stats {
    /// Visitors.
    pub visitors: f64,
    /// Visits.
    pub visits: f64,
    /// Pageviews.
    pub pageviews: f64,
    /// Pageviews per visit, to two places.
    pub views_per_visit: f64,
    /// 0 to 1.
    pub bounce_rate: f64,
    /// Mean engaged time per visit, milliseconds.
    pub visit_duration: f64,
}

impl Stats {
    /// The SDK's object.
    pub fn to_value(&self) -> Value {
        obj! {
            "visitors" => self.visitors, "visits" => self.visits, "pageviews" => self.pageviews,
            "viewsPerVisit" => self.views_per_visit, "bounceRate" => self.bounce_rate, "visitDuration" => self.visit_duration,
        }
    }

    /// A metric by the SDK's name.
    pub fn get(&self, key: &str) -> f64 {
        match key {
            "visitors" => self.visitors,
            "visits" => self.visits,
            "pageviews" => self.pageviews,
            "viewsPerVisit" => self.views_per_visit,
            "bounceRate" => self.bounce_rate,
            "visitDuration" => self.visit_duration,
            _ => 0.0,
        }
    }
}

/// The pageview an engagement ping or event belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageviewInfo {
    /// The visit's id.
    pub session: String,
    /// The visitor.
    pub visitor: String,
    /// The path.
    pub path: String,
    /// The host.
    pub hostname: String,
    /// When.
    pub ts: i64,
    /// When its visit began.
    pub started_at: i64,
    /// When its visit was last active.
    pub last_at: i64,
}
