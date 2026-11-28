//! Model size tiers and release generations.

use crate::usage::UsageRecord;
use chrono::{TimeZone, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

/// A rough size class. Vendors don't publish parameter counts for closed
/// models, so the tier is inferred from the product line.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelTier {
    Large,
    Medium,
    Small,
    Unknown,
}

impl ModelTier {
    pub fn display_name(self) -> &'static str {
        match self {
            ModelTier::Large => "Large",
            ModelTier::Medium => "Medium",
            ModelTier::Small => "Small",
            ModelTier::Unknown => "Unknown",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GenerationSource {
    /// Public release month from the built-in catalog.
    Catalog,
    /// Not in the catalog: the earliest time this model shows up in the logs.
    /// A *late* bound on the release date when log history is short.
    FirstSeen,
    /// From the user's `models.json` override file.
    Override,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProfile {
    pub id: String,
    pub display_name: String,
    pub tier: ModelTier,
    /// When the model (and its serving stack) became available, ms since epoch.
    pub generation_ms: i64,
    pub generation_source: GenerationSource,
}

/// A user-supplied correction: `[{"prefix": "claude-opus-5", "tier": "large", "released": "2026-05"}]`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelOverride {
    pub prefix: String,
    pub tier: Option<ModelTier>,
    /// "YYYY-MM"
    pub released: Option<String>,
}

impl ModelOverride {
    fn release_ms(&self) -> Option<i64> {
        let released = self.released.as_deref()?;
        let mut parts = released.split('-').filter_map(|p| p.parse::<u32>().ok());
        let (year, month) = (parts.next()?, parts.next()?);
        mid_month_ms(year as i32, month)
    }

    /// `~/Library/Application Support/Superwarm/models.json` on macOS,
    /// `~/.config/superwarm/models.json` on Linux.
    pub fn default_path() -> Option<PathBuf> {
        crate::paths::config_dir().map(|d| d.join("models.json"))
    }

    pub fn load(path: &Path) -> Vec<ModelOverride> {
        std::fs::read(path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }
}

fn mid_month_ms(year: i32, month: u32) -> Option<i64> {
    Utc.with_ymd_and_hms(year, month, 15, 0, 0, 0).single().map(|d| d.timestamp_millis())
}

/// Public release months of known models, matched by prefix, longest first.
const ENTRIES: &[(&str, i32, u32)] = &[
    // Anthropic
    ("claude-3-opus", 2024, 3),
    ("claude-3-sonnet", 2024, 3),
    ("claude-3-haiku", 2024, 3),
    ("claude-3-5-sonnet", 2024, 6),
    ("claude-3-5-haiku", 2024, 11),
    ("claude-3-7-sonnet", 2025, 2),
    ("claude-sonnet-4", 2025, 5),
    ("claude-opus-4", 2025, 5),
    ("claude-opus-4-1", 2025, 8),
    ("claude-sonnet-4-5", 2025, 9),
    ("claude-haiku-4-5", 2025, 10),
    ("claude-opus-4-5", 2025, 11),
    // OpenAI
    ("gpt-4o", 2024, 5),
    ("gpt-4o-mini", 2024, 7),
    ("o1", 2024, 12),
    ("o3-mini", 2025, 1),
    ("o3", 2025, 4),
    ("o4-mini", 2025, 4),
    ("gpt-4.1", 2025, 4),
    ("codex-mini", 2025, 5),
    ("gpt-5", 2025, 8),
    ("gpt-5-codex", 2025, 9),
    ("gpt-5.1", 2025, 11),
    // Google
    ("gemini-2.5-pro", 2025, 3),
    ("gemini-2.5-flash", 2025, 4),
    ("gemini-3-pro", 2025, 11),
    ("gemini-3-flash", 2025, 12),
    ("gemini-4-neon", 2026, 11),
];

static SORTED_ENTRIES: LazyLock<Vec<(&'static str, i32, u32)>> = LazyLock::new(|| {
    let mut entries = ENTRIES.to_vec();
    entries.sort_by_key(|e| std::cmp::Reverse(e.0.len()));
    entries
});

static VERSION_SUFFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"-v\d+(:\d+)?$").unwrap());
static COMPACT_DATE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[-@]\d{8}$").unwrap());
static DASHED_DATE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"-\d{4}-\d{2}-\d{2}$").unwrap());
static BRACKETS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[.*\]$").unwrap());
static O_SERIES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^o\d").unwrap());

/// Lowercases and strips dated snapshot suffixes and Bedrock/Vertex style
/// prefixes: `anthropic.claude-haiku-4-5-20251001-v1:0` -> `claude-haiku-4-5`.
pub fn normalize(model: &str) -> String {
    let mut id = model.to_lowercase();
    if let Some(slash) = id.rfind('/') {
        id = id[slash + 1..].to_string();
    }
    for vendor in ["anthropic.", "openai.", "us.anthropic.", "eu.anthropic."] {
        if let Some(rest) = id.strip_prefix(vendor) {
            id = rest.to_string();
        }
    }
    for pattern in [&*VERSION_SUFFIX, &*COMPACT_DATE, &*DASHED_DATE, &*BRACKETS] {
        id = pattern.replace(&id, "").into_owned();
    }
    id
}

pub fn tier(id: &str) -> ModelTier {
    // Checked first: "gemini" contains "mini". Gemini 4 names its tiers after
    // elements: Carbon (largest), Neon, Hydrogen (fastest).
    if id.starts_with("gemini-") {
        return if ["flash", "lite", "hydrogen", "nano"].iter().any(|m| id.contains(m)) {
            ModelTier::Small
        } else if id.contains("neon") {
            ModelTier::Medium
        } else if ["pro", "ultra", "carbon"].iter().any(|m| id.contains(m)) {
            ModelTier::Large
        } else {
            ModelTier::Unknown
        };
    }
    const SMALL: [&str; 9] = ["haiku", "mini", "nano", "flash", "lite", "small", "8b", "7b", "3b"];
    if SMALL.iter().any(|m| id.contains(m)) {
        return ModelTier::Small;
    }
    if id.contains("sonnet") || id.contains("medium") {
        return ModelTier::Medium;
    }
    if id.contains("opus") || id.contains("pro") || id.contains("large") {
        return ModelTier::Large;
    }
    // OpenAI flagship lines without a size suffix: gpt-4o, gpt-5, o3, ...
    if id.starts_with("gpt-") || O_SERIES.is_match(id) {
        return ModelTier::Large;
    }
    ModelTier::Unknown
}

/// A prefix matches only on a token boundary and never swallows a newer
/// version number: `claude-opus-4` matches `claude-opus-4-thinking` but not
/// `claude-opus-4-8`, and `gpt-5` matches neither `gpt-5.5` nor `gpt-50`.
pub fn matches(id: &str, prefix: &str) -> bool {
    let Some(rest) = id.strip_prefix(prefix) else { return false };
    let mut chars = rest.chars();
    match chars.next() {
        None => true,
        Some('-') => !chars.next().is_some_and(|c| c.is_ascii_digit()),
        Some(_) => false,
    }
}

#[derive(Clone, Debug, Default)]
pub struct ModelCatalog {
    /// Earliest timestamp each normalized model id appears in the logs.
    pub first_seen: HashMap<String, i64>,
    pub overrides: Vec<ModelOverride>,
}

impl ModelCatalog {
    pub fn new(first_seen: HashMap<String, i64>, mut overrides: Vec<ModelOverride>) -> ModelCatalog {
        overrides.sort_by_key(|o| std::cmp::Reverse(o.prefix.len()));
        ModelCatalog { first_seen, overrides }
    }

    pub fn from_records(records: &[UsageRecord], overrides: Vec<ModelOverride>) -> ModelCatalog {
        let mut seen: HashMap<String, i64> = HashMap::new();
        for record in records {
            let id = normalize(&record.model);
            let entry = seen.entry(id).or_insert(record.timestamp_ms);
            *entry = (*entry).min(record.timestamp_ms);
        }
        ModelCatalog::new(seen, overrides)
    }

    pub fn profile(&self, model: &str, fallback_ms: i64) -> ModelProfile {
        let id = normalize(model);
        let model_override = self.overrides.iter().find(|o| matches(&id, &o.prefix.to_lowercase()));
        let tier = model_override.and_then(|o| o.tier).unwrap_or_else(|| tier(&id));
        if let Some(released) = model_override.and_then(ModelOverride::release_ms) {
            return ModelProfile {
                display_name: id.clone(),
                id,
                tier,
                generation_ms: released,
                generation_source: GenerationSource::Override,
            };
        }
        if let Some(&(_, year, month)) = SORTED_ENTRIES.iter().find(|e| matches(&id, e.0)) {
            if let Some(released) = mid_month_ms(year, month) {
                return ModelProfile {
                    display_name: id.clone(),
                    id,
                    tier,
                    generation_ms: released,
                    generation_source: GenerationSource::Catalog,
                };
            }
        }
        ModelProfile {
            display_name: id.clone(),
            generation_ms: self.first_seen.get(&id).copied().unwrap_or(fallback_ms),
            id,
            tier,
            generation_source: GenerationSource::FirstSeen,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes() {
        for (raw, expected) in [
            ("claude-haiku-4-5-20251001", "claude-haiku-4-5"),
            ("anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5"),
            ("openai/gpt-4o-2024-08-06", "gpt-4o"),
            ("claude-opus-5-5[1m]", "claude-opus-5-5"),
        ] {
            assert_eq!(normalize(raw), expected, "{raw}");
        }
    }

    #[test]
    fn infers_tier() {
        use ModelTier::*;
        for (id, expected) in [
            ("claude-opus-4-5", Large),
            ("claude-sonnet-4-5", Medium),
            ("claude-haiku-4-5", Small),
            ("gpt-5", Large),
            ("gpt-4o-mini", Small),
            ("gpt-4.1-nano", Small),
            ("o3", Large),
            ("gemini-2.5-flash", Small),
            ("gemini-2.5-pro", Large),
            ("gemini-3-pro-preview", Large),
            ("gemini-4-carbon", Large),
            ("gemini-4-neon", Medium),
            ("gemini-4-hydrogen", Small),
            ("codex-auto-review", Unknown),
        ] {
            assert_eq!(tier(id), expected, "{id}");
        }
    }

    #[test]
    fn prefix_never_swallows_newer_version() {
        assert!(matches("claude-opus-4-thinking", "claude-opus-4"));
        assert!(!matches("claude-opus-4-8", "claude-opus-4"));
        assert!(!matches("gpt-5.5", "gpt-5"));
        assert!(!matches("gpt-50", "gpt-5"));
    }

    #[test]
    fn uses_catalog_then_first_seen() {
        let seen = 1_790_000_000_000;
        let catalog = ModelCatalog::new(HashMap::from([("claude-opus-4-8".to_string(), seen)]), vec![]);
        let known = catalog.profile("claude-opus-4-5-20251101", 0);
        assert_eq!(known.generation_source, GenerationSource::Catalog);
        assert_eq!(known.generation_ms, mid_month_ms(2025, 11).unwrap());
        let unknown = catalog.profile("claude-opus-4-8", 0);
        assert_eq!(unknown.generation_source, GenerationSource::FirstSeen);
        assert_eq!(unknown.generation_ms, seen);
    }

    #[test]
    fn override_wins() {
        let catalog = ModelCatalog::new(
            HashMap::new(),
            vec![ModelOverride {
                prefix: "gpt-6".into(),
                tier: Some(ModelTier::Medium),
                released: Some("2026-03".into()),
            }],
        );
        let profile = catalog.profile("gpt-6-luna", 0);
        assert_eq!(profile.tier, ModelTier::Medium);
        assert_eq!(profile.generation_source, GenerationSource::Override);
    }
}
