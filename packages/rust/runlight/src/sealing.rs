//! Keys kept in the database, sealed with AES-GCM under a key derived from the secret (mail/secret.ts).

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use sha2::{Digest, Sha256};

fn cipher(secret: &str) -> Aes256Gcm {
    let key = Sha256::digest(format!("runlight-mail:{secret}").as_bytes());
    Aes256Gcm::new_from_slice(&key).expect("a 32 byte key")
}

/// `v1:<iv>:<ciphertext>`, or `plain:<text>` when the server has no secret to encrypt with.
pub(crate) fn seal(value: &str, secret: Option<&str>) -> String {
    let Some(secret) = secret.filter(|s| !s.is_empty()) else { return format!("plain:{value}") };
    let iv = crate::hash::random_bytes(12);
    let data = cipher(secret).encrypt(Nonce::from_slice(&iv), value.as_bytes()).expect("encryption");
    format!("v1:{}:{}", STANDARD.encode(iv), STANDARD.encode(data))
}

/// The sealed value, or `None` when it cannot be opened (a different secret, or damaged).
pub(crate) fn unseal(sealed: &str, secret: Option<&str>) -> Option<String> {
    if let Some(plain) = sealed.strip_prefix("plain:") {
        return Some(plain.to_string());
    }
    let mut parts = sealed.split(':');
    let (version, iv, data) = (parts.next()?, parts.next()?, parts.next()?);
    let secret = secret.filter(|s| !s.is_empty())?;
    if version != "v1" || iv.is_empty() || data.is_empty() {
        return None;
    }
    let iv = crate::geo::atob(iv)?;
    if iv.len() != 12 {
        return None;
    }
    let plain = cipher(secret).decrypt(Nonce::from_slice(&iv), crate::geo::atob(data)?.as_slice()).ok()?;
    Some(String::from_utf8_lossy(&plain).into_owned())
}
