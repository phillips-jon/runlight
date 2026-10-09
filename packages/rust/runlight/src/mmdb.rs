//! A reader for MaxMind DB files (the MMDB format that MaxMind's GeoLite2
//! and DB-IP's free databases use), so location needs no other crate. It
//! answers what the TypeScript server's mmdb-lib answers: the record for an
//! address as a JSON value, or `None` when the address is not in the
//! database.
//!
//! A database opened from a file is read a page at a time as lookups need
//! it, so a 130 MB city database costs each lookup a few hundred kilobytes
//! of reads.
//!
//! Format: <https://maxmind.github.io/MaxMind-DB/>

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::net::IpAddr;
use std::sync::Mutex;

use crate::geo::{Found, GeoLookup};
use crate::js::{self, Object, Value};
use crate::{BoxError, BoxFuture};

const METADATA_MARKER: &[u8] = b"\xAB\xCD\xEFMaxMind.com";
/// The metadata sits in the file's last 128 KiB.
const METADATA_MAX: u64 = 131_072;
const PAGE: u64 = 4096;
/// Pages kept from a file at once; a lookup reads a few dozen.
const PAGES_KEPT: usize = 256;

enum Source {
    Bytes(Vec<u8>),
    File(Mutex<(File, HashMap<u64, Vec<u8>>)>),
}

/// An MMDB database.
pub struct Mmdb {
    source: Source,
    size: u64,
    /// The database's metadata.
    pub metadata: Value,
    node_count: u64,
    record_size: u64,
    node_bytes: u64,
    data_start: u64,
    ipv4_start: Mutex<Option<u64>>,
}

/// A database that could not be read.
#[derive(Debug)]
pub struct MmdbError(pub String);

impl std::fmt::Display for MmdbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for MmdbError {}

fn bad(what: &str) -> MmdbError {
    MmdbError(what.to_string())
}

impl Mmdb {
    /// A database held in memory.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Mmdb, MmdbError> {
        let size = bytes.len() as u64;
        Mmdb::with(Source::Bytes(bytes), size)
    }

    /// A database read from its file as lookups need it.
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Mmdb, MmdbError> {
        let path = path.as_ref();
        let file = File::open(path).map_err(|_| MmdbError(format!("Could not read {}", path.display())))?;
        let size = file.metadata().map_err(|e| MmdbError(e.to_string()))?.len();
        Mmdb::with(Source::File(Mutex::new((file, HashMap::new()))), size)
    }

    fn with(source: Source, size: u64) -> Result<Mmdb, MmdbError> {
        let mut db = Mmdb {
            source,
            size,
            metadata: Value::Null,
            node_count: 0,
            record_size: 0,
            node_bytes: 0,
            data_start: 0,
            ipv4_start: Mutex::new(None),
        };
        let tail_start = size.saturating_sub(METADATA_MAX);
        let tail = db.read(tail_start, size - tail_start)?;
        let at = tail
            .windows(METADATA_MARKER.len())
            .rposition(|w| w == METADATA_MARKER)
            .ok_or_else(|| bad("Not a MaxMind DB file: no metadata"))?;
        let start = tail_start + at as u64 + METADATA_MARKER.len() as u64;
        let (metadata, _) = db.decode(start, start, 0)?;
        let num = |k: &str| metadata.get(k).and_then(Value::as_f64);
        let (Some(nodes), Some(record), Some(_)) = (num("node_count"), num("record_size"), num("ip_version")) else {
            return Err(bad("Not a MaxMind DB file: bad metadata"));
        };
        if ![24.0, 28.0, 32.0].contains(&record) {
            return Err(MmdbError(format!("Unsupported record size {record}")));
        }
        db.node_count = nodes as u64;
        db.record_size = record as u64;
        db.node_bytes = db.record_size / 4;
        db.data_start = db.node_count * db.node_bytes + 16;
        db.metadata = metadata;
        Ok(db)
    }

    fn ip_version(&self) -> u64 {
        self.metadata.get("ip_version").and_then(Value::as_f64).unwrap_or(0.0) as u64
    }

    /// `length` bytes from `at`, fewer at the end of the database.
    fn read(&self, at: u64, length: u64) -> Result<Vec<u8>, MmdbError> {
        let end = (at + length).min(self.size);
        match &self.source {
            Source::Bytes(b) => Ok(b.get(at as usize..end as usize).unwrap_or(&[]).to_vec()),
            Source::File(file) => {
                let mut guard = file.lock().unwrap_or_else(|e| e.into_inner());
                let (handle, pages) = &mut *guard;
                let mut out = Vec::new();
                let mut at = at;
                while at < end {
                    let number = at / PAGE;
                    if !pages.contains_key(&number) {
                        if pages.len() >= PAGES_KEPT {
                            pages.clear();
                        }
                        let mut page = Vec::with_capacity(PAGE as usize);
                        handle.seek(SeekFrom::Start(number * PAGE)).map_err(|e| MmdbError(e.to_string()))?;
                        handle.by_ref().take(PAGE).read_to_end(&mut page).map_err(|e| MmdbError(e.to_string()))?;
                        pages.insert(number, page);
                    }
                    let page = &pages[&number];
                    let offset = (at - number * PAGE) as usize;
                    let take = ((end - at) as usize).min(page.len().saturating_sub(offset));
                    if take == 0 {
                        break;
                    }
                    out.extend_from_slice(&page[offset..offset + take]);
                    at += take as u64;
                }
                Ok(out)
            }
        }
    }

    fn byte(&self, at: u64) -> Result<u64, MmdbError> {
        self.read(at, 1)?.first().map(|b| u64::from(*b)).ok_or_else(|| bad("Invalid MaxMind DB: read past the end"))
    }

    /// The record for an address, or `None`. An error for text that is not
    /// an IP address, or an IPv6 address in an IPv4-only database.
    pub fn get(&self, ip: &str) -> Result<Option<Value>, MmdbError> {
        let address: IpAddr = ip.parse().map_err(|_| MmdbError(format!("Not an IP address: {ip}")))?;
        let packed: Vec<u8> = match address {
            IpAddr::V4(a) => a.octets().to_vec(),
            IpAddr::V6(a) => a.octets().to_vec(),
        };
        let v6 = packed.len() == 16;
        if v6 && self.ip_version() == 4 {
            return Err(MmdbError(format!("An IPv6 address cannot be looked up in an IPv4-only database: {ip}")));
        }
        let mut node = if v6 || self.ip_version() == 4 { 0 } else { self.ipv4_start()? };
        let bits = packed.len() * 8;
        let mut i = 0;
        while i < bits && node < self.node_count {
            let bit = (packed[i >> 3] >> (7 - (i & 7))) & 1;
            node = self.record(node, u64::from(bit))?;
            i += 1;
        }
        // The node count itself means no record, and so does a tree that ends before the address does.
        if node <= self.node_count {
            return Ok(None);
        }
        let (value, _) = self.decode(self.data_start + node - self.node_count - 16, self.data_start, 0)?;
        Ok(Some(value))
    }

    /// IPv4 addresses live under ::/96 in an IPv6 tree: the node 96 left
    /// turns down.
    fn ipv4_start(&self) -> Result<u64, MmdbError> {
        let mut cached = self.ipv4_start.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = *cached {
            return Ok(n);
        }
        let mut node = 0;
        let mut i = 0;
        while i < 96 && node < self.node_count {
            node = self.record(node, 0)?;
            i += 1;
        }
        *cached = Some(node);
        Ok(node)
    }

    fn record(&self, node: u64, right: u64) -> Result<u64, MmdbError> {
        let b = self.read(node * self.node_bytes, self.node_bytes)?;
        if (b.len() as u64) < self.node_bytes {
            return Err(bad("Invalid MaxMind DB: read past the end"));
        }
        let b: Vec<u64> = b.into_iter().map(u64::from).collect();
        Ok(match self.record_size {
            24 => {
                let at = (right * 3) as usize;
                (b[at] << 16) | (b[at + 1] << 8) | b[at + 2]
            }
            28 => {
                if right == 0 {
                    ((b[3] & 0xF0) << 20) | (b[0] << 16) | (b[1] << 8) | b[2]
                } else {
                    ((b[3] & 0x0F) << 24) | (b[4] << 16) | (b[5] << 8) | b[6]
                }
            }
            _ => {
                let at = (right * 4) as usize;
                (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]
            }
        })
    }

    /// Decodes the value at `at`; pointers are offsets from `base`. Gives
    /// the value and the offset just past it.
    fn decode(&self, at: u64, base: u64, depth: usize) -> Result<(Value, u64), MmdbError> {
        if depth > 64 {
            return Err(bad("Invalid MaxMind DB: nested too deeply"));
        }
        let mut at = at;
        let control = self.byte(at)?;
        at += 1;
        let mut kind = control >> 5;
        if kind == 1 {
            // A pointer: up to four more bytes of offset, then the value found there.
            let ss = (control >> 3) & 3;
            let vvv = control & 7;
            let pointer = match ss {
                0 => (vvv << 8) | self.byte(at)?,
                1 => ((vvv << 16) | (self.byte(at)? << 8) | self.byte(at + 1)?) + 2048,
                2 => ((vvv << 24) | (self.byte(at)? << 16) | (self.byte(at + 1)? << 8) | self.byte(at + 2)?) + 526_336,
                _ => unsigned(&self.read(at, 4)?),
            };
            let (value, _) = self.decode(base + pointer, base, depth + 1)?;
            return Ok((value, at + ss + 1));
        }
        if kind == 0 {
            kind = 7 + self.byte(at)?;
            at += 1;
        }
        let mut size = control & 0x1F;
        if size >= 29 {
            let extra = size - 28;
            let mut n = 0;
            for i in 0..extra {
                n = (n << 8) | self.byte(at + i)?;
            }
            size = match size {
                29 => 29,
                30 => 285,
                _ => 65_821,
            } + n;
            at += extra;
        }
        Ok(match kind {
            2 => (Value::String(String::from_utf8_lossy(&self.read(at, size)?).into_owned()), at + size),
            3 => {
                let b = self.read(at, 8)?;
                let bytes: [u8; 8] = b.try_into().map_err(|_| bad("Invalid MaxMind DB: read past the end"))?;
                (Value::Number(f64::from_be_bytes(bytes)), at + 8)
            }
            4 => (Value::String(String::from_utf8_lossy(&self.read(at, size)?).into_owned()), at + size),
            5 | 6 => (Value::Number(unsigned(&self.read(at, size)?) as f64), at + size),
            7 => {
                let mut map = Object::new();
                for _ in 0..size {
                    let (key, next) = self.decode(at, base, depth + 1)?;
                    let (value, next) = self.decode(next, base, depth + 1)?;
                    map.set(js::js_string(&key), value);
                    at = next;
                }
                (Value::Object(map), at)
            }
            8 => {
                let mut n = unsigned(&self.read(at, size)?) as i64;
                if size == 4 && n >= 0x8000_0000 {
                    n -= 0x1_0000_0000;
                }
                (Value::Number(n as f64), at + size)
            }
            9 | 10 => {
                let bytes = self.read(at, size)?;
                let n = bytes.iter().fold(0u128, |n, b| (n << 8) | u128::from(*b));
                // A number past 2^53 is written as its decimal text.
                let v = if n <= 1u128 << 53 { Value::Number(n as f64) } else { Value::String(n.to_string()) };
                (v, at + size)
            }
            11 => {
                let mut list = Vec::new();
                for _ in 0..size {
                    let (value, next) = self.decode(at, base, depth + 1)?;
                    list.push(value);
                    at = next;
                }
                (Value::Array(list), at)
            }
            14 => (Value::Bool(size != 0), at),
            15 => {
                let b = self.read(at, 4)?;
                let bytes: [u8; 4] = b.try_into().map_err(|_| bad("Invalid MaxMind DB: read past the end"))?;
                (Value::Number(f64::from(f32::from_be_bytes(bytes))), at + 4)
            }
            _ => return Err(MmdbError(format!("Invalid MaxMind DB: unknown data type {kind}"))),
        })
    }
}

fn unsigned(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0u64, |n, b| (n << 8) | u64::from(*b))
}

/// A city as people say it, without a trailing bracketed district.
pub fn city_name(name: &str) -> String {
    let re = crate::re::uni_re!(
        r"[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]*\([^)]*\)[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]*$"
    );
    js::trim(&re.replace(name, "")).to_string()
}

/// What a lookup makes of a database record. DB-IP's records follow
/// MaxMind's city layout, with names but no subdivision codes; a city loses
/// the district DB-IP adds in brackets, as in "Toronto (Old Toronto)". This
/// is the TypeScript server's `lookupFrom`.
pub fn found_in(record: &Value) -> Option<Found> {
    let country = record.get("country").and_then(|c| c.get("iso_code"))?;
    if !js::truthy(country) {
        return None;
    }
    let sub = record.get("subdivisions").and_then(|s| s.as_array()).and_then(|a| a.first());
    let region = sub
        .and_then(|s| s.get("iso_code").filter(|v| !v.is_null()))
        .or_else(|| sub.and_then(|s| s.get("names")).and_then(|n| n.get("en")).filter(|v| !v.is_null()));
    let city = record.get("city").and_then(|c| c.get("names")).and_then(|n| n.get("en")).filter(|v| !v.is_null());
    Some(Found {
        country: Some(js::js_string(country)),
        region: Some(region.map(js::js_string).unwrap_or_default()),
        city: Some(match city {
            Some(Value::String(s)) => city_name(s),
            Some(other) => js::js_string(other),
            None => String::new(),
        }),
    })
}

impl GeoLookup for Mmdb {
    fn lookup<'a>(&'a self, ip: &'a str) -> BoxFuture<'a, Result<Option<Found>, BoxError>> {
        Box::pin(async move {
            Ok(match self.get(ip) {
                Ok(Some(record)) => found_in(&record),
                _ => None,
            })
        })
    }
}
