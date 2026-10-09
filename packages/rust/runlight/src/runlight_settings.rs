//! The Runlight's mail service, email reports, and the assistant's settings (runlight.ts).

use crate::assistant::{AssistantSettings, PROVIDERS};
use crate::error::Error;
use crate::goals::CodedError;
use crate::http::Url;
use crate::js::{self, Object, Value};
use crate::mail::secret::{seal, unseal};
use crate::mail::transports::{Message, SERVICES, check_config, send};
use crate::reports::{ReportPeriod, build_report, last_period};
use crate::runlight::{Runlight, is_email};
use crate::store::{ReportRow, SiteRow};

fn mail_error(message: &str, code: &str) -> Error {
    Error::Mail(CodedError::new(message, code, &[]))
}

impl Runlight {
    /// The mail service: from code, or as saved in the dashboard, with where it came from.
    pub async fn mail_settings(&self) -> Result<Option<(Object, &'static str)>, Error> {
        if let Some(code) = &self.0.mail_in_code {
            return Ok(Some((code.clone(), "code")));
        }
        self.init().await?;
        let Some(sealed) = self.store().setting("mail").await? else { return Ok(None) };
        let Some(opened) = unseal(&sealed, self.secret()) else { return Ok(None) };
        Ok(match js::parse(&opened) {
            Ok(Value::Object(o)) => Some((o, "dashboard")),
            _ => None,
        })
    }

    /// Saves the mail service from the dashboard. A secret field left blank keeps the saved value, so the
    /// browser never needs to see it. `None` removes it.
    pub async fn save_mail_settings(&self, input: Option<&Value>) -> Result<(), Error> {
        if self.0.mail_in_code.is_some() {
            return Err(mail_error("The mail service is set in code", "mail_in_code"));
        }
        let Some(input) = input else {
            self.store().set_setting("mail", None).await?;
            return Ok(());
        };
        let before = self.mail_settings().await?.map(|b| b.0);
        let Some(service) = SERVICES.iter().find(|s| input.get("service").and_then(Value::as_str) == Some(s.id)) else {
            return Err(mail_error("Pick a mail service", "mail_service"));
        };
        let text = |k: &str| js::trim(&js::str_or_empty(input.get(k))).to_string();
        let mut settings = Object::new();
        settings.set("service", service.id);
        for f in service.fields.iter().filter(|f| !f.secret) {
            settings.set(f.name, text(f.name));
        }
        // A blank secret keeps the saved one only while the connection is the same, so changing the host
        // cannot send a saved password somewhere new.
        let same = before.as_ref().is_some_and(|b| {
            b.get("service").and_then(Value::as_str) == Some(service.id)
                && service.fields.iter().all(|f| f.secret || js::str_or_empty(b.get(f.name)) == js::str_or_empty(settings.get(f.name)))
        });
        for f in service.fields.iter().filter(|f| f.secret) {
            let given = text(f.name);
            let value = if given.is_empty() && same { js::str_or_empty(before.as_ref().and_then(|b| b.get(f.name))) } else { given };
            settings.set(f.name, value);
        }
        let from = text("from");
        if !is_email(&from) {
            return Err(mail_error("Enter the address reports come from, like reports@example.com", "mail_from"));
        }
        let from_name = js::head16(&text("fromName"), 80);
        settings.set("from", from);
        if !from_name.is_empty() {
            settings.set("fromName", from_name);
        }
        check_config(&settings).map_err(Error::Mail)?;
        let sealed = seal(&settings.to_json(), self.secret());
        self.store().set_setting("mail", Some(&sealed)).await?;
        Ok(())
    }

    /// Sends one email through the mail service.
    pub async fn send_mail(&self, mut message: Message) -> Result<(), Error> {
        let Some((settings, _)) = self.mail_settings().await? else { return Err(mail_error("Set up a mail service first", "mail_unset")) };
        message.from = js::str_or_empty(settings.get("from"));
        message.from_name = settings.get("fromName").map(js::js_string);
        send(&settings, &message, self.fetcher(), self.now()).await.map_err(Error::Mail)
    }

    /// Sends every report that is due: last week's on Monday from 8am, last month's on the 1st, in each
    /// site's timezone. Safe to run often; each period goes out once. Gives how many went and failed.
    pub async fn send_reports(&self) -> Result<(i64, i64), Error> {
        self.init().await?;
        let (mut sent, mut failed) = (0, 0);
        let reports = self.store().reports(None).await?;
        if reports.is_empty() || self.mail_settings().await?.is_none() {
            return Ok((sent, failed));
        }
        let now = self.now();
        for r in reports {
            let Some(site) = self.site(Some(&r.site)) else { continue };
            let period = last_period(&r.frequency, now, &site.timezone);
            if now < period.due_at || r.last_period == period.key {
                continue;
            }
            if !self.store().claim_report(&r.id, &period.key, now).await? {
                continue;
            }
            match self.deliver_report(&r, &site, Some(&period)).await {
                Ok(()) => sent += 1,
                Err(error) => {
                    self.store().release_report(&r.id, &period.key, &r.last_period).await?;
                    eprintln!("Runlight: could not send the {} report for {} to {}: {}", r.frequency, site.name, r.email, error.message());
                    failed += 1;
                }
            }
        }
        Ok((sent, failed))
    }

    /// Builds and sends one report. Also used by "Send a sample now".
    pub async fn deliver_report(&self, r: &ReportRow, site: &SiteRow, period: Option<&ReportPeriod>) -> Result<(), Error> {
        let owned;
        let period = match period {
            Some(p) => p,
            None => {
                owned = last_period(&r.frequency, self.now(), &site.timezone);
                &owned
            }
        };
        let unsubscribe = format!("{}/unsubscribe/{}", r.origin, r.token);
        let dashboard = format!("{}/?site={}", r.origin, crate::sources::encode_uri_component(&site.id));
        let report = build_report(self.store(), site, &r.frequency, period, &r.lang, &dashboard, &unsubscribe).await?;
        self.send_mail(Message {
            to: r.email.clone(),
            subject: report.subject,
            html: report.html,
            text: report.text,
            headers: vec![("List-Unsubscribe".into(), format!("<{unsubscribe}>")), ("List-Unsubscribe-Post".into(), "List-Unsubscribe=One-Click".into())],
            ..Message::default()
        })
        .await
    }

    /// The dashboard assistant's provider, model, and key, kept sealed like the mail keys.
    pub async fn assistant_settings(&self) -> Result<Option<AssistantSettings>, Error> {
        let Some(stored) = self.store().setting("assistant").await? else { return Ok(None) };
        let Some(opened) = unseal(&stored, self.secret()) else { return Ok(None) };
        let Ok(v) = js::parse(&opened) else { return Ok(None) };
        let s = |k: &str| js::str_or_empty(v.get(k));
        Ok(Some(AssistantSettings { provider: s("provider"), model: s("model"), base_url: s("baseUrl"), key: s("key") }))
    }

    /// Saves the assistant's settings; an empty key keeps the one saved for the same provider. `None` removes them.
    pub async fn save_assistant_settings(&self, input: Option<&Value>) -> Result<(), Error> {
        let Some(input) = input else {
            self.store().set_setting("assistant", None).await?;
            return Ok(());
        };
        let Some(provider) = PROVIDERS.iter().find(|p| input.get("provider").and_then(Value::as_str) == Some(p.id)) else {
            return Err(Error::settings("Choose a provider", "assistant_provider", &[]));
        };
        let base_url = js::trim(&js::str_or_empty(input.get("baseUrl"))).trim_end_matches('/').to_string();
        if !base_url.is_empty() {
            let ok = Url::parse(&base_url).is_some_and(|u| u.protocol() == "https:" || u.protocol() == "http:");
            if !ok {
                return Err(Error::settings("Enter the service's address, starting with https://", "assistant_address_bad", &[]));
            }
        }
        if base_url.is_empty() && provider.base_url.is_empty() {
            return Err(Error::settings("Enter the service's address", "assistant_address", &[]));
        }
        let model = js::head16(js::trim(&js::str_or_empty(input.get("model"))), 200);
        if model.is_empty() && provider.model.is_empty() {
            return Err(Error::settings("Enter the model to use", "assistant_model", &[]));
        }
        let before = self.assistant_settings().await?;
        let mut key = js::trim(&js::str_or_empty(input.get("key"))).to_string();
        // A saved key is kept only for the same service at the same address, so it is never sent somewhere new.
        let address = |b: &str| if b.is_empty() { provider.base_url.to_string() } else { b.to_string() };
        if key.is_empty()
            && let Some(b) = &before
            && b.provider == provider.id
            && address(&b.base_url) == address(&base_url)
        {
            key = b.key.clone();
        }
        if key.is_empty() && provider.key == "yes" {
            return Err(Error::settings(format!("Enter your {} key", provider.name), "assistant_key", &[("provider", provider.name)]));
        }
        let settings = crate::obj! { "provider" => provider.id, "model" => model, "baseUrl" => base_url, "key" => key };
        let sealed = seal(&settings.to_json(), self.secret());
        self.store().set_setting("assistant", Some(&sealed)).await?;
        Ok(())
    }
}
