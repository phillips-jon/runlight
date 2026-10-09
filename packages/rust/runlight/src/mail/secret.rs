//! Keys kept in the database (the mail service's, the AI Assistant's, and the tokens for connected
//! installs) are encrypted with AES-GCM, under a key derived from a secret only the server has:
//! `RUNLIGHT_SECRET`, or else the dashboard token. A copied database alone does not give them away.
//! The label says "mail" because mail came first; changing it would make every saved key unreadable.
//!
//! The sealed form is Web Crypto's: base64 of the 12 byte IV, and base64 of the ciphertext followed
//! by its 16 byte tag, so either implementation opens what the other sealed.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use sha2::{Digest, Sha256};

fn key_for(secret: &str) -> Aes256Gcm {
    let digest = Sha256::digest(format!("runlight-mail:{secret}").as_bytes());
    Aes256Gcm::new_from_slice(&digest).expect("a SHA-256 digest is a 256 bit key")
}

/// `atob`: forgiving base64, which drops ASCII whitespace, takes the padding
/// or leaves it off, and ignores the bits past the last whole byte.
fn from_base64(text: &str) -> Option<Vec<u8>> {
    let mut t: String = text.chars().filter(|c| !matches!(c, ' ' | '\t' | '\n' | '\x0c' | '\r')).collect();
    if t.len().is_multiple_of(4) {
        for _ in 0..2 {
            if t.ends_with('=') {
                t.pop();
            }
        }
    }
    if t.len() % 4 == 1 || !t.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/') {
        return None;
    }
    const FORGIVING: base64::engine::GeneralPurpose = base64::engine::GeneralPurpose::new(
        &base64::alphabet::STANDARD,
        base64::engine::GeneralPurposeConfig::new()
            .with_decode_allow_trailing_bits(true)
            .with_decode_padding_mode(base64::engine::DecodePaddingMode::RequireNone),
    );
    FORGIVING.decode(t.as_bytes()).ok()
}

/// `v1:<iv>:<ciphertext>`, or `plain:<json>` when the server has no secret to encrypt with.
pub fn seal(value: &str, secret: Option<&str>) -> String {
    let secret = match secret {
        Some(s) if !s.is_empty() => s,
        _ => return format!("plain:{value}"),
    };
    let iv = crate::hash::random_bytes(12);
    let data =
        key_for(secret).encrypt(Nonce::from_slice(&iv), value.as_bytes()).expect("AES-GCM seals any value under 64 GB");
    format!("v1:{}:{}", STANDARD.encode(&iv), STANDARD.encode(&data))
}

/// The sealed value, or `None` when it cannot be opened (a different secret, or damaged).
///
/// Web Crypto refuses an IV under 12 bytes, so such a value opens nowhere. It takes a longer one,
/// which no sealed value has; this port takes that as damaged too.
pub fn unseal(sealed: &str, secret: Option<&str>) -> Option<String> {
    if let Some(rest) = sealed.strip_prefix("plain:") {
        return Some(rest.to_string());
    }
    let mut parts = sealed.split(':');
    let (version, iv, data) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    let secret = secret.unwrap_or("");
    if version != "v1" || iv.is_empty() || data.is_empty() || secret.is_empty() {
        return None;
    }
    let iv = from_base64(iv)?;
    let data = from_base64(data)?;
    if iv.len() != 12 {
        return None;
    }
    let plain = key_for(secret).decrypt(Nonce::from_slice(&iv), data.as_slice()).ok()?;
    // TextDecoder: a byte order mark goes, and bytes that are not UTF-8 become U+FFFD.
    let plain = plain.strip_prefix(&[0xef, 0xbb, 0xbf][..]).unwrap_or(&plain);
    Some(String::from_utf8_lossy(plain).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atob_is_forgiving() {
        assert_eq!(from_base64("SGk=").as_deref(), Some(&b"Hi"[..]));
        assert_eq!(from_base64("SGk").as_deref(), Some(&b"Hi"[..]));
        assert_eq!(from_base64(" S G k = ").as_deref(), Some(&b"Hi"[..]));
        assert_eq!(from_base64("SGl="), Some(b"Hi".to_vec()), "trailing bits are dropped");
        assert_eq!(from_base64("SG="), None, "padding that leaves a length of 3 is refused");
        assert_eq!(from_base64("S"), None);
        assert_eq!(from_base64("S*Gk"), None);
        assert_eq!(from_base64(""), Some(Vec::new()));
    }
}
