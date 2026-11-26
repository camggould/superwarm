//! Finds log files, parses changed ones in parallel, and caches the results.

use crate::usage::{Provider, UsageRecord};
use crate::{claude, codex};
use anyhow::{Context, Result};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// Where one tool keeps its logs on disk.
#[derive(Clone, Debug)]
pub struct LogSource {
    pub provider: Provider,
    pub roots: Vec<PathBuf>,
}

impl LogSource {
    /// Default locations, honouring `CLAUDE_CONFIG_DIR` (comma-separated) and `CODEX_HOME`.
    pub fn defaults() -> Vec<LogSource> {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        let claude_roots = match std::env::var("CLAUDE_CONFIG_DIR") {
            Ok(dirs) if !dirs.trim().is_empty() => {
                dirs.split(',').map(|d| PathBuf::from(d.trim()).join("projects")).collect()
            }
            _ => vec![home.join(".claude/projects"), home.join(".config/claude/projects")],
        };
        let codex_home = std::env::var("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|_| home.join(".codex"));
        vec![
            LogSource { provider: Provider::ClaudeCode, roots: claude_roots },
            LogSource {
                provider: Provider::Codex,
                roots: vec![codex_home.join("sessions"), codex_home.join("archived_sessions")],
            },
        ]
    }
}

/// Parsed records for one log file, reused while its size and mtime are unchanged.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CachedFile {
    pub size: u64,
    pub modified_ns: i128,
    pub records: Vec<UsageRecord>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ScanCache {
    pub version: u32,
    pub files: HashMap<String, CachedFile>,
}

impl ScanCache {
    /// Bump whenever parsers change what they emit (ids, fields, merging), so
    /// stale cached records are re-parsed instead of silently reused.
    /// 2: Codex record ids are keyed by rollout file rather than session id.
    pub const VERSION: u32 = 2;

    /// `~/Library/Caches/superwarm` on macOS, `~/.cache/superwarm` on Linux.
    pub fn default_path() -> Option<PathBuf> {
        dirs::cache_dir().map(|d| d.join("superwarm").join("engine-cache-v1.bin"))
    }

    pub fn load(path: &Path) -> ScanCache {
        std::fs::read(path)
            .ok()
            .and_then(|data| bincode::deserialize::<ScanCache>(&data).ok())
            .filter(|cache| cache.version == Self::VERSION)
            .unwrap_or_else(|| ScanCache { version: Self::VERSION, files: HashMap::new() })
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, bincode::serialize(self)?).with_context(|| format!("writing {}", tmp.display()))?;
        std::fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
        Ok(())
    }
}

#[derive(Clone, Debug, Default)]
pub struct ScanResult {
    pub records: Vec<UsageRecord>,
    pub files_found: usize,
    pub files_parsed: usize,
    pub issues: Vec<String>,
}

struct FileTask {
    provider: Provider,
    path: PathBuf,
    size: u64,
    modified_ns: i128,
}

pub struct Scanner {
    pub sources: Vec<LogSource>,
}

impl Default for Scanner {
    fn default() -> Self {
        Scanner { sources: LogSource::defaults() }
    }
}

impl Scanner {
    fn discover(&self) -> Vec<FileTask> {
        let mut tasks = Vec::new();
        for source in &self.sources {
            for root in source.roots.iter().filter(|r| r.exists()) {
                for entry in walkdir::WalkDir::new(root).into_iter().filter_map(Result::ok) {
                    let name = entry.file_name().to_string_lossy();
                    if !(name.ends_with(".jsonl") || name.ends_with(".jsonl.zst")) || !entry.file_type().is_file() {
                        continue;
                    }
                    let Ok(meta) = entry.metadata() else { continue };
                    let modified_ns = meta
                        .modified()
                        .ok()
                        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                        .map_or(0, |d| d.as_nanos() as i128);
                    tasks.push(FileTask {
                        provider: source.provider,
                        path: entry.into_path(),
                        size: meta.len(),
                        modified_ns,
                    });
                }
            }
        }
        tasks
    }

    /// Scans all sources, re-parsing only files whose size or mtime changed since `cache`.
    pub fn scan(&self, cache: &mut ScanCache) -> ScanResult {
        let tasks = self.discover();
        let stale: Vec<&FileTask> = tasks
            .iter()
            .filter(|t| match cache.files.get(&t.path.to_string_lossy().into_owned()) {
                Some(cached) => cached.size != t.size || cached.modified_ns != t.modified_ns,
                None => true,
            })
            .collect();

        let parsed: Vec<(String, Result<CachedFile>)> = stale
            .par_iter()
            .map(|task| {
                let records = match task.provider {
                    Provider::ClaudeCode => claude::parse_file(&task.path),
                    Provider::Codex => codex::parse_file(&task.path),
                };
                let file =
                    records.map(|records| CachedFile { size: task.size, modified_ns: task.modified_ns, records });
                (task.path.to_string_lossy().into_owned(), file)
            })
            .collect();

        let mut fresh: HashMap<String, CachedFile> = HashMap::new();
        let mut issues = Vec::new();
        for (path, result) in parsed {
            match result {
                Ok(file) => {
                    fresh.insert(path, file);
                }
                Err(error) => issues.push(format!("{error:#}")),
            }
        }
        let files_parsed = fresh.len();

        let mut files = HashMap::with_capacity(tasks.len());
        for task in &tasks {
            let key = task.path.to_string_lossy().into_owned();
            if let Some(file) = fresh.remove(&key) {
                files.insert(key, file);
            } else if let Some(file) = cache.files.remove(&key) {
                files.insert(key, file);
            }
        }
        cache.files = files;
        cache.version = ScanCache::VERSION;

        ScanResult {
            records: deduplicate(cache.files.values().flat_map(|f| f.records.iter().cloned())),
            files_found: tasks.len(),
            files_parsed,
            issues: summarize(issues),
        }
    }
}

/// The same response can be logged in several files (a resumed Claude Code
/// session copies its history). Keeps one record per id, sorted by time.
///
/// Input order doesn't matter: records are pre-sorted so the kept model and
/// project always come from the earliest copy, whatever order files were read in.
pub fn deduplicate(records: impl IntoIterator<Item = UsageRecord>) -> Vec<UsageRecord> {
    let mut records: Vec<UsageRecord> = records.into_iter().collect();
    records.sort_by(|a, b| {
        (a.timestamp_ms, &a.model, &a.project)
            .partial_cmp(&(b.timestamp_ms, &b.model, &b.project))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut by_id: HashMap<String, UsageRecord> = HashMap::with_capacity(records.len());
    for record in records {
        match by_id.get_mut(&record.id) {
            Some(existing) => {
                existing.tokens = existing.tokens.fieldwise_max(&record.tokens);
                existing.timestamp_ms = existing.timestamp_ms.min(record.timestamp_ms);
            }
            None => {
                by_id.insert(record.id.clone(), record);
            }
        }
    }
    let mut unique: Vec<UsageRecord> = by_id.into_values().collect();
    unique.sort_by(|a, b| a.timestamp_ms.cmp(&b.timestamp_ms).then_with(|| a.id.cmp(&b.id)));
    unique
}

/// Collapses a long list of unreadable files into one line.
fn summarize(mut issues: Vec<String>) -> Vec<String> {
    issues.sort();
    if issues.len() > 3 {
        let first = issues[0].clone();
        return vec![format!("{} log files couldn't be read, e.g. {first}", issues.len())];
    }
    issues
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::TokenCounts;

    #[test]
    fn same_response_in_two_files_counts_once() {
        let a = UsageRecord {
            id: "cc:m:r".into(),
            timestamp_ms: 1_800_000_000_000,
            provider: Provider::ClaudeCode,
            model: "x".into(),
            project: None,
            tokens: TokenCounts { output: 10, ..Default::default() },
        };
        let mut b = a.clone();
        b.tokens.output = 12;
        let unique = deduplicate([a, b]);
        assert_eq!(unique.len(), 1);
        assert_eq!(unique[0].tokens.output, 12);
    }

    #[test]
    fn cache_skips_unchanged_files() {
        let root = tempfile::tempdir().unwrap();
        let line = r#"{"type":"assistant","timestamp":"2026-11-01T10:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-4-5","usage":{"output_tokens":10}}}"#;
        std::fs::write(root.path().join("s.jsonl"), line).unwrap();
        let scanner = Scanner {
            sources: vec![LogSource { provider: Provider::ClaudeCode, roots: vec![root.path().to_path_buf()] }],
        };
        let mut cache = ScanCache::default();
        assert_eq!(scanner.scan(&mut cache).files_parsed, 1);
        let second = scanner.scan(&mut cache);
        assert_eq!(second.files_parsed, 0);
        assert_eq!(second.records.len(), 1);

        let path = root.path().join("cache.bin");
        cache.save(&path).unwrap();
        assert_eq!(ScanCache::load(&path).files.len(), 1);
    }
}
