//! Streams newline-delimited records from plain or zstd-compressed files
//! without loading whole files into memory.

use anyhow::{Context, Result};
use memchr::memmem::Finder;
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;

/// Calls `body` once per non-empty line. Lines containing none of `needles`
/// are skipped before the caller sees them, which keeps JSON decoding off the
/// vast majority of log lines. An empty `needles` passes every line.
pub fn for_each_line(path: &Path, needles: &[&[u8]], body: impl FnMut(&[u8])) -> Result<()> {
    let file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let is_zstd = path.extension().is_some_and(|e| e == "zst");
    if is_zstd {
        let decoder = zstd::stream::read::Decoder::new(file)
            .with_context(|| format!("reading zstd stream {}", path.display()))?;
        split(decoder, needles, body).with_context(|| format!("decompressing {}", path.display()))
    } else {
        split(file, needles, body).with_context(|| format!("reading {}", path.display()))
    }
}

/// Splits in-memory data; used by tests and small inputs.
pub fn for_each_line_in(data: &[u8], needles: &[&[u8]], body: impl FnMut(&[u8])) {
    split(data, needles, body).expect("reading from memory cannot fail");
}

fn split(reader: impl Read, needles: &[&[u8]], mut body: impl FnMut(&[u8])) -> Result<()> {
    let finders: Vec<Finder> = needles.iter().map(|n| Finder::new(n)).collect();
    let mut reader = BufReader::with_capacity(1 << 20, reader);
    let mut line = Vec::with_capacity(64 * 1024);
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            return Ok(());
        }
        while matches!(line.last(), Some(b'\n' | b'\r')) {
            line.pop();
        }
        if line.is_empty() {
            continue;
        }
        if finders.is_empty() || finders.iter().any(|f| f.find(&line).is_some()) {
            body(&line);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn filters_by_needle() {
        let mut seen = Vec::new();
        for_each_line_in(b"a usage\nb\n\nc usage", &[b"usage"], |l| seen.push(String::from_utf8_lossy(l).into_owned()));
        assert_eq!(seen, ["a usage", "c usage"]);
    }

    #[test]
    fn reads_zstd_natively() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("r.jsonl.zst");
        let mut encoder = zstd::stream::write::Encoder::new(File::create(&path).unwrap(), 3).unwrap();
        encoder.write_all(b"one\r\ntwo\n").unwrap();
        encoder.finish().unwrap();
        let mut lines = Vec::new();
        for_each_line(&path, &[], |l| lines.push(String::from_utf8_lossy(l).into_owned())).unwrap();
        assert_eq!(lines, ["one", "two"]);
    }
}
