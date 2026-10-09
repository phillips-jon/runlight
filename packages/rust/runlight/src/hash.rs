//! Hashes and random ids.

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

/// Lower case hex of bytes.
pub fn hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

/// SHA-256 of the text, as hex.
pub fn sha256(text: &str) -> String {
    hex(&Sha256::digest(text.as_bytes()))
}

/// HMAC-SHA-256 of text under key, as hex.
pub fn hmac(key: &str, text: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(key.as_bytes()).expect("HMAC takes any key");
    mac.update(text.as_bytes());
    hex(&mac.finalize().into_bytes())
}

/// The day's visitor hash: SHA-256 of salt, site, IP, and user agent, cut to
/// 64 bits. The salt changes every day and old salts are deleted, so the
/// hash cannot be recomputed and does not follow anyone across days.
pub fn visitor_hash(salt: &str, site: &str, ip: &str, ua: &str) -> String {
    sha256(&format!("{salt}\n{site}\n{ip}\n{ua}"))[..16].to_string()
}

/// Random bytes from the system.
pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut out = vec![0u8; n];
    getrandom::fill(&mut out).expect("the system's random numbers");
    out
}

/// A random id: `bytes` random bytes as hex.
pub fn random_id(bytes: usize) -> String {
    hex(&random_bytes(bytes))
}

/// A random id of twelve bytes, the SDK's default.
pub fn new_id() -> String {
    random_id(12)
}

/// A new day's salt.
pub fn random_salt() -> String {
    random_id(32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_match_the_sdk() {
        assert_eq!(sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(visitor_hash("s", "default", "1.2.3.4", "ua").len(), 16);
        assert_eq!(new_id().len(), 24);
        assert_eq!(
            hmac("key", "The quick brown fox jumps over the lazy dog"),
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
        );
    }
}
