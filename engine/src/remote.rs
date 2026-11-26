//! Usage from other machines: export it where your agents run, pull it to
//! where you look at it.
//!
//! ```text
//! devbox$  superwarm export --since 2026-11-01 > devbox.jsonl     # by hand, or…
//! laptop$  superwarm remote add devbox me@devbox                  # …let SSH fetch it
//! laptop$  superwarm sync
//! ```
//!
//! Only usage records travel: timestamps, models, token counts and project
//! folder names (or nothing with `--no-projects`). Never prompts or code.
//! Sync runs `ssh <host> superwarm export --since …` with BatchMode, so it uses
//! the user's existing keys, never prompts, and needs no daemon or open port.

use crate::usage::{Provider, TokenCounts, UsageRecord};
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// Bumped when the export format changes incompatibly.
pub const EXPORT_VERSION: u32 = 1;

/// How far before the newest synced record the next sync starts, to pick up
/// responses logged late (a long session written after it began).
const SYNC_OVERLAP_MS: i64 = 6 * 3_600_000;

/// First line of an export.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportHeader {
    pub superwarm_export: u32,
    pub machine: String,
    pub exported_at_ms: i64,
    pub engine_version: String,
}

/// One response in an export. Projects are folder names, never full paths.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExportRecord {
    id: String,
    timestamp_ms: i64,
    provider: Provider,
    model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    project: Option<String>,
    tokens: TokenCounts,
}

fn folder_name(path: &str) -> String {
    Path::new(path).file_name().map_or_else(|| path.to_string(), |n| n.to_string_lossy().into_owned())
}

/// Writes this machine's records (optionally only those at or after `since_ms`) as JSON lines.
pub fn write_export(
    records: &[UsageRecord],
    since_ms: Option<i64>,
    include_projects: bool,
    machine: &str,
    now_ms: i64,
    mut out: impl Write,
) -> Result<usize> {
    let header = ExportHeader {
        superwarm_export: EXPORT_VERSION,
        machine: machine.to_string(),
        exported_at_ms: now_ms,
        engine_version: env!("CARGO_PKG_VERSION").to_string(),
    };
    writeln!(out, "{}", serde_json::to_string(&header)?)?;
    let mut written = 0;
    // Only this machine's own usage: never re-export what was synced from elsewhere.
    for r in records.iter().filter(|r| r.machine.is_none() && since_ms.is_none_or(|s| r.timestamp_ms >= s)) {
        let line = ExportRecord {
            id: r.id.clone(),
            timestamp_ms: r.timestamp_ms,
            provider: r.provider,
            model: r.model.clone(),
            project: if include_projects { r.project.as_deref().map(folder_name) } else { None },
            tokens: r.tokens,
        };
        writeln!(out, "{}", serde_json::to_string(&line)?)?;
        written += 1;
    }
    out.flush()?;
    Ok(written)
}

/// Reads an export, tagging every record with `machine` (default: the header's).
pub fn read_export(reader: impl BufRead, machine: Option<&str>) -> Result<(ExportHeader, Vec<UsageRecord>)> {
    let mut lines = reader.lines();
    let first = lines.next().ok_or_else(|| anyhow!("empty export"))??;
    let header: ExportHeader = serde_json::from_str(&first).context("not a Superwarm export (missing header line)")?;
    if header.superwarm_export != EXPORT_VERSION {
        bail!(
            "export format v{} isn't supported by this superwarm (v{EXPORT_VERSION}); update both machines",
            header.superwarm_export
        );
    }
    let machine = machine.unwrap_or(&header.machine).to_string();
    let mut records = Vec::new();
    for (index, line) in lines.enumerate() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let r: ExportRecord =
            serde_json::from_str(&line).with_context(|| format!("export line {} is malformed", index + 2))?;
        records.push(UsageRecord {
            id: format!("{machine}/{}", r.id),
            timestamp_ms: r.timestamp_ms,
            provider: r.provider,
            model: r.model,
            project: r.project,
            tokens: r.tokens,
            machine: Some(machine.clone()),
        });
    }
    Ok((header, records))
}

/// A machine to pull usage from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Remote {
    pub name: String,
    /// Anything `ssh` accepts: `host`, `user@host`, or an alias from ~/.ssh/config.
    pub ssh: String,
    /// The remote superwarm binary, if it isn't on the remote's PATH or in ~/.local/bin.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary: Option<String>,
}

pub fn validate_name(name: &str) -> Result<()> {
    let ok = !name.is_empty()
        && name.len() <= 40
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.');
    if ok {
        Ok(())
    } else {
        bail!("machine names use letters, digits, '-', '_' or '.' (got {name:?})")
    }
}

/// `remotes.json` in the config directory.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RemoteConfig {
    pub remotes: Vec<Remote>,
}

impl RemoteConfig {
    pub fn path() -> Option<PathBuf> {
        crate::paths::config_dir().map(|d| d.join("remotes.json"))
    }

    pub fn load() -> Result<RemoteConfig> {
        match RemoteConfig::path() {
            Some(path) if path.exists() => {
                let data = std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
                serde_json::from_slice(&data).with_context(|| format!("parsing {}", path.display()))
            }
            _ => Ok(RemoteConfig::default()),
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = RemoteConfig::path().ok_or_else(|| anyhow!("no config directory"))?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(&path, serde_json::to_vec_pretty(self)?)?;
        Ok(())
    }
}

/// Everything synced from one machine, kept until the remote is removed.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct RemoteStore {
    pub version: u32,
    pub name: String,
    pub last_sync_ms: Option<i64>,
    pub last_error: Option<String>,
    pub records: Vec<UsageRecord>,
}

impl RemoteStore {
    pub const VERSION: u32 = 1;

    pub fn path(name: &str) -> Option<PathBuf> {
        crate::paths::data_dir().map(|d| d.join("remotes").join(format!("{name}.bin")))
    }

    pub fn load(name: &str) -> RemoteStore {
        RemoteStore::path(name)
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|data| bincode::deserialize::<RemoteStore>(&data).ok())
            .filter(|s| s.version == Self::VERSION)
            .unwrap_or_else(|| RemoteStore { version: Self::VERSION, name: name.to_string(), ..Default::default() })
    }

    pub fn save(&self) -> Result<()> {
        let path = RemoteStore::path(&self.name).ok_or_else(|| anyhow!("no data directory"))?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, bincode::serialize(self)?)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }

    pub fn delete(name: &str) {
        if let Some(path) = RemoteStore::path(name) {
            let _ = std::fs::remove_file(path);
        }
    }

    /// Merges records (same id: field-wise max), returning how many were new.
    pub fn merge(&mut self, incoming: Vec<UsageRecord>) -> usize {
        let mut by_id: HashMap<String, usize> =
            self.records.iter().enumerate().map(|(i, r)| (r.id.clone(), i)).collect();
        let mut added = 0;
        for record in incoming {
            match by_id.get(&record.id) {
                Some(&i) => self.records[i].tokens = self.records[i].tokens.fieldwise_max(&record.tokens),
                None => {
                    by_id.insert(record.id.clone(), self.records.len());
                    self.records.push(record);
                    added += 1;
                }
            }
        }
        self.records.sort_by_key(|r| r.timestamp_ms);
        added
    }

    /// Where the next incremental sync should start.
    pub fn since_ms(&self) -> Option<i64> {
        self.records.iter().map(|r| r.timestamp_ms).max().map(|m| m - SYNC_OVERLAP_MS)
    }
}

/// The command run on the remote to export its usage.
pub fn remote_command(remote: &Remote, since_ms: Option<i64>) -> String {
    let since = since_ms.map(|s| format!(" --since {s}")).unwrap_or_default();
    match &remote.binary {
        Some(binary) => format!("{binary} export{since}"),
        // Non-interactive SSH shells often lack ~/.local/bin and ~/.cargo/bin on PATH.
        None => format!("PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH\" superwarm export{since}"),
    }
}

/// Runs `ssh` and returns the export it printed. `ssh_program` is `ssh`
/// unless `$SUPERWARM_SSH` overrides it (tests use a fake).
pub fn fetch(remote: &Remote, since_ms: Option<i64>, timeout: Duration) -> Result<Vec<u8>> {
    let ssh = std::env::var("SUPERWARM_SSH").unwrap_or_else(|_| "ssh".to_string());
    let mut child = Command::new(&ssh)
        .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15"])
        .args(["-o", "ServerAliveCountMax=2", "--", &remote.ssh, &remote_command(remote, since_ms)])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("running {ssh}"))?;

    // Read both pipes on threads so neither can fill up and stall ssh.
    let mut stdout = child.stdout.take().expect("piped");
    let mut stderr = child.stderr.take().expect("piped");
    let out_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        stdout.read_to_end(&mut buf).map(|_| buf)
    });
    let err_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stderr.read_to_end(&mut buf);
        buf
    });

    let deadline = std::time::Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("timed out after {}s", timeout.as_secs());
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let output = out_thread.join().map_err(|_| anyhow!("reading ssh output failed"))??;
    let errors = String::from_utf8_lossy(&err_thread.join().unwrap_or_default()).trim().to_string();
    if !status.success() {
        let hint = if errors.contains("command not found") || status.code() == Some(127) {
            " (is superwarm installed on the remote? Set its path with `superwarm remote add … --binary`)"
        } else {
            ""
        };
        bail!("ssh exited with {}: {}{hint}", status.code().map_or("a signal".into(), |c| c.to_string()), errors);
    }
    Ok(output)
}

/// Outcome of syncing one remote.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncOutcome {
    pub name: String,
    pub added: usize,
    pub total: usize,
    pub error: Option<String>,
}

/// Pulls new usage from `remote` into its store.
pub fn sync(remote: &Remote, now_ms: i64, timeout: Duration) -> SyncOutcome {
    let mut store = RemoteStore::load(&remote.name);
    let result = fetch(remote, store.since_ms(), timeout)
        .and_then(|data| read_export(std::io::Cursor::new(data), Some(&remote.name)));
    let (added, error) = match result {
        Ok((_, records)) => (store.merge(records), None),
        Err(error) => (0, Some(format!("{error:#}"))),
    };
    store.last_sync_ms = Some(now_ms);
    store.last_error = error.clone();
    let save_error = store.save().err().map(|e| format!("{e:#}"));
    SyncOutcome { name: remote.name.clone(), added, total: store.records.len(), error: error.or(save_error) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(id: &str, t: i64, machine: Option<&str>) -> UsageRecord {
        UsageRecord {
            id: id.into(),
            timestamp_ms: t,
            provider: Provider::ClaudeCode,
            model: "claude-opus-4-5".into(),
            project: Some("/home/me/code/secret-app".into()),
            tokens: TokenCounts { output: 10, ..Default::default() },
            machine: machine.map(str::to_string),
        }
    }

    #[test]
    fn export_round_trips_and_strips_paths() {
        let records = vec![record("a", 100, None), record("b", 200, None), record("c", 300, Some("other"))];
        let mut buf = Vec::new();
        let written = write_export(&records, Some(150), true, "devbox", 999, &mut buf).unwrap();
        assert_eq!(written, 1, "only local records at or after --since");
        let text = String::from_utf8(buf.clone()).unwrap();
        assert!(!text.contains("/home/me"), "full paths never leave the machine");
        let (header, imported) = read_export(std::io::Cursor::new(buf), None).unwrap();
        assert_eq!(header.machine, "devbox");
        assert_eq!(imported.len(), 1);
        assert_eq!(imported[0].id, "devbox/b");
        assert_eq!(imported[0].machine.as_deref(), Some("devbox"));
        assert_eq!(imported[0].project.as_deref(), Some("secret-app"));
    }

    #[test]
    fn export_can_drop_projects() {
        let mut buf = Vec::new();
        write_export(&[record("a", 100, None)], None, false, "m", 0, &mut buf).unwrap();
        assert!(!String::from_utf8(buf).unwrap().contains("secret-app"));
    }

    #[test]
    fn rejects_foreign_input_and_newer_formats() {
        assert!(read_export(std::io::Cursor::new(b"hello\n".to_vec()), None).is_err());
        let newer = format!(
            r#"{{"superwarmExport":{},"machine":"m","exportedAtMs":0,"engineVersion":"9"}}"#,
            EXPORT_VERSION + 1
        );
        let error = read_export(std::io::Cursor::new(newer.into_bytes()), None).unwrap_err();
        assert!(error.to_string().contains("update both machines"));
    }

    #[test]
    fn merge_counts_new_records_and_overlaps_the_next_sync() {
        let mut store = RemoteStore::default();
        let added = store.merge(vec![record("m/a", 1_000_000_000, Some("m")), record("m/b", 2_000_000_000, Some("m"))]);
        assert_eq!(added, 2);
        assert_eq!(store.merge(vec![record("m/b", 2_000_000_000, Some("m"))]), 0);
        assert_eq!(store.since_ms(), Some(2_000_000_000 - SYNC_OVERLAP_MS));
    }

    #[test]
    fn remote_command_finds_user_installs() {
        let remote = Remote { name: "d".into(), ssh: "me@d".into(), binary: None };
        let command = remote_command(&remote, Some(42));
        assert!(command.contains("$HOME/.local/bin") && command.ends_with("superwarm export --since 42"));
        let custom = Remote { binary: Some("/opt/sw/superwarm".into()), ..remote };
        assert_eq!(remote_command(&custom, None), "/opt/sw/superwarm export");
    }

    #[test]
    fn names_are_safe_file_names() {
        assert!(validate_name("devbox-2").is_ok());
        assert!(validate_name("../etc").is_err());
        assert!(validate_name("").is_err());
    }
}
