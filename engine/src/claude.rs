//! Parses Claude Code session transcripts (`~/.claude/projects/**/*.jsonl`).
//!
//! Every assistant line carries the API `usage` block for its response.
//! Claude Code writes one line per content block, so a single response can
//! appear several times; records are keyed by message id + request id and
//! merged with a field-wise max.

use crate::lines;
use crate::usage::{parse_timestamp, Provider, TokenCounts, UsageRecord};
use anyhow::Result;
use serde::Deserialize;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::path::Path;

pub const NEEDLES: &[&[u8]] = &[b"\"usage\""];

#[derive(Deserialize)]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<String>,
    #[serde(rename = "requestId")]
    request_id: Option<String>,
    uuid: Option<String>,
    cwd: Option<String>,
    message: Option<Message>,
}

#[derive(Deserialize)]
struct Message {
    id: Option<String>,
    model: Option<String>,
    usage: Option<Usage>,
}

#[derive(Deserialize)]
struct Usage {
    input_tokens: Option<f64>,
    cache_creation_input_tokens: Option<f64>,
    cache_read_input_tokens: Option<f64>,
    output_tokens: Option<f64>,
}

fn count(value: Option<f64>) -> u64 {
    value.map_or(0, |v| v.max(0.0) as u64)
}

pub fn parse_line(line: &[u8]) -> Option<UsageRecord> {
    let parsed: Line = serde_json::from_slice(line).ok()?;
    if parsed.kind.as_deref() != Some("assistant") {
        return None;
    }
    let message = parsed.message?;
    let usage = message.usage?;
    let model = message.model?;
    if model.starts_with('<') {
        return None; // "<synthetic>" placeholder messages are not API calls
    }
    let timestamp_ms = parse_timestamp(parsed.timestamp.as_deref()?)?;
    let tokens = TokenCounts {
        input: count(usage.input_tokens),
        cache_write: count(usage.cache_creation_input_tokens),
        cache_read: count(usage.cache_read_input_tokens),
        output: count(usage.output_tokens),
    };
    if tokens.is_zero() {
        return None;
    }
    let message_id = message.id.or(parsed.uuid).unwrap_or_else(|| {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        line.hash(&mut hasher);
        format!("line-{:x}", hasher.finish())
    });
    Some(UsageRecord {
        id: format!("cc:{message_id}:{}", parsed.request_id.unwrap_or_default()),
        timestamp_ms,
        provider: Provider::ClaudeCode,
        model,
        project: parsed.cwd,
        tokens,
        machine: None,
    })
}

pub fn parse_file(path: &Path) -> Result<Vec<UsageRecord>> {
    let mut records: Vec<UsageRecord> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    lines::for_each_line(path, NEEDLES, |line| {
        let Some(record) = parse_line(line) else { return };
        if let Some(&i) = index.get(&record.id) {
            records[i].tokens = records[i].tokens.fieldwise_max(&record.tokens);
        } else {
            index.insert(record.id.clone(), records.len());
            records.push(record);
        }
    })?;
    Ok(records)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(id: &str, req: &str, model: &str, output: u64) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"2026-11-01T10:00:00.123Z","requestId":"{req}","cwd":"/tmp/proj","message":{{"id":"{id}","model":"{model}","content":[{{"type":"text","text":"hi"}}],"usage":{{"input_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":20000,"output_tokens":{output},"server_tool_use":{{"web_search_requests":0}}}}}}}}"#
        )
    }

    #[test]
    fn parses_usage_line() {
        let record = parse_line(line("msg_1", "req_1", "claude-opus-4-5-20251101", 100).as_bytes()).unwrap();
        assert_eq!(record.id, "cc:msg_1:req_1");
        assert_eq!(record.provider, Provider::ClaudeCode);
        assert_eq!(record.project.as_deref(), Some("/tmp/proj"));
        assert_eq!(record.tokens, TokenCounts { input: 5, cache_write: 1000, cache_read: 20000, output: 100 });
    }

    #[test]
    fn merges_streamed_duplicates_with_fieldwise_max() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.jsonl");
        let text = [
            line("msg_1", "req_1", "claude-opus-4-5", 3),
            line("msg_1", "req_1", "claude-opus-4-5", 250),
            line("msg_2", "req_2", "claude-opus-4-5", 7),
        ]
        .join("\n");
        std::fs::write(&path, text).unwrap();
        let records = parse_file(&path).unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].tokens.output, 250);
        assert_eq!(records[1].tokens.output, 7);
    }

    #[test]
    fn skips_synthetic_and_non_assistant_lines() {
        assert!(parse_line(line("m", "r", "<synthetic>", 5).as_bytes()).is_none());
        let user =
            r#"{"type":"user","timestamp":"2026-11-01T10:00:00Z","message":{"role":"user","content":"hi","usage":{}}}"#;
        assert!(parse_line(user.as_bytes()).is_none());
    }
}
