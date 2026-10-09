//! Accounts' cryptography, two-factor codes, the throttle, and the account pages, against
//! packages/php/tests/fixtures/crypto.json and pages.json, written by the TypeScript SDK and Node's own crypto.

mod common;

use common::{fixture, list, s};
use runlight::accounts::auth::{match_step, recovery_codes, recovery_hash, unbase32};
use runlight::accounts::crypto::{
    self, CryptoError, HmacHash, base64url, check_password, from_base64url, hash_password, hex, same_text,
    scrypt_derive, seal_text, seal_text_with_iv, unseal_text,
};
use runlight::accounts::pages::{self, CodePage, InvitePage, LoginPage, SetupPage};
use runlight::accounts::{Throttle, base32, otpauth_uri, totp};
use runlight::js::Value;

fn num(v: &Value, key: &str) -> f64 {
    v.at(key).as_f64().unwrap_or_else(|| panic!("{key} is a number"))
}

fn throws(v: &Value) -> bool {
    v.get("throws").is_some()
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
}

fn hex_of(bytes: &[u8]) -> String {
    hex(bytes)
}

#[test]
fn scrypt_gives_nodes_bytes() {
    let f = fixture("crypto");
    for case in list(&f, "scrypt") {
        let key = scrypt_derive(
            s(case, "password").as_bytes(),
            &from_base64url(s(case, "salt")).unwrap(),
            num(case, "N") as u64,
            num(case, "r") as u32,
            num(case, "p") as u32,
            num(case, "length") as usize,
        )
        .expect("a cost Node takes");
        assert_eq!(hex_of(&key), s(case, "key"), "{}", case.to_json());
    }
}

#[test]
fn scrypt_test_vectors_from_rfc_7914() {
    assert_eq!(
        hex_of(&scrypt_derive(b"password", b"NaCl", 1024, 8, 16, 64).unwrap()),
        "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"
    );
    assert_eq!(scrypt_derive(b"x", b"y", 1000, 8, 1, 32), None, "a cost that is not a power of two");
}

#[test]
fn passwords_hashed_by_typescript_check_here() {
    let f = fixture("crypto");
    for (i, case) in list(&f, "hashes").iter().enumerate() {
        assert!(check_password(s(case, "password"), s(case, "hash")), "{}", s(case, "hash"));
        if i == 0 {
            assert!(!check_password(&format!("{}!", s(case, "password")), s(case, "hash")));
        }
    }
}

#[test]
fn new_hashes_use_scrypt_and_check() {
    let hash = hash_password("a long password");
    let parts: Vec<&str> = hash.split('$').collect();
    assert_eq!(parts[0], "scrypt");
    assert_eq!((parts[1].len(), parts[2].len()), (22, 43));
    assert!(check_password("a long password", &hash));
    assert!(!check_password("a wrong password", &hash));
    assert_ne!(hash, hash_password("a long password"), "a new salt each time");
}

#[test]
fn check_password_answers_as_typescript_does() {
    let f = fixture("crypto");
    for case in list(&f, "checks") {
        let got = check_password(s(case, "password"), s(case, "stored"));
        let label = format!("{} against {}", s(case, "password"), s(case, "stored"));
        assert_eq!(got, case.at("value").as_bool().unwrap(), "{label}");
    }
}

#[test]
fn sealed_text_opens_both_ways() {
    let f = fixture("crypto");
    for case in list(&f, "sealedByTs") {
        let (text, secret) = (s(case, "text"), s(case, "secret"));
        assert_eq!(unseal_text(s(case, "sealed"), secret).as_deref(), Some(text));
        assert_eq!(unseal_text(&seal_text(text, secret), secret).as_deref(), Some(text));
    }
    for case in list(&f, "sealedWithIv") {
        let iv = from_base64url(s(case, "iv")).unwrap();
        assert_eq!(seal_text_with_iv(s(case, "text"), s(case, "secret"), &iv), s(case, "sealed"));
    }
}

#[test]
fn unseal_answers_as_typescript_does() {
    let f = fixture("crypto");
    for case in list(&f, "unseal") {
        let want = case.at("result").as_str();
        assert_eq!(unseal_text(s(case, "sealed"), s(case, "secret")).as_deref(), want, "{}", s(case, "sealed"));
    }
}

#[test]
fn base64_and_base32() {
    let f = fixture("crypto");
    for case in list(&f, "base64") {
        let got = from_base64url(s(case, "text"));
        if throws(case) {
            assert_eq!(got, Err(CryptoError::InvalidCharacter), "{:?}", s(case, "text"));
        } else {
            assert_eq!(hex_of(&got.unwrap()), s(case, "value"), "{:?}", s(case, "text"));
        }
    }
    for case in list(&f, "encode") {
        let bytes = unhex(s(case, "hex"));
        assert_eq!(base64url(&bytes), s(case, "base64url"));
        assert_eq!(base32(&bytes), s(case, "base32"));
        assert_eq!(hex_of(&from_base64url(s(case, "base64url")).unwrap()), s(case, "hex"));
        assert_eq!(hex_of(&unbase32(s(case, "base32"))), s(case, "hex"));
    }
}

#[test]
fn totp_codes() {
    let f = fixture("crypto");
    let cases = list(&f, "totp");
    assert_eq!(cases.len(), 162);
    for case in cases {
        let step = num(case, "step").floor() as i64;
        let got = totp(s(case, "secret"), step);
        let label = format!("{} at {step}", s(case, "secret"));
        if throws(case) {
            assert_eq!(got, Err(CryptoError::Data), "{label}");
        } else {
            assert_eq!(got.as_deref(), Ok(s(case, "value")), "{label}");
        }
    }
}

#[test]
fn rfc_6238_vector() {
    // RFC 6238's SHA-1 secret "12345678901234567890" at 59 seconds: 94287082, of which authenticator apps show the last six.
    assert_eq!(totp(&base32(b"12345678901234567890"), 1).unwrap(), "287082");
    assert_eq!(totp(&base32(b"12345678901234567890"), 1_234_567_890 / 30).unwrap(), "005924");
}

#[test]
fn match_step_allows_one_step_either_side_and_never_an_old_one() {
    let secret = "JBSWY3DPEHPK3PXP";
    let now = 1_759_900_000_000;
    let step = now / 30_000;
    let code = |n: i64| totp(secret, n).unwrap();
    assert_eq!(match_step(secret, &code(step), now, 0), Ok(Some(step)));
    assert_eq!(match_step(secret, &code(step - 1), now, 0), Ok(Some(step - 1)));
    assert_eq!(match_step(secret, &code(step + 1), now, 0), Ok(Some(step + 1)));
    assert_eq!(match_step(secret, &code(step + 2), now, 0), Ok(None));
    assert_eq!(match_step(secret, &code(step), now, step), Ok(None), "a code used once is not taken again");
}

#[test]
fn otpauth_signatures_recovery_and_same_text() {
    let f = fixture("crypto");
    for case in list(&f, "uris") {
        assert_eq!(otpauth_uri(s(case, "secret"), s(case, "email"), s(case, "host")), s(case, "uri"));
    }
    for case in list(&f, "signatures") {
        // How sessions, tickets, and devices are signed: HMAC-SHA-256 of "body.hash" under the install's secret.
        let mac = crypto::hmac(
            HmacHash::Sha256,
            s(case, "secret").as_bytes(),
            format!("{}.{}", s(case, "body"), s(case, "hash")).as_bytes(),
        )
        .unwrap();
        assert_eq!(base64url(&mac), s(case, "signature"));
    }
    for case in list(&f, "recovery") {
        assert_eq!(recovery_hash(s(case, "code")), s(case, "hash"), "{:?}", s(case, "code"));
    }
    for case in list(&f, "same") {
        assert_eq!(same_text(s(case, "a"), s(case, "b")), case.at("same").as_bool().unwrap());
    }
    let codes = recovery_codes();
    assert_eq!(codes.len(), 10);
    for code in codes {
        let (a, b) = code.split_once('-').unwrap();
        assert!(a.len() == 4 && b.len() == 4, "{code}");
        assert!(code.chars().all(|c| c == '-' || c.is_ascii_lowercase() || ('2'..='7').contains(&c)), "{code}");
    }
}

#[test]
fn hmac_refuses_an_empty_key_and_sha1_matches() {
    assert_eq!(crypto::hmac(HmacHash::Sha256, b"", b"x"), Err(CryptoError::Data));
    assert_eq!(
        hex_of(&crypto::hmac(HmacHash::Sha1, b"key", b"The quick brown fox jumps over the lazy dog").unwrap()),
        "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9"
    );
    assert_eq!(hex_of(&crypto::sha256(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

#[test]
fn the_throttle_counts_before_the_check_and_forgives_a_right_try() {
    let now = 1_791_288_000_000;
    let throttle = Throttle::new(3, 1000);
    for _ in 0..3 {
        assert!(throttle.take("jon@example.com", now));
    }
    assert!(throttle.blocked("jon@example.com", now));
    assert!(!throttle.take("jon@example.com", now), "at its limit, nothing more is counted");
    assert!(!throttle.blocked("ada@example.com", now));
    throttle.forgive("jon@example.com");
    assert!(!throttle.blocked("jon@example.com", now));
    throttle.fail("jon@example.com", now);
    assert!(throttle.blocked("jon@example.com", now));
    assert!(!throttle.blocked("jon@example.com", now + 1000), "a window ends");
    throttle.fail("jon@example.com", now + 1000);
    assert!(!throttle.blocked("jon@example.com", now + 1000), "and a new one starts from one");
    throttle.clear("jon@example.com");
    assert!(!throttle.blocked("jon@example.com", now));
    assert!(!Throttle::new(3, 1000).blocked("ada@example.com", now), "each throttle counts on its own");
}

#[test]
fn the_throttle_keeps_a_ceiling_and_its_blocks() {
    let now = 1_791_288_000_000;
    let throttle = Throttle::new(2, 60_000);
    throttle.fail("blocked", now);
    throttle.fail("blocked", now);
    for i in 0..10_050 {
        throttle.fail(&format!("made up {i}"), now);
    }
    assert_eq!(throttle.size(), 10_000);
    assert!(throttle.blocked("blocked", now), "a flood of made-up names cannot wipe out a real block");
    // The oldest names that were not blocked went first, and the newest stayed.
    throttle.fail("made up 0", now);
    assert!(!throttle.blocked("made up 0", now), "counted afresh");
    throttle.fail("made up 10049", now);
    assert!(throttle.blocked("made up 10049", now), "still counted");
}

#[test]
fn styles_and_script_match() {
    let f = fixture("pages");
    assert_eq!(pages::AUTH_CSS, s(&f, "css"));
    assert_eq!(pages::AUTH_JS, s(&f, "js"));
}

fn opt<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

#[test]
fn pages_match() {
    let f = fixture("pages");
    let cases = list(&f, "pages");
    assert_eq!(cases.len(), 48);
    for case in cases {
        let (name, base, o) = (s(case, "fn"), s(case, "base"), case.at("opts"));
        let html = match name {
            "loginPage" => pages::login_page(
                base,
                &LoginPage {
                    error: opt(o, "error"),
                    email: opt(o, "email"),
                    next: opt(o, "next"),
                    forgot: s(o, "forgot"),
                },
            ),
            "codePage" => pages::code_page(
                base,
                &CodePage { pending: s(o, "pending"), next: s(o, "next"), error: opt(o, "error") },
            ),
            "invitePage" => pages::invite_page(
                base,
                &InvitePage {
                    code: s(o, "code"),
                    email: s(o, "email"),
                    role: s(o, "role"),
                    host: s(o, "host"),
                    error: opt(o, "error"),
                },
            ),
            "inviteGonePage" => pages::invite_gone_page(base),
            "setupPage" => pages::setup_page(
                base,
                &SetupPage {
                    code: s(o, "code"),
                    error: opt(o, "error"),
                    email: opt(o, "email"),
                    ask_code: o.get("askCode").and_then(Value::as_bool).unwrap_or(false),
                },
            ),
            "setupLockedPage" => pages::setup_locked_page(base),
            "setupNeedsTokenPage" => pages::setup_needs_token_page(base),
            other => panic!("no page {other}"),
        };
        assert_eq!(html, s(case, "html"), "{name} at {base:?}");
    }
    for case in list(&f, "roles") {
        assert_eq!(pages::role_text(s(case, "role")), s(case, "text"));
    }
}

#[test]
fn setup_asks_for_the_token_when_told() {
    let page = pages::setup_page("/runlight", &SetupPage { code: "", ask_code: true, ..Default::default() });
    assert!(page.contains("RUNLIGHT_TOKEN"));
    assert!(page.contains(r#"action="/runlight/setup""#));
    assert!(page.contains(r#"href="/runlight/auth.css""#));
    let invite =
        pages::invite_page("", &InvitePage { code: "c", email: "a@b.c", role: "member", host: "x", error: None });
    assert!(invite.contains("as a member"));
}
