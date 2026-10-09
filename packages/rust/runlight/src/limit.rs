//! The tracker's rate limit.

use std::collections::HashMap;
use std::sync::Mutex;

use sha2::{Digest, Sha256};

use crate::hash::{hex, random_bytes};

/// Counts tracker requests per address in fixed one-minute windows, in
/// memory. Addresses are hashed with a key made at start, so the map never
/// holds an IP, and the whole map is dropped at the end of each window.
pub struct RateLimit {
    per_minute: f64,
    key: Vec<u8>,
    state: Mutex<(i64, HashMap<String, u64>)>,
}

impl RateLimit {
    /// A limit of `per_minute` requests per address.
    pub fn new(per_minute: f64) -> RateLimit {
        RateLimit { per_minute, key: random_bytes(16), state: Mutex::new((0, HashMap::new())) }
    }

    /// True while this address is under its limit for the current minute.
    pub fn allow(&self, ip: &str, now: i64) -> bool {
        // No address (a bare adapter with no context) cannot be told apart, so it is not limited.
        if ip.is_empty() {
            return true;
        }
        let window = now.div_euclid(60_000);
        let id = self.hash(ip);
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if window != state.0 {
            state.0 = window;
            state.1.clear();
        }
        let count = state.1.entry(id).or_insert(0);
        *count += 1;
        (*count as f64) <= self.per_minute
    }

    fn hash(&self, ip: &str) -> String {
        let mut h = Sha256::new();
        h.update(&self.key);
        h.update(ip.as_bytes());
        hex(&h.finalize()[..8])
    }
}
