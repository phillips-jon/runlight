//! A ZIP file of text files, stored without compression, and CSV rows.

use crate::js::{self, Value};
use crate::re::{js_re, test};

fn crc32(bytes: &[u8]) -> u32 {
    static TABLE: std::sync::LazyLock<[u32; 256]> = std::sync::LazyLock::new(|| {
        let mut t = [0u32; 256];
        for (n, slot) in t.iter_mut().enumerate() {
            let mut c = n as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { 0xedb8_8320 ^ (c >> 1) } else { c >> 1 };
            }
            *slot = c;
        }
        t
    });
    let mut crc = 0xffff_ffffu32;
    for b in bytes {
        crc = TABLE[((crc ^ u32::from(*b)) & 0xff) as usize] ^ (crc >> 8);
    }
    crc ^ 0xffff_ffff
}

/// DOS date and time, as ZIP stores them, for an instant in UTC.
fn dos_time(ms: i64) -> (u16, u16) {
    let days = ms.div_euclid(86_400_000);
    let rest = ms.rem_euclid(86_400_000) / 1000;
    let (y, m, d) = js::civil_from_days(days);
    let time = ((rest / 3600) << 11) | (((rest / 60) % 60) << 5) | ((rest % 60) / 2);
    let day = ((y - 1980) << 9) | (m << 5) | d;
    (time as u16, day as u16)
}

/// A ZIP of text files, stored, dated `now` (epoch milliseconds, UTC).
pub fn zip(files: &[(String, String)], now: i64) -> Vec<u8> {
    let (time, day) = dos_time(now);
    let mut out = Vec::new();
    let mut central = Vec::new();
    for (name, text) in files {
        let name = name.as_bytes();
        let data = text.as_bytes();
        let crc = crc32(data);
        let offset = out.len() as u32;
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&0x0800u16.to_le_bytes()); // names are UTF-8
        out.extend_from_slice(&0u16.to_le_bytes()); // stored
        out.extend_from_slice(&time.to_le_bytes());
        out.extend_from_slice(&day.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(name);
        out.extend_from_slice(data);

        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&0x0800u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&time.to_le_bytes());
        central.extend_from_slice(&day.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&[0u8; 12]);
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name);
    }
    let size = central.len() as u32;
    let offset = out.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0u8; 4]);
    out.extend_from_slice(&(files.len() as u16).to_le_bytes());
    out.extend_from_slice(&(files.len() as u16).to_le_bytes());
    out.extend_from_slice(&size.to_le_bytes());
    out.extend_from_slice(&offset.to_le_bytes());
    out.extend_from_slice(&[0u8; 2]);
    out
}

/// One CSV cell's text from a value, as `String(v)` writes it, null as
/// empty.
pub fn cell(v: &Value) -> String {
    if v.is_null() { String::new() } else { js::js_string(v) }
}

/// One CSV row, quoting what needs it; a leading =, +, -, or @ is escaped so
/// a spreadsheet will not run it.
pub fn csv_row(values: &[String]) -> String {
    values
        .iter()
        .map(|v| {
            let mut s = v.clone();
            if test(js_re!(r"^[=+\-@\t\r]"), &s) && !test(js_re!(r"^-?\d+(\.\d+)?$"), &s) {
                s = format!("'{s}");
            }
            if s.contains(['"', ',', '\n', '\r']) { format!("\"{}\"", s.replace('"', "\"\"")) } else { s }
        })
        .collect::<Vec<_>>()
        .join(",")
}

/// A CSV file: the header and the rows, each line ended with CRLF.
pub fn csv(header: &[&str], rows: &[Vec<String>]) -> String {
    let mut lines = vec![csv_row(&header.iter().map(|s| s.to_string()).collect::<Vec<_>>())];
    lines.extend(rows.iter().map(|r| csv_row(r)));
    lines.join("\r\n") + "\r\n"
}
