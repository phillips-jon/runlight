//! Short links: create, change, delete, and import, with the rules every route shares.

use crate::error::Error;
use crate::goals::CodedError;
use crate::hash::{new_id, random_bytes};
use crate::http::Url;
use crate::js::{self, Object, Value};
use crate::re::{js_re, test};
use crate::runlight::Runlight;
use crate::sources::strip_www;
use crate::store::LinkRow;

/// What a person or an import may set on a new link.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LinkInput {
    /// Where it goes.
    pub url: String,
    /// Its name.
    pub name: Option<String>,
    /// Its slug.
    pub slug: Option<String>,
    /// A link domain added in Settings, or "" (the default) for the app's own.
    pub domain: Option<String>,
}

/// What may change on a link: each field left `None` stays.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LinkPatch {
    /// Where it goes.
    pub url: Option<String>,
    /// Its name.
    pub name: Option<String>,
    /// Its slug.
    pub slug: Option<String>,
    /// Its domain.
    pub domain: Option<String>,
}

const ALPHABET: &[u8] = b"abcdefghijkmnpqrstuvwxyz23456789";

/// Six characters from an alphabet without look-alikes (no 0/o, 1/l).
pub fn random_slug() -> String {
    random_bytes(6).iter().map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char).collect()
}

fn link_error(message: impl Into<String>, code: &str, params: &[(&str, &str)]) -> Error {
    Error::Link(CodedError::new(message, code, params))
}

fn clean_url(value: &str) -> Result<String, Error> {
    let text = js::trim(value).to_string();
    let Some(url) = Url::parse(&text) else {
        return Err(link_error("The destination must be a full URL, starting with https://", "link_url", &[]));
    };
    if url.protocol() != "https:" && url.protocol() != "http:" {
        return Err(link_error("The destination must start with http:// or https://", "link_protocol", &[]));
    }
    if js::len16(&text) > 2000 {
        return Err(link_error("The destination is longer than 2,000 characters", "link_long", &[]));
    }
    Ok(url.href())
}

fn default_name(url: &str) -> String {
    let u = Url::parse(url).expect("a checked URL");
    let path = u.pathname();
    js::head16(&format!("{}{}", strip_www(&u.hostname()), if path == "/" { "" } else { path.as_str() }), 100)
}

/// Short links over a Runlight.
pub struct Links<'a>(pub(crate) &'a Runlight);

impl Runlight {
    /// Short links: create, change, delete, and import.
    pub fn links(&self) -> Links<'_> {
        Links(self)
    }
}

impl Links<'_> {
    async fn domain_for(&self, site: &str, value: &str) -> Result<String, Error> {
        let domain = strip_www(js::trim(value));
        if domain.is_empty() {
            return Ok(String::new());
        }
        let known = self.0.store().link_domains().await?;
        if !known.iter().any(|(d, s)| *d == domain && s == site) {
            return Err(link_error(
                format!("Add {domain} as a link domain in Settings first"),
                "link_domain",
                &[("domain", &domain)],
            ));
        }
        Ok(domain)
    }

    /// Slugs are unique across every domain, so a link can always fall back to the app's own path.
    async fn free_slug(&self, wanted: Option<&str>, except: Option<&str>) -> Result<String, Error> {
        if let Some(wanted) = wanted.filter(|w| !w.is_empty()) {
            if !test(js_re!(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$"), wanted) {
                return Err(link_error(
                    "A slug is letters, digits, dashes, and underscores, up to 100",
                    "link_slug",
                    &[],
                ));
            }
            if let Some(taken) = self.0.store().link_by_slug(wanted).await?
                && Some(taken.id.as_str()) != except
            {
                return Err(link_error(format!("/{wanted} is already taken"), "link_taken", &[("slug", wanted)]));
            }
            return Ok(wanted.to_string());
        }
        for _ in 0..8 {
            let slug = random_slug();
            if self.0.store().link_by_slug(&slug).await?.is_none() {
                return Ok(slug);
            }
        }
        Err(link_error("Could not find a free slug; try again", "link_no_slug", &[]))
    }

    /// Makes a link.
    pub async fn create(&self, site: &str, input: &LinkInput) -> Result<LinkRow, Error> {
        self.0.init().await?;
        let url = clean_url(&input.url)?;
        let domain = self.domain_for(site, input.domain.as_deref().unwrap_or("")).await?;
        let slug = self.free_slug(input.slug.as_deref().map(js::trim), None).await?;
        let now = self.0.now();
        let name = input
            .name
            .as_deref()
            .map(js::trim)
            .filter(|n| !n.is_empty())
            .map_or_else(|| default_name(&url), str::to_string);
        let link = LinkRow {
            id: new_id(),
            site: site.into(),
            domain,
            slug,
            name: js::head16(&name, 100),
            url,
            created_at: now,
            updated_at: now,
        };
        self.0.store().insert_link(&link).await?;
        Ok(link)
    }

    /// Changes a link.
    pub async fn update(&self, id: &str, input: &LinkPatch) -> Result<LinkRow, Error> {
        self.0.init().await?;
        let Some(link) = self.0.store().link_by_id(id).await? else { return Err(Error::Range("Unknown link".into())) };
        let mut next = link.clone();
        if let Some(url) = &input.url {
            next.url = clean_url(url)?;
        }
        if let Some(name) = &input.name {
            let n = js::head16(js::trim(name), 100);
            next.name = if n.is_empty() { default_name(&next.url) } else { n };
        }
        // Keeping a link's domain needs no check, even while that domain is removed.
        if let Some(domain) = &input.domain
            && strip_www(js::trim(domain)) != link.domain
        {
            next.domain = self.domain_for(&link.site, domain).await?;
        }
        if let Some(slug) = &input.slug {
            next.slug = self.free_slug(Some(js::trim(slug)), Some(&link.id)).await?;
        }
        next.updated_at = self.0.now();
        self.0.store().update_link(&next).await?;
        Ok(next)
    }

    /// Deletes a link; its clicks stay in the history.
    pub async fn remove(&self, id: &str) -> Result<(), Error> {
        self.0.init().await?;
        if self.0.store().link_by_id(id).await?.is_none() {
            return Err(Error::Range("Unknown link".into()));
        }
        self.0.store().delete_link(id, self.0.now()).await?;
        Ok(())
    }

    /// Creates many links at once, as from a CSV. Rows that fail are reported with their reason and the
    /// rest go in. Answers `{ created, failed }`.
    pub async fn import(&self, site: &str, rows: &[Value]) -> Result<Value, Error> {
        let mut failed = Vec::new();
        let mut created = 0;
        for (i, raw) in rows.iter().enumerate() {
            let pick = |keys: &[&str]| {
                keys.iter().find_map(|k| match raw.get(k) {
                    Some(Value::String(s)) if !js::trim(s).is_empty() => Some(js::trim(s).to_string()),
                    _ => None,
                })
            };
            let input = LinkInput {
                url: pick(&["url", "destination_url"]).unwrap_or_default(),
                name: pick(&["name", "link_name"]),
                slug: pick(&["slug", "link_slug"]),
                domain: pick(&["domain", "tracking_domain"]),
            };
            match self.create(site, &input).await {
                Ok(_) => created += 1,
                // A bad row is reported and skipped; a failing database stops the whole import.
                Err(Error::Link(e)) => {
                    let mut o = Object::new();
                    o.set("row", i + 1);
                    o.set("reason", e.message.clone());
                    o.set("code", e.code.clone());
                    o.set("params", e.params_value());
                    failed.push(Value::Object(o));
                }
                Err(e) => return Err(e),
            }
        }
        Ok(crate::obj! { "created" => created, "failed" => Value::Array(failed) })
    }
}
