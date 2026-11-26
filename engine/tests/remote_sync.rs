//! End-to-end test of pulling usage from a remote machine, driving the real
//! `superwarm` binary. A fake `ssh` runs the remote command locally against a
//! separate "remote" home directory, so the whole path is exercised: remote
//! config, the ssh invocation, `superwarm export` on the remote, import,
//! incremental sync, reports, the snapshot and removal.

use std::path::{Path, PathBuf};
use std::process::Command;

const FAKE_SSH: &str = r#"#!/bin/sh
# Fake ssh: skip options up to "--", then run the command "on" the remote.
while [ "$1" != "--" ]; do shift; done
shift
host="$1"
shift
if [ "$host" = "broken" ]; then
  echo "me@broken: Permission denied (publickey)." >&2
  exit 255
fi
exec env HOME="$REMOTE_HOME" CLAUDE_CONFIG_DIR="$REMOTE_HOME/.claude" CODEX_HOME="$REMOTE_HOME/.codex" \
  SUPERWARM_CACHE_DIR="$REMOTE_HOME/cache" PATH="$SUPERWARM_BIN_DIR:$PATH" sh -c "$1"
"#;

struct World {
    _dir: tempfile::TempDir,
    root: PathBuf,
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        for d in ["laptop/.claude/projects", "laptop/.codex", "remote/.claude/projects", "remote/.codex"] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        let ssh = root.join("fake-ssh");
        std::fs::write(&ssh, FAKE_SSH).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        World { _dir: dir, root }
    }

    /// Appends one Claude Code response to a machine's logs.
    fn log(&self, machine: &str, id: &str, minutes_ago: i64, output: u64) {
        let dir = self.root.join(machine).join(".claude/projects/-work-app");
        std::fs::create_dir_all(&dir).unwrap();
        let when = chrono::Utc::now() - chrono::Duration::minutes(minutes_ago);
        let line = format!(
            r#"{{"type":"assistant","timestamp":"{}","requestId":"r-{id}","cwd":"/home/me/work/app","message":{{"id":"{id}","model":"claude-sonnet-4-5","usage":{{"input_tokens":10,"cache_read_input_tokens":20000,"output_tokens":{output}}}}}}}"#,
            when.to_rfc3339()
        );
        let path = dir.join("session.jsonl");
        let mut text = std::fs::read_to_string(&path).unwrap_or_default();
        text.push_str(&line);
        text.push('\n');
        std::fs::write(path, text).unwrap();
    }

    fn superwarm(&self, args: &[&str]) -> std::process::Output {
        let binary = Path::new(env!("CARGO_BIN_EXE_superwarm"));
        let laptop = self.root.join("laptop");
        Command::new(binary)
            .args(args)
            .env("HOME", &laptop)
            .env("CLAUDE_CONFIG_DIR", laptop.join(".claude"))
            .env("CODEX_HOME", laptop.join(".codex"))
            .env("SUPERWARM_CONFIG_DIR", laptop.join("config"))
            .env("SUPERWARM_DATA_DIR", laptop.join("data"))
            .env("SUPERWARM_CACHE_DIR", laptop.join("cache"))
            .env("SUPERWARM_SSH", self.root.join("fake-ssh"))
            .env("REMOTE_HOME", self.root.join("remote"))
            .env("SUPERWARM_BIN_DIR", binary.parent().unwrap())
            .env("NO_COLOR", "1")
            .output()
            .unwrap()
    }

    fn ok(&self, args: &[&str]) -> String {
        let out = self.superwarm(args);
        assert!(out.status.success(), "superwarm {args:?} failed:\n{}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8(out.stdout).unwrap()
    }
}

#[test]
fn pulls_usage_from_a_remote_over_ssh() {
    let w = World::new();
    w.log("laptop", "local-1", 30, 500);
    w.log("remote", "remote-1", 20, 1500);

    w.ok(&["remote", "add", "devbox", "me@devbox"]);
    let sync: serde_json::Value = serde_json::from_str(&w.ok(&["sync", "--json"])).unwrap();
    assert_eq!(sync[0]["name"], "devbox");
    assert_eq!(sync[0]["added"], 1);
    assert!(sync[0]["error"].is_null());

    // Records are minutes old; the 7-day period holds them even just after midnight.
    let report = w.ok(&["report", "week"]);
    assert!(report.contains("By machine"), "{report}");
    assert!(report.contains("devbox"), "{report}");
    assert!(report.contains("1 remote(s), synced just now"), "{report}");

    // Syncing again adds nothing; new remote usage arrives on the next sync.
    let again: serde_json::Value = serde_json::from_str(&w.ok(&["sync", "--json"])).unwrap();
    assert_eq!(again[0]["added"], 0);
    w.log("remote", "remote-2", 5, 900);
    let next: serde_json::Value = serde_json::from_str(&w.ok(&["sync", "--json"])).unwrap();
    assert_eq!(next[0]["added"], 1);
    assert_eq!(next[0]["total"], 2);

    // The app's view: remote status and a per-machine split.
    let snapshot: serde_json::Value = serde_json::from_str(&w.ok(&["snapshot"])).unwrap();
    assert_eq!(snapshot["remotes"][0]["name"], "devbox");
    assert_eq!(snapshot["remotes"][0]["responses"], 2);
    let week = &snapshot["periods"][1];
    assert_eq!(week["period"], "week");
    assert_eq!(week["summary"]["responses"], 3);
    assert_eq!(week["machines"].as_array().unwrap().len(), 2);

    // --local-only leaves the remote out.
    let local: serde_json::Value = serde_json::from_str(&w.ok(&["snapshot", "--local-only"])).unwrap();
    assert_eq!(local["periods"][1]["summary"]["responses"], 1);

    // Removing the remote forgets its usage.
    w.ok(&["remote", "remove", "devbox"]);
    let after: serde_json::Value = serde_json::from_str(&w.ok(&["snapshot"])).unwrap();
    assert_eq!(after["periods"][1]["summary"]["responses"], 1);
    assert!(after["remotes"].as_array().unwrap().is_empty());
}

#[test]
fn reports_ssh_failures_without_losing_data() {
    let w = World::new();
    w.ok(&["remote", "add", "flaky", "broken"]);
    let out = w.superwarm(&["sync"]);
    assert!(!out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("flaky: failed") && text.contains("Permission denied"), "{text}");

    let list = w.ok(&["remote", "list"]);
    assert!(list.contains("last attempt just now failed") && !list.contains("synced just now"), "{list}");
    // snapshot --sync still succeeds and carries the error for the app to show.
    let snapshot: serde_json::Value = serde_json::from_str(&w.ok(&["snapshot", "--sync"])).unwrap();
    assert!(snapshot["remotes"][0]["lastError"].as_str().unwrap().contains("Permission denied"));
}

#[test]
fn imports_an_export_copied_by_hand() {
    let w = World::new();
    w.log("laptop", "local-1", 30, 500);
    // Export on the "remote" by running the binary with the remote's environment.
    let export = Command::new(env!("CARGO_BIN_EXE_superwarm"))
        .args(["--demo", "export", "--no-projects"])
        .env("SUPERWARM_CACHE_DIR", w.root.join("remote/cache"))
        .output()
        .unwrap();
    assert!(export.status.success());
    let file = w.root.join("box.jsonl");
    std::fs::write(&file, &export.stdout).unwrap();
    assert!(!String::from_utf8_lossy(&export.stdout).contains("acme-web"), "--no-projects drops folder names");

    let imported = w.ok(&["import", file.to_str().unwrap(), "--machine", "box2"]);
    assert!(imported.contains("from box2"), "{imported}");
    let list = w.ok(&["remote", "list"]);
    assert!(list.contains("box2") && list.contains("imported"), "{list}");
    assert!(w.superwarm(&["import", file.to_str().unwrap(), "--machine", "../evil"]).status.code() != Some(0));
}
