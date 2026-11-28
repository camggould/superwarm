//! Parses Antigravity conversations (`~/.gemini/antigravity-cli/conversations/*.db`).
//!
//! Antigravity (`agy`) keeps each conversation in its own SQLite database of
//! protobuf blobs. Every model response is a row in `steps` whose `metadata`
//! carries a timestamp and a usage block, laid out like Codeium's
//! `ModelUsageStats` (Antigravity descends from Windsurf):
//!
//! | field | meaning |
//! |---|---|
//! | 1 | model, as an enum number |
//! | 2 | uncached input tokens |
//! | 3 | output tokens, thinking included (= 9 + 10) |
//! | 4 | cache-write tokens |
//! | 5 | cache-read tokens |
//! | 7 | the API response id |
//!
//! The enum is resolved to a model id (`gemini-4-neon`) through `gen_metadata`,
//! which records both for each generation. Some steps (checkpoints) are model
//! calls with no `gen_metadata` row, so usage is read from `steps`.
//!
//! The databases are in WAL mode and stay open while `agy` runs, and the most
//! recent responses often live only in the `-wal` file. Each database is read
//! from a private copy of the `.db` and `-wal`, so Superwarm never takes
//! Antigravity's locks or writes next to its files.

use crate::usage::{Provider, TokenCounts, UsageRecord};
use anyhow::{bail, Context, Result};
use rusqlite::{Connection, OpenFlags};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// The conversation database plus its write-ahead log, if any.
pub fn wal_path(db: &Path) -> PathBuf {
    let mut name = db.as_os_str().to_os_string();
    name.push("-wal");
    PathBuf::from(name)
}

pub fn parse_file(path: &Path) -> Result<Vec<UsageRecord>> {
    let copy = PrivateCopy::new(path).with_context(|| format!("copying {}", path.display()))?;
    let conn =
        Connection::open_with_flags(&copy.db, OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX)
            .with_context(|| format!("opening {}", path.display()))?;
    read(&conn, path).with_context(|| format!("reading {}", path.display()))
}

fn read(conn: &Connection, path: &Path) -> Result<Vec<UsageRecord>> {
    let tables: Vec<String> = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    if !tables.iter().any(|t| t == "steps") {
        bail!("not an Antigravity conversation (no steps table)");
    }
    let has = |t: &str| tables.iter().any(|name| name == t);
    let conversation = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();

    let mut models: HashMap<u64, String> = HashMap::new();
    if has("gen_metadata") {
        let mut statement = conn.prepare("SELECT data FROM gen_metadata")?;
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let data: Option<Vec<u8>> = row.get(0)?;
            let Some(generation) = data.as_deref().and_then(|d| Message(d).message(1)) else { continue };
            if let (Some(number), Some(id)) = (generation.varint(3), generation.string(19)) {
                models.insert(number, id);
            }
        }
    }

    let project = if has("trajectory_metadata_blob") {
        conn.query_row("SELECT data FROM trajectory_metadata_blob LIMIT 1", [], |r| r.get::<_, Option<Vec<u8>>>(0))
            .ok()
            .flatten()
            .and_then(|data| {
                let m = Message(&data);
                m.string(7).or_else(|| m.message(1).and_then(|w| w.string(1)))
            })
            .and_then(|uri| file_uri_path(&uri))
    } else {
        None
    };

    let mut records = Vec::new();
    let mut statement = conn.prepare("SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx")?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        let index: i64 = row.get(0)?;
        let data: Vec<u8> = row.get(1)?;
        let step = Message(&data);
        let Some(usage) = step.message(9) else { continue };
        let tokens = TokenCounts {
            input: usage.varint(2).unwrap_or(0),
            output: usage.varint(3).unwrap_or(0),
            cache_write: usage.varint(4).unwrap_or(0),
            cache_read: usage.varint(5).unwrap_or(0),
        };
        if tokens.is_zero() {
            continue;
        }
        let Some(timestamp_ms) = step.message(1).and_then(|t| timestamp_ms(&t)) else { continue };
        let number = usage.varint(1).or_else(|| step.varint(11));
        let model = match number {
            Some(n) => models.get(&n).cloned().unwrap_or_else(|| format!("antigravity-model-{n}")),
            None => "antigravity-unknown".to_string(),
        };
        let id = match usage.string(7).filter(|s| !s.is_empty()) {
            Some(response) => format!("ag:{response}"),
            None => format!("ag:{conversation}:{index}"),
        };
        records.push(UsageRecord {
            id,
            timestamp_ms,
            provider: Provider::Antigravity,
            model,
            project: project.clone(),
            tokens,
            machine: None,
        });
    }
    Ok(records)
}

/// `google.protobuf.Timestamp { seconds = 1; nanos = 2; }` in milliseconds.
fn timestamp_ms(t: &Message) -> Option<i64> {
    let seconds = i64::try_from(t.varint(1)?).ok()?;
    let nanos = t.varint(2).unwrap_or(0) as i64;
    Some(seconds * 1000 + nanos / 1_000_000)
}

/// `file:///Users/me/My%20App` -> `/Users/me/My App`.
fn file_uri_path(uri: &str) -> Option<String> {
    let rest = uri.strip_prefix("file://")?;
    let bytes = rest.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    let path = String::from_utf8_lossy(&out).into_owned();
    (!path.is_empty()).then_some(path)
}

/// A minimal protobuf reader: just enough to pull scalar and nested fields
/// out of a message without its schema.
#[derive(Clone, Copy)]
struct Message<'a>(&'a [u8]);

enum Value<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Fixed,
}

impl<'a> Message<'a> {
    fn fields(&self) -> impl Iterator<Item = (u64, Value<'a>)> + 'a {
        let mut data = self.0;
        std::iter::from_fn(move || {
            let key = read_varint(&mut data)?;
            let value = match key & 7 {
                0 => Value::Varint(read_varint(&mut data)?),
                1 => skip(&mut data, 8)?,
                2 => {
                    let len = usize::try_from(read_varint(&mut data)?).ok()?;
                    if len > data.len() {
                        return None;
                    }
                    let (bytes, rest) = data.split_at(len);
                    data = rest;
                    Value::Bytes(bytes)
                }
                5 => skip(&mut data, 4)?,
                _ => return None, // groups are long deprecated; stop at anything unexpected
            };
            Some((key >> 3, value))
        })
    }

    fn varint(&self, field: u64) -> Option<u64> {
        self.fields().find_map(|(f, v)| match v {
            Value::Varint(n) if f == field => Some(n),
            _ => None,
        })
    }

    fn bytes(&self, field: u64) -> Option<&'a [u8]> {
        self.fields().find_map(|(f, v)| match v {
            Value::Bytes(b) if f == field => Some(b),
            _ => None,
        })
    }

    fn message(&self, field: u64) -> Option<Message<'a>> {
        self.bytes(field).map(Message)
    }

    fn string(&self, field: u64) -> Option<String> {
        self.bytes(field).and_then(|b| std::str::from_utf8(b).ok()).map(str::to_string)
    }
}

fn read_varint(data: &mut &[u8]) -> Option<u64> {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let (&byte, rest) = data.split_first()?;
        *data = rest;
        value |= u64::from(byte & 0x7f) << shift;
        if byte < 0x80 {
            return Some(value);
        }
    }
    None
}

fn skip<'a>(data: &mut &'a [u8], n: usize) -> Option<Value<'a>> {
    if data.len() < n {
        return None;
    }
    *data = &data[n..];
    Some(Value::Fixed)
}

/// A throwaway copy of a database and its WAL, deleted on drop.
struct PrivateCopy {
    dir: PathBuf,
    db: PathBuf,
}

impl PrivateCopy {
    fn new(source: &Path) -> Result<PrivateCopy> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "superwarm-antigravity-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir)?;
        let copy = PrivateCopy { db: dir.join("conversation.db"), dir };
        std::fs::copy(source, &copy.db)?;
        let wal = wal_path(source);
        if wal.exists() {
            std::fs::copy(&wal, wal_path(&copy.db))?;
        }
        Ok(copy)
    }
}

impl Drop for PrivateCopy {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Encodes protobuf fields: varints, or length-delimited bytes.
    pub enum F<'a> {
        V(u64, u64),
        B(u64, &'a [u8]),
    }

    pub fn encode(fields: &[F]) -> Vec<u8> {
        fn varint(out: &mut Vec<u8>, mut n: u64) {
            while n >= 0x80 {
                out.push((n as u8) | 0x80);
                n >>= 7;
            }
            out.push(n as u8);
        }
        let mut out = Vec::new();
        for field in fields {
            match field {
                F::V(f, n) => {
                    varint(&mut out, f << 3);
                    varint(&mut out, *n);
                }
                F::B(f, b) => {
                    varint(&mut out, (f << 3) | 2);
                    varint(&mut out, b.len() as u64);
                    out.extend_from_slice(b);
                }
            }
        }
        out
    }

    pub fn step(seconds: u64, response: &str, input: u64, cache_read: u64, output: u64) -> Vec<u8> {
        let usage = encode(&[
            F::V(1, 1532),
            F::V(2, input),
            F::V(3, output),
            F::V(5, cache_read),
            F::V(6, 24),
            F::B(7, response.as_bytes()),
        ]);
        let created = encode(&[F::V(1, seconds), F::V(2, 452_000_000)]);
        encode(&[F::B(1, &created), F::V(3, 2), F::B(9, &usage), F::V(11, 1532)])
    }

    /// Creates a conversation database shaped like Antigravity's.
    pub fn conversation(path: &Path) -> Connection {
        let conn = Connection::open(path).unwrap();
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA wal_autocheckpoint = 0;
             CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, metadata blob);
             CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0);
             CREATE TABLE trajectory_metadata_blob (id text DEFAULT 'main' PRIMARY KEY, data blob);",
        )
        .unwrap();
        let generation = encode(&[F::B(
            1,
            &encode(&[F::V(3, 1532), F::B(19, b"gemini-4-neon"), F::B(21, b"Gemini 4 Neon (High)")]),
        )]);
        conn.execute("INSERT INTO gen_metadata (idx, data) VALUES (0, ?1)", [generation]).unwrap();
        let trajectory = encode(&[F::B(7, b"file:///home/me/My%20App")]);
        conn.execute("INSERT INTO trajectory_metadata_blob (data) VALUES (?1)", [trajectory]).unwrap();
        conn
    }

    pub fn add_step(conn: &Connection, idx: i64, metadata: &[u8]) {
        conn.execute(
            "INSERT INTO steps (idx, step_type, metadata) VALUES (?1, 15, ?2)",
            rusqlite::params![idx, metadata],
        )
        .unwrap();
    }

    #[test]
    fn reads_responses_including_the_uncheckpointed_wal() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("40451050-44e4-497e-af79-cd5c433b453f.db");
        // Kept open, like a running agy: the rows exist only in the -wal file.
        let conn = conversation(&path);
        add_step(&conn, 0, &step(1_795_873_338, "resp-a", 13_230, 0, 184));
        add_step(&conn, 1, &step(1_795_873_342, "resp-b", 4_968, 13_231, 182));
        // A user message: no usage block.
        add_step(&conn, 2, &encode(&[F::B(1, &encode(&[F::V(1, 1_795_873_343)]))]));
        assert!(wal_path(&path).metadata().unwrap().len() > 0);

        let records = parse_file(&path).unwrap();
        assert_eq!(records.len(), 2);
        let b = &records[1];
        assert_eq!(b.id, "ag:resp-b");
        assert_eq!(b.provider, Provider::Antigravity);
        assert_eq!(b.model, "gemini-4-neon");
        assert_eq!(b.project.as_deref(), Some("/home/me/My App"));
        assert_eq!(b.timestamp_ms, 1_795_873_342_452);
        assert_eq!(b.tokens, TokenCounts { input: 4_968, cache_write: 0, cache_read: 13_231, output: 182 });
        // The owner's connection is unaffected and later writes are picked up.
        add_step(&conn, 3, &step(1_795_873_350, "resp-c", 1, 0, 1));
        assert_eq!(parse_file(&path).unwrap().len(), 3);
    }

    #[test]
    fn unknown_models_and_missing_ids_still_count() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.db");
        let conn = conversation(&path);
        let usage = encode(&[F::V(1, 9999), F::V(2, 10), F::V(3, 5)]);
        let created = encode(&[F::V(1, 1_795_000_000)]);
        add_step(&conn, 7, &encode(&[F::B(1, &created), F::B(9, &usage)]));
        let records = parse_file(&path).unwrap();
        assert_eq!(records[0].model, "antigravity-model-9999");
        assert_eq!(records[0].id, "ag:c:7");
    }

    #[test]
    fn rejects_other_databases() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("other.db");
        Connection::open(&path).unwrap().execute_batch("CREATE TABLE t (x);").unwrap();
        assert!(format!("{:#}", parse_file(&path).unwrap_err()).contains("not an Antigravity conversation"));
    }

    #[test]
    fn decodes_file_uris() {
        assert_eq!(file_uri_path("file:///Users/g/My%20App").as_deref(), Some("/Users/g/My App"));
        assert_eq!(file_uri_path("file:///tmp/100%").as_deref(), Some("/tmp/100%"));
        assert_eq!(file_uri_path("https://example.com"), None);
    }

    #[test]
    fn truncated_messages_do_not_panic() {
        let data = step(1, "r", 1, 2, 3);
        for cut in 0..data.len() {
            let m = Message(&data[..cut]);
            let _ = m.message(9).and_then(|u| u.varint(3));
        }
    }
}
