//! The cryptography accounts need. Passwords use scrypt, as the standalone server always has, with the same
//! bytes as Node's; a PBKDF2 hash made on an edge runtime checks out too.
//!
//! Where WebCrypto or `atob` would throw in the TypeScript, these answer a [`CryptoError`] instead.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::aes::Aes256;
use aes_gcm::aes::cipher::{BlockEncrypt, generic_array::GenericArray};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ghash::GHash;
use ghash::universal_hash::UniversalHash;
use hmac::{Hmac, Mac};
use sha1::Sha1;
use sha2::{Digest, Sha256};

pub use crate::hash::{hex, random_bytes};

/// What the TypeScript throws from its cryptography, by the name of the DOMException.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CryptoError {
    /// `atob` met text that is not base64 (an InvalidCharacterError).
    InvalidCharacter,
    /// WebCrypto refused a key, as it refuses an empty HMAC key (a DataError).
    Data,
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            CryptoError::InvalidCharacter => "The string to be decoded is not correctly encoded.",
            CryptoError::Data => "Zero-length key is not supported",
        })
    }
}

impl std::error::Error for CryptoError {}

/// Bytes as base64url, without padding.
pub fn base64url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Bytes from base64url (or plain base64), read as `atob` reads them: ASCII white space is skipped, padding
/// is optional, leftover bits are dropped, and anything else that is not base64 is refused.
pub fn from_base64url(text: &str) -> Result<Vec<u8>, CryptoError> {
    let mut plain: Vec<u8> = text
        .bytes()
        .filter(|b| !matches!(b, b'\t' | b'\n' | 0x0c | b'\r' | b' '))
        .map(|b| match b {
            b'-' => b'+',
            b'_' => b'/',
            other => other,
        })
        .collect();
    // A character outside ASCII is never base64; its bytes are refused below.
    if plain.len().is_multiple_of(4) {
        if plain.ends_with(b"==") {
            plain.truncate(plain.len() - 2);
        } else if plain.ends_with(b"=") {
            plain.truncate(plain.len() - 1);
        }
    }
    if plain.len() % 4 == 1 {
        return Err(CryptoError::InvalidCharacter);
    }
    let mut out = Vec::with_capacity(plain.len() * 3 / 4);
    let mut value: u32 = 0;
    let mut bits = 0;
    for b in plain {
        let digit = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return Err(CryptoError::InvalidCharacter),
        };
        value = (value << 6) | u32::from(digit);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((value >> bits) as u8);
            value &= (1 << bits) - 1;
        }
    }
    Ok(out)
}

/// SHA-256 of bytes (a string's UTF-8).
pub fn sha256(value: &[u8]) -> Vec<u8> {
    Sha256::digest(value).to_vec()
}

/// The hash an HMAC is made with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HmacHash {
    /// SHA-1, for TOTP.
    Sha1,
    /// SHA-256.
    Sha256,
}

/// An HMAC. An empty key is refused, as WebCrypto refuses to import one.
pub fn hmac(hash: HmacHash, key: &[u8], data: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if key.is_empty() {
        return Err(CryptoError::Data);
    }
    Ok(match hash {
        HmacHash::Sha1 => {
            let mut mac = <Hmac<Sha1> as Mac>::new_from_slice(key).expect("HMAC takes any key");
            mac.update(data);
            mac.finalize().into_bytes().to_vec()
        }
        HmacHash::Sha256 => {
            let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC takes any key");
            mac.update(data);
            mac.finalize().into_bytes().to_vec()
        }
    })
}

/// Compares two strings in time that does not depend on where they differ.
pub fn same_text(a: &str, b: &str) -> bool {
    same_bytes(a.as_bytes(), b.as_bytes())
}

fn same_bytes(a: &[u8], b: &[u8]) -> bool {
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        diff |= usize::from(a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(0));
    }
    diff == 0
}

/// The cost the standalone server has always hashed passwords with: N 16384, r 8, p 1.
const SCRYPT_LOG_N: u8 = 14;
const SCRYPT_R: u32 = 8;
const SCRYPT_P: u32 = 1;

/// As many PBKDF2 rounds as Cloudflare Workers allow, the strictest runtime Runlight runs on.
pub const PBKDF2_ROUNDS: u32 = 100_000;

/// The shortest stored key accepted. Ours are 32 bytes; an empty or cut key would match too easily, or anything.
const MIN_KEY_BYTES: usize = 16;

/// Node's `scrypt(password, salt, length, { N, r, p })`: the same bytes. `None` for a cost Node refuses
/// (N not a power of two above 1, or too large for r) or a length of 0.
pub fn scrypt_derive(password: &[u8], salt: &[u8], n: u64, r: u32, p: u32, length: usize) -> Option<Vec<u8>> {
    if n < 2 || !n.is_power_of_two() || length == 0 {
        return None;
    }
    let params = scrypt::Params::new(n.trailing_zeros() as u8, r, p, 32).ok()?;
    let mut out = vec![0u8; length];
    scrypt::scrypt(password, salt, &params, &mut out).ok()?;
    Some(out)
}

fn scrypt_key(password: &str, salt: &[u8], length: usize) -> Vec<u8> {
    scrypt_derive(password.as_bytes(), salt, 1 << SCRYPT_LOG_N, SCRYPT_R, SCRYPT_P, length)
        .expect("the server's own scrypt cost")
}

fn pbkdf2_key(password: &str, salt: &[u8], rounds: u32, length: usize) -> Vec<u8> {
    let mut out = vec![0u8; length];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), salt, rounds, &mut out);
    out
}

/// A password hash, in the scrypt form the standalone server has always written: `scrypt$salt$key`.
/// It takes a while on purpose; call it off the async runtime's threads.
pub fn hash_password(password: &str) -> String {
    let salt = random_bytes(16);
    format!("scrypt${}${}", base64url(&salt), base64url(&scrypt_key(password, &salt, 32)))
}

/// Whether a password matches a hash, scrypt or PBKDF2. A stored hash whose salt or key is not base64url
/// matches nothing, rather than failing the sign-in.
pub fn check_password(password: &str, stored: &str) -> bool {
    let parts: Vec<&str> = stored.split('$').collect();
    if parts[0] == "scrypt" && parts.len() == 3 {
        let (Ok(expected), Ok(salt)) = (from_base64url(parts[2]), from_base64url(parts[1])) else { return false };
        if expected.len() < MIN_KEY_BYTES {
            return false;
        }
        return same_bytes(&scrypt_key(password, &salt, expected.len()), &expected);
    }
    if parts[0] == "pbkdf2" && parts.len() == 4 {
        let rounds = crate::js::text_number(parts[1]);
        if !crate::js::is_integer(rounds) || !(1.0..=10_000_000.0).contains(&rounds) {
            return false;
        }
        let (Ok(expected), Ok(salt)) = (from_base64url(parts[3]), from_base64url(parts[2])) else { return false };
        if expected.len() < MIN_KEY_BYTES {
            return false;
        }
        return same_bytes(&pbkdf2_key(password, &salt, rounds as u32, expected.len()), &expected);
    }
    false
}

fn seal_key(secret: &str) -> Vec<u8> {
    sha256(format!("totp:{secret}").as_bytes())
}

/// Seals text with AES-256-GCM under a key from the secret, as "iv.body.tag" in base64url, the form the
/// standalone server has always stored two-factor secrets in.
pub fn seal_text(text: &str, secret: &str) -> String {
    seal_text_with_iv(text, secret, &random_bytes(12))
}

/// [`seal_text`] with a twelve-byte IV of the caller's, for tests.
#[doc(hidden)]
pub fn seal_text_with_iv(text: &str, secret: &str, iv: &[u8]) -> String {
    let cipher = Aes256Gcm::new_from_slice(&seal_key(secret)).expect("a 32-byte key");
    let out = cipher.encrypt(Nonce::from_slice(iv), text.as_bytes()).expect("AES-GCM seals any text");
    let (body, tag) = out.split_at(out.len() - 16);
    format!("{}.{}.{}", base64url(iv), base64url(body), base64url(tag))
}

/// The text sealed by [`seal_text`], or `None` when it does not open with this secret.
pub fn unseal_text(sealed: &str, secret: &str) -> Option<String> {
    let mut parts = sealed.split('.');
    let iv = parts.next().unwrap_or("");
    let body = parts.next()?;
    let tag = parts.next().unwrap_or("");
    if iv.is_empty() || tag.is_empty() {
        return None;
    }
    // WebCrypto reads the tag as the last 16 bytes of body and tag together, wherever the dot fell.
    let mut joined = from_base64url(body).ok()?;
    joined.extend(from_base64url(tag).ok()?);
    let iv = from_base64url(iv).ok()?;
    // WebCrypto refuses an IV shorter than 12 bytes.
    if joined.len() < 16 || iv.len() < 12 {
        return None;
    }
    let key = seal_key(secret);
    let plain = if iv.len() == 12 {
        let cipher = Aes256Gcm::new_from_slice(&key).expect("a 32-byte key");
        cipher.decrypt(Nonce::from_slice(&iv), Payload { msg: &joined, aad: &[] }).ok()?
    } else {
        open_long_iv(&key, &iv, &joined)?
    };
    Some(decode_utf8(&plain))
}

/// AES-256-GCM opened under an IV of other than twelve bytes, which the aes-gcm crate takes only at a
/// length fixed when it is built: the counter starts from GHASH of the IV (NIST SP 800-38D, 7.2).
fn open_long_iv(key: &[u8], iv: &[u8], joined: &[u8]) -> Option<Vec<u8>> {
    let aes = Aes256::new_from_slice(key).ok()?;
    let encrypt = |block: [u8; 16]| {
        let mut b = GenericArray::from(block);
        aes.encrypt_block(&mut b);
        <[u8; 16]>::from(b)
    };
    let h = encrypt([0u8; 16]);
    let ghash = |chunks: &[&[u8]], lengths: [u64; 2]| {
        let mut g = GHash::new(&GenericArray::from(h));
        for chunk in chunks {
            g.update_padded(chunk);
        }
        let mut last = [0u8; 16];
        last[..8].copy_from_slice(&lengths[0].to_be_bytes());
        last[8..].copy_from_slice(&lengths[1].to_be_bytes());
        g.update(&[GenericArray::from(last)]);
        <[u8; 16]>::from(g.finalize())
    };
    let j0 = ghash(&[iv], [0, iv.len() as u64 * 8]);
    let (body, tag) = joined.split_at(joined.len() - 16);
    let mut expected = ghash(&[&[], body], [0, body.len() as u64 * 8]);
    let mask = encrypt(j0);
    for (e, m) in expected.iter_mut().zip(mask) {
        *e ^= m;
    }
    if !same_bytes(&expected, tag) {
        return None;
    }
    let mut counter = j0;
    let mut out = Vec::with_capacity(body.len());
    for chunk in body.chunks(16) {
        let n = u32::from_be_bytes([counter[12], counter[13], counter[14], counter[15]]).wrapping_add(1);
        counter[12..].copy_from_slice(&n.to_be_bytes());
        let stream = encrypt(counter);
        out.extend(chunk.iter().zip(stream).map(|(c, s)| c ^ s));
    }
    Some(out)
}

/// TextDecoder's reading: bytes that are not UTF-8 become U+FFFD, and a leading byte order mark goes.
fn decode_utf8(bytes: &[u8]) -> String {
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    String::from_utf8_lossy(bytes).into_owned()
}
