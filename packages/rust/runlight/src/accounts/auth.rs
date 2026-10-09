//! Accounts: who may sign in, their password hashes, two-factor, invites, and the signed cookie that keeps them
//! signed in. The standalone server always has them, and an app turns them on with its routes' accounts option.

use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::sync::{Arc, Mutex as StdMutex};

use tokio::sync::{Mutex, OnceCell};

use super::crypto::{
    CryptoError, HmacHash, base64url, check_password, hash_password, hex, hmac, random_bytes, same_text, seal_text,
    sha256, unseal_text,
};
use crate::goals::CodedError;
use crate::js::{self, Value};
use crate::obj;
use crate::params;
use crate::store::{DbError, Dialect, Hold, MYSQL_COLLATION, Row, SqlStore};

/// A problem with an account change, to show the person making it: a RangeError in the TypeScript, with a
/// `code` and `params` the dashboard words in its own language.
pub type AccountError = CodedError;

/// Why an accounts call failed: a change refused ([`AccountError`]), the database, or what the TypeScript's
/// cryptography would throw.
#[derive(Clone, Debug, PartialEq)]
pub enum AuthError {
    /// A change refused, with its code.
    Account(AccountError),
    /// The database refused or could not be reached.
    Db(DbError),
    /// A stored hash or key the cryptography refused.
    Crypto(CryptoError),
    /// A stored value that is not the JSON it should be.
    Stored(String),
}

impl std::fmt::Display for AuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AuthError::Account(e) => e.fmt(f),
            AuthError::Db(e) => e.fmt(f),
            AuthError::Crypto(e) => e.fmt(f),
            AuthError::Stored(e) => f.write_str(e),
        }
    }
}

impl std::error::Error for AuthError {}

impl From<AccountError> for AuthError {
    fn from(e: AccountError) -> AuthError {
        AuthError::Account(e)
    }
}
impl From<DbError> for AuthError {
    fn from(e: DbError) -> AuthError {
        AuthError::Db(e)
    }
}
impl From<CryptoError> for AuthError {
    fn from(e: CryptoError) -> AuthError {
        AuthError::Crypto(e)
    }
}

type R<T> = Result<T, AuthError>;

/// The session cookie's name.
pub const SESSION_COOKIE: &str = "runlight_session";
/// Thirty days, renewed on every sign-in.
pub const SESSION_MS: i64 = 30 * 86_400_000;
/// The shortest password accepted, in UTF-16 code units as JavaScript counts them.
pub const MIN_PASSWORD: usize = 10;
/// The most sign-in keys the throttle remembers at once.
const MAX_THROTTLED: usize = 10_000;
/// How long an invite link works.
pub const INVITE_MS: i64 = 7 * 86_400_000;

/// The owner can do everything, and nobody else can remove them or change their role; they can hand ownership to an
/// admin. An admin can do everything the owner can apart from that. A member changes sites, goals, links, and the
/// rest, but not people, the mail service, the assistant's settings, or deleting a site. A viewer reads every site's
/// stats and changes nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    /// The one owner.
    Owner,
    /// Everything but the owner's own powers.
    Admin,
    /// Changes sites and their settings.
    Member,
    /// Reads stats.
    Viewer,
}

impl Role {
    /// Every role, in the TypeScript's order.
    pub const ALL: [Role; 4] = [Role::Owner, Role::Admin, Role::Member, Role::Viewer];

    /// The role's name: "owner", "admin", "member", or "viewer".
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Owner => "owner",
            Role::Admin => "admin",
            Role::Member => "member",
            Role::Viewer => "viewer",
        }
    }

    /// The role a name is, if it is one.
    pub fn parse(name: &str) -> Option<Role> {
        Role::ALL.into_iter().find(|r| r.as_str() == name)
    }

    /// A stored role read back; anything unknown reads as a viewer, the least it could be.
    pub fn from_stored(name: &str) -> Role {
        Role::parse(name).unwrap_or(Role::Viewer)
    }
}

impl std::fmt::Display for Role {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

fn role_of(row: &Row, name: &str) -> Role {
    if row.is_null(name) { Role::Viewer } else { Role::from_stored(&row.text(name)) }
}

/// Someone who may sign in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct User {
    /// The account's id.
    pub id: String,
    /// The email address, trimmed and in lower case.
    pub email: String,
    /// The password hash.
    pub hash: String,
    /// What they may do.
    pub role: Role,
    /// When the account was made, in epoch milliseconds.
    pub created_at: i64,
    /// Whether sign-in also asks for a code from an authenticator app.
    pub two_factor: bool,
    /// Recovery codes not yet used.
    pub recovery_left: usize,
}

impl User {
    /// The user as the TypeScript's object, its keys in order.
    pub fn to_value(&self) -> Value {
        obj! {
            "id" => self.id.as_str(),
            "email" => self.email.as_str(),
            "hash" => self.hash.as_str(),
            "role" => self.role.as_str(),
            "createdAt" => self.created_at,
            "twoFactor" => self.two_factor,
            "recoveryLeft" => self.recovery_left,
        }
    }
}

/// Someone asked to join, until they choose a password. Only a hash of the link's code is kept.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invite {
    /// The invite's id.
    pub id: String,
    /// Who it is for, trimmed and in lower case.
    pub email: String,
    /// The role they join with.
    pub role: Role,
    /// Who sent it, as the caller named them.
    pub invited_by: String,
    /// When it was made, in epoch milliseconds.
    pub created_at: i64,
    /// When its link stops working.
    pub expires_at: i64,
}

impl Invite {
    /// The invite as the TypeScript's object, its keys in order.
    pub fn to_value(&self) -> Value {
        obj! {
            "id" => self.id.as_str(),
            "email" => self.email.as_str(),
            "role" => self.role.as_str(),
            "invitedBy" => self.invited_by.as_str(),
            "createdAt" => self.created_at,
            "expiresAt" => self.expires_at,
        }
    }
}

/// A new invite and the code for its link, which is shown once.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewInvite {
    /// The invite.
    pub invite: Invite,
    /// The code its link carries.
    pub code: String,
}

/// The account a code-step ticket names, and whether a right code may sign in with it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pending {
    /// The account.
    pub user: User,
    /// False for a decoy ticket, which no code ever passes.
    pub real: bool,
}

// Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.
const STEP_MS: i64 = 30_000;
const BASE32: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// Bytes as base32, without padding.
pub fn base32(bytes: &[u8]) -> String {
    let mut bits = 0;
    let mut value: u32 = 0;
    let mut out = String::new();
    for &byte in bytes {
        value = (value << 8) | u32::from(byte);
        bits += 8;
        while bits >= 5 {
            out.push(BASE32[((value >> (bits - 5)) & 31) as usize] as char);
            bits -= 5;
        }
        // Only the low bits are ever read.
        value &= 0xff;
    }
    if bits > 0 {
        out.push(BASE32[((value << (5 - bits)) & 31) as usize] as char);
    }
    out
}

/// Bytes from base32, skipping anything that is not a base32 letter, as authenticator apps' secrets come.
pub fn unbase32(text: &str) -> Vec<u8> {
    let mut bits = 0;
    let mut value: u32 = 0;
    let mut out = Vec::new();
    for c in text.trim_end_matches('=').to_uppercase().chars() {
        let Some(i) = BASE32.iter().position(|&b| b as char == c) else { continue };
        value = ((value << 5) | i as u32) & 0xffff;
        bits += 5;
        if bits >= 8 {
            out.push(((value >> (bits - 8)) & 255) as u8);
            bits -= 8;
        }
    }
    out
}

/// The six-digit code for a secret at a time step. A secret with no base32 in it is refused, as WebCrypto
/// refuses its empty key.
pub fn totp(secret: &str, step: i64) -> Result<String, CryptoError> {
    let mac = hmac(HmacHash::Sha1, &unbase32(secret), &(step as u64).to_be_bytes())?;
    let at = (mac[mac.len() - 1] & 15) as usize;
    let n = (u32::from(mac[at] & 127) << 24)
        | (u32::from(mac[at + 1]) << 16)
        | (u32::from(mac[at + 2]) << 8)
        | u32::from(mac[at + 3]);
    Ok(format!("{:06}", n % 1_000_000))
}

/// The address an authenticator app reads from the QR code.
pub fn otpauth_uri(secret: &str, email: &str, host: &str) -> String {
    let encode = crate::sources::encode_uri_component;
    let label = encode(&format!("Runlight ({host}):{email}"));
    format!(
        "otpauth://totp/{label}?secret={secret}&issuer={}&algorithm=SHA1&digits=6&period=30",
        encode(&format!("Runlight ({host})"))
    )
}

/// Ten one-use recovery codes, like "k7dq-2mfa".
pub fn recovery_codes() -> Vec<String> {
    (0..10)
        .map(|_| {
            let raw = base32(&random_bytes(5)).to_lowercase();
            format!("{}-{}", &raw[..4], &raw[4..8])
        })
        .collect()
}

/// What a recovery code is kept as: SHA-256 of its letters and digits in lower case, so dashes and case do
/// not matter.
pub fn recovery_hash(code: &str) -> String {
    let kept: String = code.chars().filter(char::is_ascii_alphanumeric).map(|c| c.to_ascii_lowercase()).collect();
    hex(&sha256(kept.as_bytes()))
}

/// The time step a code matches, one step either side for clocks that drift, newer than `after`; else `None`.
pub fn match_step(secret: &str, code: &str, now: i64, after: i64) -> Result<Option<i64>, CryptoError> {
    let current = js::floor_div(now, STEP_MS);
    for step in [current, current - 1, current + 1] {
        if step > after && totp(secret, step)? == code {
            return Ok(Some(step));
        }
    }
    Ok(None)
}

/// `/^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/`, with JavaScript's `\s`.
fn is_email(address: &str) -> bool {
    let bad = |c: char| js::is_space(c) || matches!(c, '@' | '<' | '>' | '"');
    let Some((local, domain)) = address.split_once('@') else { return false };
    if local.is_empty() || local.chars().any(bad) || domain.chars().any(bad) {
        return false;
    }
    // A dot with something before it and after it.
    let chars: Vec<char> = domain.chars().collect();
    chars.iter().enumerate().any(|(i, &c)| c == '.' && i > 0 && i + 1 < chars.len())
}

/// Whether a ticket's expiry, read as JavaScript's Number() reads it, is after now.
fn later(expires: &str, now: i64) -> bool {
    js::text_number(expires) > now as f64
}

fn code_hash(code: &str) -> String {
    hex(&sha256(code.as_bytes()))
}

/// `/^[A-Za-z0-9_-]{20,64}$/`.
fn is_invite_code(code: &str) -> bool {
    (20..=64).contains(&code.len()) && code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A password checked against nothing, so a wrong email takes as long as a wrong password. Made when first needed.
static DECOY: OnceCell<String> = OnceCell::const_new();

/// Runs slow work, hashing a password, off the async runtime's threads, as Node runs scrypt off its event loop.
async fn slow<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    match tokio::task::spawn_blocking(f).await {
        Ok(value) => value,
        Err(error) => std::panic::resume_unwind(error.into_panic()),
    }
}

async fn hash_slowly(password: &str) -> String {
    let password = password.to_string();
    slow(move || hash_password(&password)).await
}

async fn check_slowly(password: &str, stored: &str) -> bool {
    let (password, stored) = (password.to_string(), stored.to_string());
    slow(move || check_password(&password, &stored)).await
}

/// The accounts on a store, signed with the install's secret.
pub struct Accounts {
    store: SqlStore,
    secret: String,
    ready: Mutex<bool>,
    /// Changes to who has an account take turns in this process, and across processes through the database's lock.
    queue: Mutex<()>,
    /// One second-factor check at a time per account.
    checking: StdMutex<HashMap<String, Arc<Mutex<()>>>>,
}

impl Accounts {
    /// Accounts on a store, with the secret that signs sessions and seals two-factor secrets.
    pub fn new(store: SqlStore, secret: impl Into<String>) -> Accounts {
        Accounts {
            store,
            secret: secret.into(),
            ready: Mutex::new(false),
            queue: Mutex::new(()),
            checking: StdMutex::new(HashMap::new()),
        }
    }

    /// Changes to who has an account take turns, in this process and, on Postgres and MySQL, across processes, so
    /// two owners demoting each other at once cannot leave none, and a double-clicked invite makes one.
    async fn turn<T, F, Fut>(&self, f: F) -> R<T>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = R<T>>,
    {
        let _turn = self.queue.lock().await;
        let held = self.store.db().hold(Hold::Exclusive).await?;
        let result = f().await;
        let finished = held.finish(result.is_ok()).await;
        let value = result?;
        finished?;
        Ok(value)
    }

    async fn init(&self) -> R<()> {
        let mut ready = self.ready.lock().await;
        if *ready {
            return Ok(());
        }
        // Several processes starting at once create the tables one at a time.
        let held = self.store.db().hold(Hold::Exclusive).await?;
        let result = self.create().await;
        let finished = held.finish(result.is_ok()).await;
        result?;
        finished?;
        *ready = true;
        Ok(())
    }

    async fn create(&self) -> R<()> {
        let db = self.store.db();
        // MySQL keys TEXT only by a prefix, so there the keyed columns are VARCHAR, in the binary collation the store's tables use.
        let my = db.dialect() == Dialect::Mysql;
        let str = |n: u32| if my { format!("VARCHAR({n})") } else { "TEXT".to_string() };
        let table = if my { format!(" DEFAULT CHARSET=utf8mb4 COLLATE={MYSQL_COLLATION}") } else { String::new() };
        db.run(
            &format!(
                "CREATE TABLE IF NOT EXISTS rl_users (id {} PRIMARY KEY, email {} NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL){table}",
                str(100),
                str(320)
            ),
            params![],
        )
        .await?;
        // Roles came later; a table from before them gains the column, and its accounts stay owners.
        let columns = if db.dialect() == Dialect::Sqlite {
            db.all("PRAGMA table_info(rl_users)", params![]).await?
        } else {
            db.all(
                &format!(
                    "SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = {}",
                    if my { "DATABASE()" } else { "current_schema()" }
                ),
                params![],
            )
            .await?
        };
        let names: Vec<String> =
            columns.iter().map(|c| if c.is_null("name") { c.text_or("NAME", "") } else { c.text("name") }).collect();
        let has = |name: &str| names.iter().any(|n| n == name);
        if !has("role") {
            db.run(&format!("ALTER TABLE rl_users ADD COLUMN role {} NOT NULL DEFAULT 'owner'", str(20)), params![])
                .await?;
        }
        // Two-factor came later still: the secret (sealed), one being set up, recovery code hashes, and the last code's step.
        for (name, kind) in
            [("totp_secret", "TEXT"), ("totp_pending", "TEXT"), ("totp_recovery", "TEXT"), ("totp_step", "BIGINT")]
        {
            if !has(name) {
                db.run(&format!("ALTER TABLE rl_users ADD COLUMN {name} {kind}"), params![]).await?;
            }
        }
        db.run(
            &format!(
                "CREATE TABLE IF NOT EXISTS rl_invites (id {} PRIMARY KEY, email {} NOT NULL UNIQUE, role {} NOT NULL, code_hash {} NOT NULL UNIQUE, invited_by {} NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL){table}",
                str(100),
                str(320),
                str(20),
                str(128),
                str(100)
            ),
            params![],
        )
        .await?;
        // A server has one owner. One from before, with several, keeps the first and the rest become admins,
        // who can still do everything but remove the owner. Invites to join as an owner become invites as an admin.
        let owners = db.all("SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id", params![]).await?;
        for extra in owners.iter().skip(1) {
            db.run("UPDATE rl_users SET role = 'admin' WHERE id = ?", params![extra.text("id")]).await?;
        }
        db.run("UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'", params![]).await?;
        Ok(())
    }

    /// The recovery code hashes stored on a row.
    fn recovery_of(r: &Row) -> R<Vec<Value>> {
        if !js::truthy(&r.get("totp_recovery").to_value()) {
            return Ok(vec![]);
        }
        let parsed = js::parse(&r.text("totp_recovery")).map_err(|e| AuthError::Stored(e.to_string()))?;
        Ok(parsed.as_array().cloned().unwrap_or_default())
    }

    fn row(r: &Row) -> R<User> {
        Ok(User {
            id: r.text("id"),
            email: r.text("email"),
            hash: r.text("hash"),
            role: role_of(r, "role"),
            created_at: r.int("created_at"),
            two_factor: js::truthy(&r.get("totp_secret").to_value()),
            recovery_left: Self::recovery_of(r)?.len(),
        })
    }

    /// Seals a two-factor secret with the install's secret, so the database alone cannot make codes.
    fn seal(&self, text: &str) -> String {
        seal_text(text, &self.secret)
    }

    fn unseal(&self, sealed: &str) -> Option<String> {
        unseal_text(sealed, &self.secret)
    }

    /// Starts turning on two-factor: a new secret, kept aside until a code from it is confirmed.
    pub async fn start_two_factor(&self, id: &str) -> R<String> {
        self.init().await?;
        let secret = base32(&random_bytes(20));
        self.store
            .db()
            .run("UPDATE rl_users SET totp_pending = ? WHERE id = ?", params![self.seal(&secret), id])
            .await?;
        Ok(secret)
    }

    /// Turns two-factor on once a code from the new secret checks out, and returns ten recovery codes, shown once.
    pub async fn confirm_two_factor(&self, id: &str, code: &str, now: i64) -> R<Option<Vec<String>>> {
        self.init().await?;
        let rows = self.store.db().all("SELECT totp_pending FROM rl_users WHERE id = ?", params![id]).await?;
        let secret = match rows.first() {
            Some(row) if js::truthy(&row.get("totp_pending").to_value()) => self.unseal(&row.text("totp_pending")),
            _ => None,
        };
        let Some(secret) = secret.filter(|s| !s.is_empty()) else { return Ok(None) };
        if match_step(&secret, code, now, -1)?.is_none() {
            return Ok(None);
        }
        let recovery = recovery_codes();
        // The code that turned it on is not marked used, so signing in again at once with it works.
        self.store
            .db()
            .run(
                "UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?",
                params![self.seal(&secret), hashes_json(&recovery), id],
            )
            .await?;
        Ok(Some(recovery))
    }

    /// New recovery codes in place of the old ones.
    pub async fn new_recovery_codes(&self, id: &str) -> R<Vec<String>> {
        self.init().await?;
        let recovery = recovery_codes();
        self.store
            .db()
            .run("UPDATE rl_users SET totp_recovery = ? WHERE id = ?", params![hashes_json(&recovery), id])
            .await?;
        Ok(recovery)
    }

    /// Drops a set-up left half done, after too many wrong codes, so it must start again with the password.
    pub async fn cancel_two_factor_setup(&self, id: &str) -> R<()> {
        self.init().await?;
        self.store.db().run("UPDATE rl_users SET totp_pending = NULL WHERE id = ?", params![id]).await?;
        Ok(())
    }

    /// Turns two-factor off.
    pub async fn disable_two_factor(&self, id: &str) -> R<()> {
        self.init().await?;
        self.store
            .db()
            .run(
                "UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?",
                params![id],
            )
            .await?;
        Ok(())
    }

    /// Checks a six-digit code, or a recovery code, for an account with two-factor on.
    /// A code works once: one already used, or older, is refused, and a recovery code is crossed off.
    pub async fn check_second_factor(&self, id: &str, code: &str, now: i64) -> R<bool> {
        // One check at a time per account, so two sign-ins at once cannot both use the same code.
        let lock = self.checking.lock().expect("the checks").entry(id.to_string()).or_default().clone();
        let result = {
            let _turn = lock.lock().await;
            self.check_second_factor_now(id, code, now).await
        };
        let mut checking = self.checking.lock().expect("the checks");
        // Nobody else waiting: the map and this hold the only two.
        if checking.get(id).is_some_and(|l| Arc::ptr_eq(l, &lock) && Arc::strong_count(l) == 2) {
            checking.remove(id);
        }
        result
    }

    async fn check_second_factor_now(&self, id: &str, code: &str, now: i64) -> R<bool> {
        self.init().await?;
        let rows = self
            .store
            .db()
            .all("SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?", params![id])
            .await?;
        let Some(row) = rows.first() else { return Ok(false) };
        if !js::truthy(&row.get("totp_secret").to_value()) {
            return Ok(false);
        }
        let given = js::trim(code);
        let digits: String = given.chars().filter(|&c| !js::is_space(c)).collect();
        if digits.len() == 6 && digits.bytes().all(|b| b.is_ascii_digit()) {
            let Some(secret) = self.unseal(&row.text("totp_secret")).filter(|s| !s.is_empty()) else {
                return Ok(false);
            };
            let after = row.opt_int("totp_step").unwrap_or(-1);
            let Some(step) = match_step(&secret, &digits, now, after)? else { return Ok(false) };
            self.store.db().run("UPDATE rl_users SET totp_step = ? WHERE id = ?", params![step, id]).await?;
            return Ok(true);
        }
        let mut hashes = Self::recovery_of(row)?;
        let wanted = Value::String(recovery_hash(given));
        let Some(at) = hashes.iter().position(|h| *h == wanted) else { return Ok(false) };
        hashes.remove(at);
        self.store
            .db()
            .run(
                "UPDATE rl_users SET totp_recovery = ? WHERE id = ?",
                params![js::stringify(&Value::Array(hashes)), id],
            )
            .await?;
        Ok(true)
    }

    /// A short-lived ticket naming an account whose password checked out and
    /// which still owes a code. Signed like a session, so it cannot be made up.
    pub fn pending_for(&self, user: &User, now: i64) -> R<String> {
        self.ticket("pending", user, now + 5 * 60_000)
    }

    /// A ticket that looks and acts like pending_for's, except that no code ever
    /// passes with it. A wrong password gets one once an account with
    /// two-factor has had too many, so the answer never tells a right password.
    pub fn decoy_for(&self, user: &User, now: i64) -> R<String> {
        self.ticket("decoy", user, now + 5 * 60_000)
    }

    /// The account a code-step ticket names, and whether a right code may sign in with it.
    pub async fn from_pending(&self, value: &str, now: i64) -> R<Option<Pending>> {
        if let Some(user) = self.ticket_user("pending", value, now).await? {
            return Ok(Some(Pending { user, real: true }));
        }
        Ok(self.ticket_user("decoy", value, now).await?.map(|user| Pending { user, real: false }))
    }

    /// A ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it.
    pub fn link_for(&self, user: &User, now: i64) -> R<String> {
        self.ticket("link", user, now + 15 * 60_000)
    }

    /// The account a sign-in link is for. A link works once: using it withdraws it, and every link sent
    /// before it. Uses take turns, so a link opened twice at once lets one in.
    pub async fn from_link(&self, value: &str, now: i64) -> R<Option<User>> {
        let Some(user) = self.ticket_user("link", value, now).await? else { return Ok(None) };
        let expires = js::text_number(value.split('.').nth(1).unwrap_or(""));
        self.turn(|| async {
            let key = format!("login-link-used:{}", user.id);
            let used = self.store.setting(&key).await?.map_or(0.0, |v| js::text_number(&v));
            if expires <= used {
                return Ok(None);
            }
            self.store.set_setting(&key, Some(&js::format_number(expires))).await?;
            Ok(Some(user))
        })
        .await
    }

    fn ticket(&self, kind: &str, user: &User, expires: i64) -> R<String> {
        let body = format!("{}.{expires}", user.id);
        Ok(format!("{body}.{}", self.sign(&format!("{kind}.{body}"), &user.hash)?))
    }

    async fn ticket_user(&self, kind: &str, value: &str, now: i64) -> R<Option<User>> {
        let mut parts = value.split('.');
        let (id, expires, signature) =
            (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
        if id.is_empty() || expires.is_empty() || signature.is_empty() || !later(expires, now) {
            return Ok(None);
        }
        let Some(user) = self.by_id(id).await? else { return Ok(None) };
        Ok(if same_text(&self.sign(&format!("{kind}.{id}.{expires}"), &user.hash)?, signature) {
            Some(user)
        } else {
            None
        })
    }

    /// How many accounts there are.
    pub async fn count(&self) -> R<i64> {
        self.init().await?;
        let rows = self.store.db().all("SELECT COUNT(*) AS n FROM rl_users", params![]).await?;
        Ok(rows.first().map_or(0, |r| r.int("n")))
    }

    /// The account with an email address, trimmed and in any case.
    pub async fn by_email(&self, email: &str) -> R<Option<User>> {
        self.init().await?;
        let rows = self
            .store
            .db()
            .all("SELECT * FROM rl_users WHERE email = ?", params![js::trim(email).to_lowercase()])
            .await?;
        rows.first().map(Self::row).transpose()
    }

    /// The account with an id.
    pub async fn by_id(&self, id: &str) -> R<Option<User>> {
        self.init().await?;
        let rows = self.store.db().all("SELECT * FROM rl_users WHERE id = ?", params![id]).await?;
        rows.first().map(Self::row).transpose()
    }

    /// Every account, oldest first.
    pub async fn list(&self) -> R<Vec<User>> {
        self.init().await?;
        self.store
            .db()
            .all("SELECT * FROM rl_users ORDER BY created_at, id", params![])
            .await?
            .iter()
            .map(Self::row)
            .collect()
    }

    async fn find(&self, id: &str) -> R<Option<User>> {
        Ok(self.list().await?.into_iter().find(|u| u.id == id))
    }

    /// Changes a role. The owner's never changes here, and nobody becomes the owner here: see hand_over().
    pub async fn set_role(&self, id: &str, role: Role) -> R<User> {
        // The tables first: making them takes the same lock as a turn.
        self.init().await?;
        self.turn(|| async {
            let Some(user) = self.find(id).await? else {
                return Err(AccountError::new("Unknown account", "unknown_account", &[]).into());
            };
            if user.role == Role::Owner {
                return Err(AccountError::new(
                    "Only the owner can change their own role, by handing ownership to an admin",
                    "owner_protected",
                    &[],
                )
                .into());
            }
            if role == Role::Owner {
                return Err(AccountError::new("Ownership is handed over by the owner", "owner_hand_over", &[]).into());
            }
            self.store.db().run("UPDATE rl_users SET role = ? WHERE id = ?", params![role.as_str(), id]).await?;
            Ok(User { role, ..user })
        })
        .await
    }

    /// Makes an admin the owner, and the owner an admin.
    pub async fn hand_over(&self, from: &str, to: &str) -> R<()> {
        self.init().await?;
        self.turn(|| async {
            let users = self.list().await?;
            let owner = users.iter().find(|u| u.id == from);
            let next = users.iter().find(|u| u.id == to);
            if owner.is_none_or(|o| o.role != Role::Owner) {
                return Err(AccountError::new("Only the owner can hand over ownership", "owner_hand_over", &[]).into());
            }
            let Some(next) = next else {
                return Err(AccountError::new("Unknown account", "unknown_account", &[]).into());
            };
            if next.role != Role::Admin {
                return Err(AccountError::new("Make them an admin first", "owner_needs_admin", &[]).into());
            }
            self.store.db().run("UPDATE rl_users SET role = 'owner' WHERE id = ?", params![to]).await?;
            self.store.db().run("UPDATE rl_users SET role = 'admin' WHERE id = ?", params![from]).await?;
            Ok(())
        })
        .await
    }

    /// Removes an account. The owner cannot be removed.
    pub async fn remove(&self, id: &str) -> R<()> {
        // The tables first: making them takes the same lock as a turn.
        self.init().await?;
        self.turn(|| async {
            let Some(user) = self.find(id).await? else {
                return Err(AccountError::new("Unknown account", "unknown_account", &[]).into());
            };
            if user.role == Role::Owner {
                return Err(AccountError::new("The owner cannot be removed", "owner_protected", &[]).into());
            }
            self.store.db().run("DELETE FROM rl_users WHERE id = ?", params![id]).await?;
            self.store.set_setting(&format!("login-link-used:{id}"), None).await?;
            Ok(())
        })
        .await
    }

    /// Makes an account, or sets a new password on an existing one. A new account is the owner when it is the first,
    /// and otherwise an admin unless a role is given, since a server has one owner.
    pub async fn set_password(&self, email: &str, password: &str, now: i64, role: Option<Role>) -> R<User> {
        self.init().await?;
        let address = js::trim(email).to_lowercase();
        if !is_email(&address) {
            return Err(AccountError::new("Enter an email address", "email_invalid", &[]).into());
        }
        if js::len16(password) < MIN_PASSWORD {
            let min = MIN_PASSWORD.to_string();
            return Err(AccountError::new(
                format!("Use a password of at least {MIN_PASSWORD} characters"),
                "password_short",
                &[("min", &min)],
            )
            .into());
        }
        let hash = hash_slowly(password).await;
        if let Some(existing) = self.by_email(&address).await? {
            self.store.db().run("UPDATE rl_users SET hash = ? WHERE id = ?", params![&hash, &existing.id]).await?;
            return Ok(User { hash, ..existing });
        }
        let first = self.count().await? == 0;
        let given = role.unwrap_or(if first { Role::Owner } else { Role::Admin });
        let user = User {
            id: hex(&random_bytes(12)),
            email: address,
            hash,
            role: if given == Role::Owner && !first { Role::Admin } else { given },
            created_at: now,
            two_factor: false,
            recovery_left: 0,
        };
        self.store
            .db()
            .run(
                "INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)",
                params![&user.id, &user.email, &user.hash, user.role.as_str(), user.created_at],
            )
            .await?;
        Ok(user)
    }

    fn invite_row(r: &Row) -> Invite {
        Invite {
            id: r.text("id"),
            email: r.text("email"),
            role: role_of(r, "role"),
            invited_by: r.text("invited_by"),
            created_at: r.int("created_at"),
            expires_at: r.int("expires_at"),
        }
    }

    /// Invites that still work, newest first. Expired ones are cleared on the way.
    pub async fn invites(&self, now: i64) -> R<Vec<Invite>> {
        self.init().await?;
        self.store.db().run("DELETE FROM rl_invites WHERE expires_at <= ?", params![now]).await?;
        let rows = self.store.db().all("SELECT * FROM rl_invites ORDER BY created_at DESC, id", params![]).await?;
        Ok(rows.iter().map(Self::invite_row).collect())
    }

    /// Invites someone to join with a role, and returns the code for their link.
    /// Asking again replaces the earlier invite, so only the newest link works.
    pub async fn invite(&self, email: &str, role: Role, invited_by: &str, now: i64) -> R<NewInvite> {
        self.init().await?;
        self.turn(|| self.invite_now(email, role, invited_by, now)).await
    }

    async fn invite_now(&self, email: &str, role: Role, invited_by: &str, now: i64) -> R<NewInvite> {
        let address = js::trim(email).to_lowercase();
        if !is_email(&address) {
            return Err(AccountError::new("Enter an email address", "email_invalid", &[]).into());
        }
        if self.by_email(&address).await?.is_some() {
            return Err(AccountError::new(
                format!("{address} already has an account"),
                "account_exists",
                &[("email", &address)],
            )
            .into());
        }
        let code = base64url(&random_bytes(24));
        let invite = Invite {
            id: hex(&random_bytes(12)),
            email: address,
            role,
            invited_by: invited_by.to_string(),
            created_at: now,
            expires_at: now + INVITE_MS,
        };
        self.store.db().run("DELETE FROM rl_invites WHERE email = ?", params![&invite.email]).await?;
        self.store
            .db()
            .run(
                "INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                params![
                    &invite.id,
                    &invite.email,
                    invite.role.as_str(),
                    code_hash(&code),
                    &invite.invited_by,
                    invite.created_at,
                    invite.expires_at
                ],
            )
            .await?;
        Ok(NewInvite { invite, code })
    }

    /// The invite a link's code belongs to, while it still works.
    pub async fn invite_by_code(&self, code: &str, now: i64) -> R<Option<Invite>> {
        self.init().await?;
        if !is_invite_code(code) {
            return Ok(None);
        }
        let rows = self
            .store
            .db()
            .all("SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?", params![code_hash(code), now])
            .await?;
        Ok(rows.first().map(Self::invite_row))
    }

    /// Withdraws an invite; false when there was none by that id.
    pub async fn cancel_invite(&self, id: &str) -> R<bool> {
        self.init().await?;
        let before = self.store.db().all("SELECT id FROM rl_invites WHERE id = ?", params![id]).await?.len();
        self.store.db().run("DELETE FROM rl_invites WHERE id = ?", params![id]).await?;
        Ok(before > 0)
    }

    /// Turns an invite into an account with the password its person chose. The link then stops working.
    pub async fn accept_invite(&self, code: &str, password: &str, now: i64) -> R<User> {
        let Some(invite) = self.invite_by_code(code, now).await? else {
            return Err(AccountError::new(
                "This invite has expired or was already used. Ask for a new one.",
                "invite_gone",
                &[],
            )
            .into());
        };
        if self.by_email(&invite.email).await?.is_some() {
            return Err(AccountError::new(
                format!("{} already has an account", invite.email),
                "account_exists",
                &[("email", &invite.email)],
            )
            .into());
        }
        let user = self.set_password(&invite.email, password, now, Some(invite.role)).await?;
        self.store.db().run("DELETE FROM rl_invites WHERE id = ?", params![&invite.id]).await?;
        Ok(user)
    }

    /// The account for an email and password, or `None`. Takes the same time either way.
    pub async fn sign_in(&self, email: &str, password: &str) -> R<Option<User>> {
        let Some(user) = self.by_email(email).await? else {
            let decoy = DECOY.get_or_init(|| async { hash_slowly(&hex(&random_bytes(16))).await }).await;
            check_slowly(password, decoy).await;
            return Ok(None);
        };
        Ok(if check_slowly(password, &user.hash).await { Some(user) } else { None })
    }

    /// A cookie value naming the user and when it expires, signed with the
    /// server's secret and the user's password hash, so changing a password
    /// signs out every other browser.
    pub fn session_for(&self, user: &User, now: i64) -> R<String> {
        let expires = now + SESSION_MS;
        let body = format!("{}.{expires}", user.id);
        Ok(format!("{body}.{}", self.sign(&body, &Self::session_key(user))?))
    }

    /// The signed-in user for a cookie value, or `None`.
    pub async fn from_session(&self, value: &str, now: i64) -> R<Option<User>> {
        let mut parts = value.split('.');
        let (id, expires, signature) =
            (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
        if id.is_empty() || expires.is_empty() || signature.is_empty() || !later(expires, now) {
            return Ok(None);
        }
        let Some(user) = self.by_id(id).await? else { return Ok(None) };
        Ok(if same_text(&self.sign(&format!("{id}.{expires}"), &Self::session_key(&user))?, signature) {
            Some(user)
        } else {
            None
        })
    }

    /// What a session is signed with: the password hash, and whether two-factor is on, so changing either ends other sessions.
    fn session_key(user: &User) -> String {
        format!("{}{}", user.hash, if user.two_factor { ".2fa" } else { "" })
    }

    /// A long-lived mark for a browser that signed in to an account. With it, failed tries by others
    /// against that account cannot lock this browser out; the per-address limit still applies.
    /// A new password withdraws it.
    pub fn device_for(&self, user: &User) -> R<String> {
        Ok(format!("{}.{}", user.id, self.sign(&format!("device.{}", user.id), &user.hash)?))
    }

    /// Whether a device mark is this account's, made since its password last changed.
    pub fn trusts_device(&self, value: &str, user: &User) -> R<bool> {
        let mut parts = value.split('.');
        let (id, signature) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
        if id != user.id || signature.is_empty() {
            return Ok(false);
        }
        Ok(same_text(&self.sign(&format!("device.{}", user.id), &user.hash)?, signature))
    }

    fn sign(&self, body: &str, hash: &str) -> R<String> {
        Ok(base64url(&hmac(HmacHash::Sha256, self.secret.as_bytes(), format!("{body}.{hash}").as_bytes())?))
    }
}

/// Recovery codes as the JSON array of their hashes that is stored.
fn hashes_json(codes: &[String]) -> String {
    js::stringify(&Value::Array(codes.iter().map(|c| Value::String(recovery_hash(c))).collect()))
}

#[derive(Clone, Copy)]
struct Failures {
    count: u32,
    until: i64,
    /// Where the key stands in the order it was first counted, as a JavaScript Map keeps it.
    order: u64,
}

#[derive(Default)]
struct ThrottleState {
    failures: HashMap<String, Failures>,
    order: BTreeMap<u64, String>,
    next: u64,
}

impl ThrottleState {
    fn delete(&mut self, id: &str) {
        if let Some(entry) = self.failures.remove(id) {
            self.order.remove(&entry.order);
        }
    }

    fn insert(&mut self, id: &str, count: u32, until: i64) {
        self.next += 1;
        self.order.insert(self.next, id.to_string());
        self.failures.insert(id.to_string(), Failures { count, until, order: self.next });
    }
}

/// Counts failed sign-ins under a key and refuses more than a few in a while.
/// Keys are hashed with a key made at start, so the map never holds an
/// address or an email as it was given.
pub struct Throttle {
    state: StdMutex<ThrottleState>,
    salt: Vec<u8>,
    limit: u32,
    window_ms: i64,
}

impl Default for Throttle {
    /// Ten tries in fifteen minutes.
    fn default() -> Throttle {
        Throttle::new(10, 15 * 60_000)
    }
}

impl Throttle {
    /// A throttle allowing `limit` tries in `window_ms`.
    pub fn new(limit: u32, window_ms: i64) -> Throttle {
        Throttle { state: StdMutex::new(ThrottleState::default()), salt: random_bytes(16), limit, window_ms }
    }

    fn id(&self, key: &str) -> String {
        let mac = hmac(HmacHash::Sha256, &self.salt, key.as_bytes()).expect("a sixteen-byte key");
        base64url(&mac)[..22].to_string()
    }

    fn state(&self) -> std::sync::MutexGuard<'_, ThrottleState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Whether a key is at its limit.
    pub fn blocked(&self, key: &str, now: i64) -> bool {
        let id = self.id(key);
        self.is_blocked(&self.state(), &id, now)
    }

    fn is_blocked(&self, state: &ThrottleState, id: &str, now: i64) -> bool {
        match state.failures.get(id) {
            Some(entry) if entry.until > now => entry.count >= self.limit,
            _ => false,
        }
    }

    /// Counts a try before the slow check it guards, so a burst that arrives
    /// while earlier tries are still being checked cannot get past the limit.
    /// False, counting nothing, when the key is already at its limit. A try
    /// that turns out right is taken back with forgive(). The check and the
    /// count happen with nothing in between.
    pub fn take(&self, key: &str, now: i64) -> bool {
        let id = self.id(key);
        let mut state = self.state();
        if self.is_blocked(&state, &id, now) {
            return false;
        }
        self.count(&mut state, &id, now);
        true
    }

    /// Takes back one counted try, for one that turned out right.
    pub fn forgive(&self, key: &str) {
        let id = self.id(key);
        if let Some(entry) = self.state().failures.get_mut(&id)
            && entry.count > 0
        {
            entry.count -= 1;
        }
    }

    /// Counts a failed try.
    pub fn fail(&self, key: &str, now: i64) {
        let id = self.id(key);
        self.count(&mut self.state(), &id, now);
    }

    fn count(&self, state: &mut ThrottleState, id: &str, now: i64) {
        match state.failures.get_mut(id) {
            Some(entry) if entry.until > now => entry.count += 1,
            _ => {
                state.delete(id);
                state.insert(id, 1, now + self.window_ms);
            }
        }
        // Expired entries go first, then the oldest that are not blocked, and blocked ones last, so the map
        // has a hard ceiling and a flood of made-up names cannot wipe out a real block.
        if state.failures.len() > MAX_THROTTLED {
            let expired: Vec<String> =
                state.failures.iter().filter(|(_, v)| v.until <= now).map(|(k, _)| k.clone()).collect();
            for k in expired {
                state.delete(&k);
            }
            let ordered: Vec<String> = state.order.values().cloned().collect();
            for k in &ordered {
                if state.failures.len() <= MAX_THROTTLED {
                    break;
                }
                if state.failures.get(k).is_some_and(|v| v.count < self.limit) {
                    state.delete(k);
                }
            }
            let ordered: Vec<String> = state.order.values().cloned().collect();
            for k in &ordered {
                if state.failures.len() <= MAX_THROTTLED {
                    break;
                }
                state.delete(k);
            }
        }
    }

    /// Forgets a key's tries.
    pub fn clear(&self, key: &str) {
        let id = self.id(key);
        self.state().delete(&id);
    }

    /// How many keys it remembers, for tests of its ceiling.
    #[doc(hidden)]
    pub fn size(&self) -> usize {
        self.state().failures.len()
    }
}
