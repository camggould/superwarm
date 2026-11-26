//! Parses Codex rollout files (`~/.codex/sessions/**/rollout-*.jsonl[.zst]`).
//!
//! Codex emits `token_count` events carrying a running `total_token_usage`.
//! Events are sometimes repeated, so each record is the *increase* in the
//! running total. The first event in a file, and any event where the total
//! went backwards (a reset), falls back to `last_token_usage`, so a resumed
//! session does not re-count the history it inherited.
//!
//! Records are keyed by the rollout *file* plus the event's ordinal, not by the
//! session id in `session_meta`: forked and subagent rollouts can carry their
//! parent's session id, and their ordinals restart, so session-keyed ids
//! collide across genuinely different responses. A session moved into
//! `archived_sessions` keeps its file name, so true duplicates still merge.

use crate::lines;
use crate::usage::{parse_timestamp, Provider, TokenCounts, UsageRecord};
use anyhow::Result;
use serde::Deserialize;
use serde_json::Value;
use std::path::Path;

pub const NEEDLES: &[&[u8]] = &[b"\"token_count\"", b"\"turn_context\"", b"\"session_meta\""];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Usage {
    input: i64,
    cached: i64,
    cache_write: i64,
    output: i64,
}

impl Usage {
    fn from(value: &Value) -> Usage {
        let int = |key: &str| value.get(key).and_then(Value::as_f64).unwrap_or(0.0) as i64;
        Usage {
            input: int("input_tokens"),
            cached: int("cached_input_tokens"),
            cache_write: int("cache_write_input_tokens"),
            output: int("output_tokens"),
        }
    }

    fn minus(&self, other: &Usage) -> Usage {
        Usage {
            input: self.input - other.input,
            cached: self.cached - other.cached,
            cache_write: self.cache_write - other.cache_write,
            output: self.output - other.output,
        }
    }

    fn is_negative(&self) -> bool {
        self.input < 0 || self.cached < 0 || self.cache_write < 0 || self.output < 0
    }

    fn is_zero(&self) -> bool {
        *self == Usage::default()
    }

    /// OpenAI's `input_tokens` includes cached tokens; split them out.
    fn tokens(&self) -> TokenCounts {
        TokenCounts {
            input: (self.input - self.cached - self.cache_write).max(0) as u64,
            cache_write: self.cache_write.max(0) as u64,
            cache_read: self.cached.max(0) as u64,
            output: self.output.max(0) as u64,
        }
    }
}

#[derive(Deserialize)]
struct Line {
    timestamp: Option<String>,
    ordinal: Option<i64>,
    #[serde(rename = "type")]
    kind: Option<String>,
    payload: Option<Value>,
}

struct State {
    /// Identifies the rollout file; the prefix of every record id.
    file_key: String,
    model: String,
    cwd: Option<String>,
    previous_total: Option<Usage>,
    line_number: usize,
    records: Vec<UsageRecord>,
}

impl State {
    fn new(file_key: &str) -> State {
        State {
            file_key: file_key.to_string(),
            model: "unknown-codex-model".to_string(),
            cwd: None,
            previous_total: None,
            line_number: 0,
            records: Vec::new(),
        }
    }

    fn consume(&mut self, line: &[u8]) {
        self.line_number += 1;
        let Ok(parsed) = serde_json::from_slice::<Line>(line) else { return };
        let (Some(kind), Some(payload)) = (parsed.kind.as_deref(), parsed.payload.as_ref()) else { return };
        let string = |key: &str| payload.get(key).and_then(Value::as_str).map(str::to_string);
        match kind {
            "session_meta" => {
                self.cwd = string("cwd").or(self.cwd.take());
            }
            "turn_context" => {
                if let Some(model) = string("model") {
                    self.model = model;
                }
                self.cwd = string("cwd").or(self.cwd.take());
            }
            "event_msg" => {
                if payload.get("type").and_then(Value::as_str) != Some("token_count") {
                    return;
                }
                let Some(info) = payload.get("info").filter(|v| v.is_object()) else { return };
                let Some(total_value) = info.get("total_token_usage").filter(|v| v.is_object()) else { return };
                let Some(timestamp_ms) = parsed.timestamp.as_deref().and_then(parse_timestamp) else { return };
                let total = Usage::from(total_value);
                let last = info.get("last_token_usage").filter(|v| v.is_object()).map(Usage::from);
                let increment = match self.previous_total {
                    Some(previous) => {
                        let delta = total.minus(&previous);
                        if delta.is_zero() {
                            return; // duplicate event
                        }
                        if delta.is_negative() {
                            last.unwrap_or(total)
                        } else {
                            delta
                        }
                    }
                    None => last.unwrap_or(total),
                };
                self.previous_total = Some(total);
                let tokens = increment.tokens();
                if tokens.is_zero() {
                    return;
                }
                let ordinal = parsed.ordinal.map_or_else(|| format!("l{}", self.line_number), |o| o.to_string());
                self.records.push(UsageRecord {
                    id: format!("cx:{}:{}", self.file_key, ordinal),
                    timestamp_ms,
                    provider: Provider::Codex,
                    model: self.model.clone(),
                    project: self.cwd.clone(),
                    tokens,
                });
            }
            _ => {}
        }
    }
}

pub fn parse_file(path: &Path) -> Result<Vec<UsageRecord>> {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let file_key = name.trim_end_matches(".zst").trim_end_matches(".jsonl").to_string();
    let mut state = State::new(&file_key);
    lines::for_each_line(path, NEEDLES, |line| state.consume(line))?;
    Ok(state.records)
}

pub fn parse_bytes(data: &[u8], file_key: &str) -> Vec<UsageRecord> {
    let mut state = State::new(file_key);
    lines::for_each_line_in(data, NEEDLES, |line| state.consume(line));
    state.records
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token_count(ordinal: i64, total: (u64, u64, u64), last: (u64, u64, u64)) -> String {
        format!(
            r#"{{"timestamp":"2026-10-26T01:55:24.585Z","ordinal":{ordinal},"type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{},"cached_input_tokens":{},"output_tokens":{}}},"last_token_usage":{{"input_tokens":{},"cached_input_tokens":{},"output_tokens":{}}}}}}}}}"#,
            total.0, total.1, total.2, last.0, last.1, last.2
        )
    }

    const HEADER: &str = r#"{"timestamp":"2026-10-25T18:22:22.263Z","type":"session_meta","payload":{"id":"sess-1","cwd":"/work/app"}}
{"timestamp":"2026-10-25T18:22:22.512Z","type":"turn_context","payload":{"model":"gpt-5.1-codex","cwd":"/work/app"}}"#;

    #[test]
    fn uses_deltas_and_skips_duplicate_events() {
        let text = [
            HEADER.to_string(),
            token_count(1, (1000, 800, 50), (1000, 800, 50)),
            token_count(2, (1000, 800, 50), (1000, 800, 50)),
            token_count(3, (3000, 2500, 80), (2000, 1700, 30)),
        ]
        .join("\n");
        let records = parse_bytes(text.as_bytes(), "rollout-a");
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].tokens, TokenCounts { input: 200, cache_write: 0, cache_read: 800, output: 50 });
        assert_eq!(records[1].tokens, TokenCounts { input: 300, cache_write: 0, cache_read: 1700, output: 30 });
        assert!(records.iter().all(|r| r.model == "gpt-5.1-codex" && r.project.as_deref() == Some("/work/app")));
        assert_eq!(records[1].id, "cx:rollout-a:3");
    }

    #[test]
    fn forked_rollouts_sharing_a_session_id_stay_distinct() {
        // Two rollout files whose session_meta carries the same parent session
        // id, with ordinals that overlap: these are different responses.
        let dir = tempfile::tempdir().unwrap();
        let parent = r#"{"timestamp":"2026-10-25T18:22:22Z","type":"session_meta","payload":{"id":"parent","session_id":"parent"}}"#;
        for name in ["rollout-1-aaa.jsonl", "rollout-2-bbb.jsonl"] {
            std::fs::write(
                dir.path().join(name),
                [parent.to_string(), token_count(7, (100, 0, 10), (100, 0, 10))].join("\n"),
            )
            .unwrap();
        }
        let a = parse_file(&dir.path().join("rollout-1-aaa.jsonl")).unwrap();
        let b = parse_file(&dir.path().join("rollout-2-bbb.jsonl")).unwrap();
        assert_ne!(a[0].id, b[0].id);

        // The same file moved into archived_sessions keeps its id, so it merges.
        let archived = dir.path().join("archived");
        std::fs::create_dir(&archived).unwrap();
        std::fs::copy(dir.path().join("rollout-1-aaa.jsonl"), archived.join("rollout-1-aaa.jsonl")).unwrap();
        assert_eq!(parse_file(&archived.join("rollout-1-aaa.jsonl")).unwrap()[0].id, a[0].id);
    }

    #[test]
    fn resumed_session_counts_only_last_turn_first() {
        let text = [HEADER.to_string(), token_count(1, (900_000, 800_000, 9_000), (5000, 4000, 100))].join("\n");
        let records = parse_bytes(text.as_bytes(), "test");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].tokens.output, 100);
    }

    #[test]
    fn total_reset_falls_back_to_last() {
        let text = [
            HEADER.to_string(),
            token_count(1, (5000, 0, 500), (5000, 0, 500)),
            token_count(2, (1000, 0, 40), (1000, 0, 40)),
        ]
        .join("\n");
        let records = parse_bytes(text.as_bytes(), "test");
        assert_eq!(records.iter().map(|r| r.tokens.output).collect::<Vec<_>>(), [500, 40]);
    }
}
