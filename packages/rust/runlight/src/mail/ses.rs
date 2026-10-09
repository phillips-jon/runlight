//! Amazon SES (API v2) with a hand-rolled Signature Version 4, so there is no
//! AWS SDK to install. https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html

use hmac::{Hmac, Mac};

use super::transports::{MailConfig, MailError, Message, get_or_empty, mail_error, service_message};
use crate::goals::CodedError;
use crate::hash::{hex, sha256};
use crate::http::{FetchInit, SharedFetcher, Url};
use crate::js::{self, Object, Value};
use crate::obj;
use crate::sources::encode_uri_component;

fn hmac(key: &[u8], text: &str) -> Vec<u8> {
    let mut mac = Hmac::<sha2::Sha256>::new_from_slice(key).expect("HMAC takes any key");
    mac.update(text.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

/// What `sign_v4` signs.
#[derive(Clone, Debug)]
pub struct SignInput<'a> {
    /// The method.
    pub method: &'a str,
    /// The URL.
    pub url: &'a Url,
    /// The body.
    pub body: &'a str,
    /// The region, like us-east-1.
    pub region: &'a str,
    /// The service, like ses.
    pub service: &'a str,
    /// The access key ID.
    pub access_key_id: &'a str,
    /// The secret access key.
    pub secret_access_key: &'a str,
    /// The time it is signed at, in epoch milliseconds.
    pub now: i64,
    /// The headers to sign besides host and x-amz-date, string values.
    pub headers: &'a Object,
}

/// `decodeURIComponent`: `None` where JavaScript throws a URIError (a `%`
/// without two hex digits after it, or bytes that are not UTF-8).
fn decode_uri_component(text: &str) -> Option<String> {
    let b = text.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let hi = (*b.get(i + 1)? as char).to_digit(16)?;
            let lo = (*b.get(i + 2)? as char).to_digit(16)?;
            out.push((hi * 16 + lo) as u8);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// `text.trim().replace(/\s+/g, " ")`.
fn squeeze(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for c in js::trim(text).chars() {
        if js::is_space(c) {
            space = true;
            continue;
        }
        if space {
            out.push(' ');
            space = false;
        }
        out.push(c);
    }
    out
}

/// Signs a request; public for its test against AWS's published example.
/// The headers given, then `host` and `x-amz-date`, then `authorization`.
/// An error (JavaScript's URIError, "URI malformed") when the URL's path holds a
/// percent sign that does not decode.
pub fn sign_v4(input: &SignInput<'_>) -> Result<Object, String> {
    // toISOString() without -, :, and the milliseconds.
    let iso: String = js::iso_string(input.now).chars().filter(|c| *c != '-' && *c != ':').collect();
    let amz_date = match iso.find('.') {
        Some(at) if iso[at + 1..].bytes().take(3).filter(u8::is_ascii_digit).count() == 3 => {
            format!("{}{}", &iso[..at], &iso[at + 4..])
        }
        _ => iso,
    };
    let day = js::head16(&amz_date, 8);
    let payload_hash = sha256(input.body);
    let mut headers = input.headers.clone();
    headers.set("host", input.url.host());
    headers.set("x-amz-date", amz_date.as_str());
    let mut names: Vec<String> = headers.keys().map(str::to_lowercase).collect();
    names.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    let mut lower: Vec<(String, String)> = Vec::new();
    for (k, v) in headers.iter() {
        let (k, v) = (k.to_lowercase(), squeeze(&js::js_string(v)));
        match lower.iter_mut().find(|(n, _)| *n == k) {
            Some(e) => e.1 = v,
            None => lower.push((k, v)),
        }
    }
    let value_of = |n: &str| lower.iter().find(|(k, _)| k == n).map(|(_, v)| v.as_str()).unwrap_or("");
    let mut segments = Vec::new();
    for p in input.url.pathname().split('/') {
        segments.push(encode_uri_component(&decode_uri_component(p).ok_or("URI malformed")?));
    }
    let path = segments.join("/");
    let mut pairs: Vec<(String, String)> = input.url.search_params().pairs().to_vec();
    // A stable sort on the name alone, as Array.prototype.sort is.
    pairs.sort_by(|a, b| a.0.encode_utf16().cmp(b.0.encode_utf16()));
    let query: Vec<String> =
        pairs.iter().map(|(k, v)| format!("{}={}", encode_uri_component(k), encode_uri_component(v))).collect();
    let canonical = [
        input.method.to_string(),
        if path.is_empty() { "/".to_string() } else { path },
        query.join("&"),
        names.iter().map(|n| format!("{n}:{}\n", value_of(n))).collect::<String>(),
        names.join(";"),
        payload_hash,
    ]
    .join("\n");
    let scope = format!("{day}/{}/{}/aws4_request", input.region, input.service);
    let to_sign = ["AWS4-HMAC-SHA256", &amz_date, &scope, &sha256(&canonical)].join("\n");
    let mut key = hmac(format!("AWS4{}", input.secret_access_key).as_bytes(), &day);
    key = hmac(&key, input.region);
    key = hmac(&key, input.service);
    key = hmac(&key, "aws4_request");
    let signature = hex(&hmac(&key, &to_sign));
    headers.set(
        "authorization",
        format!(
            "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={}, Signature={signature}",
            input.access_key_id,
            names.join(";")
        ),
    );
    Ok(headers)
}

/// `/^[a-z]{2}(-[a-z]+)+-\d$/`.
fn is_region(region: &str) -> bool {
    let parts: Vec<&str> = region.split('-').collect();
    parts.len() >= 3
        && parts[0].len() == 2
        && parts[0].bytes().all(|b| b.is_ascii_lowercase())
        && parts[1..parts.len() - 1].iter().all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_lowercase()))
        && parts[parts.len() - 1].len() == 1
        && parts[parts.len() - 1].bytes().all(|b| b.is_ascii_digit())
}

/// Sends one message through Amazon SES, signed at `now` (epoch milliseconds).
pub async fn ses_send(
    config: &MailConfig,
    m: &Message,
    from: &str,
    fetcher: &SharedFetcher,
    now: i64,
) -> Result<(), MailError> {
    let region = js::trim(get_or_empty(config, "region"));
    if !is_region(region) {
        return Err(CodedError::new("That is not an AWS region, like us-east-1", "mail_region", &[]));
    }
    let href = format!("https://email.{region}.amazonaws.com/v2/email/outbound-emails");
    let url = Url::parse(&href).ok_or_else(|| mail_error("Invalid URL"))?;
    let header_list: Vec<Value> =
        m.headers_object().iter().map(|(k, v)| obj! { "Name" => k, "Value" => v.clone() }).collect();
    let body = js::stringify(&obj! {
        "FromEmailAddress" => from,
        "Destination" => obj! { "ToAddresses" => Value::Array(vec![m.to.as_str().into()]) },
        "Content" => obj! {
            "Simple" => obj! {
                "Subject" => obj! { "Data" => m.subject.as_str(), "Charset" => "UTF-8" },
                "Body" => obj! {
                    "Html" => obj! { "Data" => m.html.as_str(), "Charset" => "UTF-8" },
                    "Text" => obj! { "Data" => m.text.as_str(), "Charset" => "UTF-8" },
                },
                "Headers" => Value::Array(header_list),
            },
        },
    });
    let mut headers = sign_v4(&SignInput {
        method: "POST",
        url: &url,
        body: &body,
        region,
        service: "ses",
        access_key_id: js::trim(get_or_empty(config, "accessKeyId")),
        secret_access_key: js::trim(get_or_empty(config, "secretAccessKey")),
        now,
        headers: &Object::new().with("content-type", "application/json"),
    })
    .map_err(mail_error)?;
    headers.remove("host");
    let mut init = FetchInit::method("POST").body(body).timeout(20_000);
    for (k, v) in headers.iter() {
        init = init.header(k, js::js_string(v));
    }
    let response = fetcher.fetch(&url.href(), init).await.map_err(|e| {
        let detail = e.to_string();
        CodedError::new(
            format!("Could not reach Amazon SES: {detail}"),
            "mail_unreachable",
            &[("host", "Amazon SES"), ("detail", &detail)],
        )
    })?;
    if !response.ok() {
        let message = service_message(&response.text());
        let status = response.status;
        let (said, detail) = if message.is_empty() {
            (String::new(), status.to_string())
        } else {
            (format!(": {message}"), format!("{status} {message}"))
        };
        return Err(CodedError::new(
            format!("Amazon SES answered {status}{said}"),
            "mail_refused",
            &[("host", "Amazon SES"), ("detail", &detail)],
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn regions_are_read_as_the_pattern_reads_them() {
        for ok in ["us-east-1", "eu-west-1", "ap-southeast-2", "us-gov-west-1"] {
            assert!(is_region(ok), "{ok}");
        }
        for bad in ["nowhere", "us-1", "useast-1", "us-east-12", "US-east-1", "us--1", "us-east-", "u-east-1"] {
            assert!(!is_region(bad), "{bad}");
        }
    }

    #[test]
    fn uri_components_decode_as_javascript_decodes_them() {
        assert_eq!(decode_uri_component("caf%C3%A9").as_deref(), Some("café"));
        assert_eq!(decode_uri_component("%7Ec%2F").as_deref(), Some("~c/"));
        assert_eq!(decode_uri_component("%zz"), None);
        assert_eq!(decode_uri_component("%FF"), None);
        assert_eq!(decode_uri_component("%4"), None);
    }

    #[test]
    fn header_values_are_squeezed() {
        assert_eq!(squeeze("  application/json   with \u{a0} spaces "), "application/json with spaces");
    }
}
