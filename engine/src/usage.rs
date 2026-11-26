//! Usage records recovered from local coding-agent logs.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::ops::{Add, AddAssign};

/// The coding tool a usage record came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Provider {
    ClaudeCode,
    Codex,
}

impl Provider {
    pub const ALL: [Provider; 2] = [Provider::ClaudeCode, Provider::Codex];

    pub fn display_name(self) -> &'static str {
        match self {
            Provider::ClaudeCode => "Claude Code",
            Provider::Codex => "Codex",
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Provider::ClaudeCode => "claudeCode",
            Provider::Codex => "codex",
        }
    }
}

/// Token counts for one model call, split by how much compute each kind costs.
///
/// `input` counts only *uncached* prompt tokens. Prompt-cache reads and writes
/// are tracked separately because they cost very different amounts of compute.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenCounts {
    pub input: u64,
    pub cache_write: u64,
    pub cache_read: u64,
    pub output: u64,
}

impl TokenCounts {
    pub fn total(&self) -> u64 {
        self.input + self.cache_write + self.cache_read + self.output
    }

    pub fn is_zero(&self) -> bool {
        self.total() == 0
    }

    /// Field-wise maximum. Used to merge duplicate log lines for the same API response.
    pub fn fieldwise_max(&self, other: &TokenCounts) -> TokenCounts {
        TokenCounts {
            input: self.input.max(other.input),
            cache_write: self.cache_write.max(other.cache_write),
            cache_read: self.cache_read.max(other.cache_read),
            output: self.output.max(other.output),
        }
    }
}

impl Add for TokenCounts {
    type Output = TokenCounts;
    fn add(self, rhs: TokenCounts) -> TokenCounts {
        TokenCounts {
            input: self.input + rhs.input,
            cache_write: self.cache_write + rhs.cache_write,
            cache_read: self.cache_read + rhs.cache_read,
            output: self.output + rhs.output,
        }
    }
}

impl AddAssign for TokenCounts {
    fn add_assign(&mut self, rhs: TokenCounts) {
        *self = *self + rhs;
    }
}

/// One billed model response, as recovered from a local log file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageRecord {
    /// Globally unique key used to deduplicate the same response logged twice.
    pub id: String,
    /// Milliseconds since the Unix epoch, UTC.
    pub timestamp_ms: i64,
    pub provider: Provider,
    pub model: String,
    pub project: Option<String>,
    pub tokens: TokenCounts,
}

impl UsageRecord {
    pub fn timestamp(&self) -> DateTime<Utc> {
        DateTime::from_timestamp_millis(self.timestamp_ms).unwrap_or_default()
    }
}

/// Parses an RFC 3339 / ISO 8601 timestamp (with or without fractional seconds).
pub fn parse_timestamp(text: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(text).ok().map(|d| d.timestamp_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_timestamps_with_and_without_fractions() {
        assert_eq!(parse_timestamp("2026-11-01T10:00:00Z"), Some(1_793_527_200_000));
        assert_eq!(parse_timestamp("2026-11-01T10:00:00.123Z"), Some(1_793_527_200_123));
        assert_eq!(parse_timestamp("not a date"), None);
    }

    #[test]
    fn adds_and_merges_token_counts() {
        let a = TokenCounts { input: 1, cache_write: 2, cache_read: 3, output: 4 };
        let b = TokenCounts { input: 5, cache_write: 0, cache_read: 1, output: 9 };
        assert_eq!((a + b).total(), 25);
        assert_eq!(a.fieldwise_max(&b), TokenCounts { input: 5, cache_write: 2, cache_read: 3, output: 9 });
    }
}
