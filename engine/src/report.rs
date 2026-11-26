//! Aggregates usage into periods, timelines, breakdowns and comparisons.

use crate::catalog::{ModelCatalog, ModelOverride, ModelProfile, ModelTier};
use crate::emissions::{EmissionsModel, Footprint};
use crate::usage::{Provider, TokenCounts, UsageRecord};
use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveDateTime, TimeZone, Timelike, Utc};
use serde::Serialize;
use std::collections::HashMap;

/// A half-open time range in milliseconds since the epoch.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeRange {
    pub start_ms: i64,
    pub end_ms: i64,
}

impl TimeRange {
    pub fn contains(&self, ms: i64) -> bool {
        ms >= self.start_ms && ms < self.end_ms
    }
}

/// Converts a local wall-clock time to epoch ms, resolving DST gaps forward.
pub fn local_ms<Tz: TimeZone>(tz: &Tz, naive: NaiveDateTime) -> i64 {
    tz.from_local_datetime(&naive)
        .earliest()
        .or_else(|| tz.from_local_datetime(&(naive + Duration::hours(1))).earliest())
        .map(|d| d.timestamp_millis())
        .unwrap_or_else(|| naive.and_utc().timestamp_millis())
}

pub fn local_naive<Tz: TimeZone>(tz: &Tz, ms: i64) -> NaiveDateTime {
    let utc = DateTime::<Utc>::from_timestamp_millis(ms).unwrap_or_default();
    utc.with_timezone(tz).naive_local()
}

fn start_of_day<Tz: TimeZone>(tz: &Tz, date: NaiveDate) -> i64 {
    local_ms(tz, date.and_hms_opt(0, 0, 0).expect("midnight"))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Period {
    Today,
    Week,
    Month,
    Year,
    AllTime,
}

impl Period {
    pub const ALL: [Period; 5] = [Period::Today, Period::Week, Period::Month, Period::Year, Period::AllTime];

    pub fn id(self) -> &'static str {
        match self {
            Period::Today => "today",
            Period::Week => "week",
            Period::Month => "month",
            Period::Year => "year",
            Period::AllTime => "allTime",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Period::Today => "Today",
            Period::Week => "7 days",
            Period::Month => "30 days",
            Period::Year => "Year",
            Period::AllTime => "All time",
        }
    }

    /// Short name of the preceding period, for comparisons ("than yesterday").
    pub fn previous_label(self) -> Option<&'static str> {
        match self {
            Period::Today => Some("yesterday"),
            Period::Week => Some("last week"),
            Period::Month => Some("the 30 days before"),
            Period::Year => Some("the year before"),
            Period::AllTime => None,
        }
    }

    fn days(self) -> Option<i64> {
        match self {
            Period::Today => Some(1),
            Period::Week => Some(7),
            Period::Month => Some(30),
            Period::Year => Some(365),
            Period::AllTime => None,
        }
    }

    /// The period ending at the end of today, in local days. `None` for all time.
    pub fn interval<Tz: TimeZone>(self, now_ms: i64, tz: &Tz) -> Option<TimeRange> {
        let days = self.days()?;
        let today = local_naive(tz, now_ms).date();
        Some(TimeRange {
            start_ms: start_of_day(tz, today - Duration::days(days - 1)),
            end_ms: start_of_day(tz, today + Duration::days(1)),
        })
    }

    /// The preceding period of the same length, cut off at the same point
    /// (e.g. yesterday up to this time of day), so a part-way-through period
    /// is compared fairly.
    pub fn previous_interval<Tz: TimeZone>(self, now_ms: i64, tz: &Tz) -> Option<TimeRange> {
        let current = self.interval(now_ms, tz)?;
        let days = Duration::days(self.days()?);
        let start = local_ms(tz, local_naive(tz, current.start_ms) - days);
        let end = local_ms(tz, local_naive(tz, now_ms.min(current.end_ms)) - days);
        Some(TimeRange { start_ms: start, end_ms: end.max(start) })
    }

    /// Natural chart resolution for the period.
    pub fn bucket(self) -> Bucket {
        match self {
            Period::Today => Bucket::Hour,
            Period::Week | Period::Month => Bucket::Day,
            Period::Year => Bucket::Week,
            Period::AllTime => Bucket::Month,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Bucket {
    Hour,
    Day,
    /// Weeks start on Monday (ISO 8601).
    Week,
    Month,
}

impl Bucket {
    pub fn start<Tz: TimeZone>(self, ms: i64, tz: &Tz) -> i64 {
        let local = local_naive(tz, ms);
        let date = local.date();
        let naive = match self {
            Bucket::Hour => date.and_hms_opt(local.hour(), 0, 0),
            Bucket::Day => date.and_hms_opt(0, 0, 0),
            Bucket::Week => {
                (date - Duration::days(date.weekday().num_days_from_monday() as i64)).and_hms_opt(0, 0, 0)
            }
            Bucket::Month => date.with_day(1).and_then(|d| d.and_hms_opt(0, 0, 0)),
        };
        naive.map_or(ms, |n| local_ms(tz, n))
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub tokens: TokenCounts,
    pub footprint: Footprint,
    pub responses: u64,
}

impl Summary {
    fn add(&mut self, entry: &Entry) {
        self.tokens += entry.record.tokens;
        self.footprint += entry.footprint;
        self.responses += 1;
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelinePoint {
    /// Start of the bucket (hour, day, week or month).
    pub start_ms: i64,
    pub provider: Provider,
    pub co2_grams: f64,
    pub energy_wh: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelBreakdown {
    pub profile: ModelProfile,
    pub provider: Provider,
    pub summary: Summary,
}

impl ModelBreakdown {
    /// Central grams of CO2e per thousand output tokens.
    pub fn grams_per_thousand_output(&self) -> f64 {
        let output = self.summary.tokens.output;
        if output > 0 { self.summary.footprint.co2_grams.central / output as f64 * 1000.0 } else { 0.0 }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectBreakdown {
    pub path: String,
    pub summary: Summary,
}

/// "How bad it could have been": the same work without today's optimizations.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Counterfactual {
    /// What was actually emitted (central grams).
    pub actual: f64,
    /// The same tokens on 2024-era models of the same size.
    pub on_reference_models: f64,
    /// As above, with every cache read and write processed as uncached input.
    pub without_caching: f64,
}

#[derive(Clone, Debug)]
pub struct Entry {
    pub record: UsageRecord,
    pub profile: ModelProfile,
    pub footprint: Footprint,
}

/// All usage with each record's footprint already computed.
#[derive(Clone, Debug)]
pub struct UsageReport {
    pub entries: Vec<Entry>,
    pub model: EmissionsModel,
}

impl UsageReport {
    pub fn new(records: Vec<UsageRecord>, model: EmissionsModel, overrides: Vec<ModelOverride>) -> UsageReport {
        let catalog = ModelCatalog::from_records(&records, overrides);
        let mut profiles: HashMap<String, ModelProfile> = HashMap::new();
        let entries = records
            .into_iter()
            .map(|record| {
                let profile = profiles
                    .entry(record.model.clone())
                    .or_insert_with(|| catalog.profile(&record.model, record.timestamp_ms))
                    .clone();
                let footprint = model.footprint(&record.tokens, &profile);
                Entry { record, profile, footprint }
            })
            .collect();
        UsageReport { entries, model }
    }

    pub fn entries_in(&self, range: Option<TimeRange>) -> impl Iterator<Item = &Entry> {
        self.entries.iter().filter(move |e| range.is_none_or(|r| r.contains(e.record.timestamp_ms)))
    }

    pub fn first_record_ms(&self) -> Option<i64> {
        self.entries.iter().map(|e| e.record.timestamp_ms).min()
    }

    pub fn summary(&self, range: Option<TimeRange>) -> Summary {
        let mut summary = Summary::default();
        for entry in self.entries_in(range) {
            summary.add(entry);
        }
        summary
    }

    /// CO2 and energy per time bucket and provider, oldest first.
    pub fn timeline<Tz: TimeZone>(&self, range: Option<TimeRange>, bucket: Bucket, tz: &Tz) -> Vec<TimelinePoint> {
        let mut buckets: HashMap<(i64, Provider), TimelinePoint> = HashMap::new();
        for entry in self.entries_in(range) {
            let start_ms = bucket.start(entry.record.timestamp_ms, tz);
            let point = buckets.entry((start_ms, entry.record.provider)).or_insert(TimelinePoint {
                start_ms,
                provider: entry.record.provider,
                co2_grams: 0.0,
                energy_wh: 0.0,
            });
            point.co2_grams += entry.footprint.co2_grams.central;
            point.energy_wh += entry.footprint.energy_wh.central;
        }
        let mut points: Vec<TimelinePoint> = buckets.into_values().collect();
        points.sort_by(|a, b| a.start_ms.cmp(&b.start_ms).then(a.provider.cmp(&b.provider)));
        points
    }

    /// Per model, largest footprint first.
    pub fn by_model(&self, range: Option<TimeRange>) -> Vec<ModelBreakdown> {
        let mut buckets: HashMap<(Provider, String), ModelBreakdown> = HashMap::new();
        for entry in self.entries_in(range) {
            buckets
                .entry((entry.record.provider, entry.profile.id.clone()))
                .or_insert_with(|| ModelBreakdown {
                    profile: entry.profile.clone(),
                    provider: entry.record.provider,
                    summary: Summary::default(),
                })
                .summary
                .add(entry);
        }
        let mut rows: Vec<ModelBreakdown> = buckets.into_values().collect();
        rows.sort_by(|a, b| b.summary.footprint.co2_grams.central.total_cmp(&a.summary.footprint.co2_grams.central));
        rows
    }

    /// Per project directory, largest footprint first.
    pub fn by_project(&self, range: Option<TimeRange>) -> Vec<ProjectBreakdown> {
        let mut buckets: HashMap<String, Summary> = HashMap::new();
        for entry in self.entries_in(range) {
            let path = entry.record.project.clone().unwrap_or_else(|| "Unknown".to_string());
            buckets.entry(path).or_default().add(entry);
        }
        let mut rows: Vec<ProjectBreakdown> =
            buckets.into_iter().map(|(path, summary)| ProjectBreakdown { path, summary }).collect();
        rows.sort_by(|a, b| b.summary.footprint.co2_grams.central.total_cmp(&a.summary.footprint.co2_grams.central));
        rows
    }

    /// Central CO2 for the work done on `from`-tier models, and what the same
    /// tokens would have emitted on `to`-tier models of the same generation.
    pub fn what_if(&self, from: ModelTier, to: ModelTier, range: Option<TimeRange>) -> (f64, f64) {
        let (mut actual, mut alternative) = (0.0, 0.0);
        for entry in self.entries_in(range).filter(|e| e.profile.tier == from) {
            let mut swapped = entry.profile.clone();
            swapped.tier = to;
            actual += entry.footprint.co2_grams.central;
            alternative += self.model.footprint(&entry.record.tokens, &swapped).co2_grams.central;
        }
        (actual, alternative)
    }

    pub fn counterfactual(&self, range: Option<TimeRange>) -> Counterfactual {
        let mut result = Counterfactual::default();
        for entry in self.entries_in(range) {
            let mut reference = entry.profile.clone();
            reference.generation_ms = self.model.coefficients.reference_generation_ms;
            let t = entry.record.tokens;
            let uncached = TokenCounts { input: t.input + t.cache_read + t.cache_write, output: t.output, ..Default::default() };
            result.actual += entry.footprint.co2_grams.central;
            result.on_reference_models += entry.footprint.baseline_co2_grams;
            result.without_caching += self.model.footprint(&uncached, &reference).co2_grams.central;
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn ms(y: i32, m: u32, d: u32, h: u32, min: u32) -> i64 {
        Utc.with_ymd_and_hms(y, m, d, h, min, 0).unwrap().timestamp_millis()
    }

    fn record(id: &str, timestamp_ms: i64, provider: Provider, model: &str, project: &str, tokens: TokenCounts) -> UsageRecord {
        UsageRecord { id: id.into(), timestamp_ms, provider, model: model.into(), project: Some(project.into()), tokens }
    }

    fn output(n: u64) -> TokenCounts {
        TokenCounts { output: n, ..Default::default() }
    }

    #[test]
    fn aggregates_by_period_model_and_day() {
        let now = ms(2026, 11, 25, 15, 0);
        let old = now - 40 * 86_400_000;
        let records = vec![
            record("c", old, Provider::ClaudeCode, "claude-opus-4-5", "/p/one", output(1000)),
            record("a", now, Provider::ClaudeCode, "claude-opus-4-5", "/p/one", output(1000)),
            record("b", now, Provider::Codex, "gpt-5", "/p/two", output(500)),
        ];
        let report = UsageReport::new(records, EmissionsModel::default(), vec![]);
        assert_eq!(report.summary(Period::Today.interval(now, &Utc)).responses, 2);
        assert_eq!(report.summary(Period::Month.interval(now, &Utc)).responses, 2);
        assert_eq!(report.summary(None).responses, 3);
        assert_eq!(report.by_model(None).len(), 2);
        assert_eq!(report.by_model(None)[0].profile.id, "claude-opus-4-5");
        assert_eq!(report.by_project(None)[0].path, "/p/one");
        let providers: Vec<Provider> =
            report.timeline(Period::Today.interval(now, &Utc), Bucket::Day, &Utc).iter().map(|p| p.provider).collect();
        assert_eq!(providers, [Provider::ClaudeCode, Provider::Codex]);
    }

    #[test]
    fn timeline_buckets_by_hour() {
        let base = ms(2026, 11, 1, 9, 10);
        let records = [0, 20, 70]
            .iter()
            .map(|m| record(&format!("r{m}"), base + m * 60_000, Provider::ClaudeCode, "claude-opus-4-5", "/p", output(1000)))
            .collect();
        let points = UsageReport::new(records, EmissionsModel::default(), vec![]).timeline(None, Bucket::Hour, &Utc);
        assert_eq!(points.len(), 2);
        assert!((points[0].co2_grams - 2.0 * points[1].co2_grams).abs() < 1e-9);
        assert_eq!(Period::Today.bucket(), Bucket::Hour);
    }

    #[test]
    fn weeks_start_on_monday() {
        // Wednesday 2026-11-25 -> Monday 2026-11-23.
        assert_eq!(Bucket::Week.start(ms(2026, 11, 25, 15, 0), &Utc), ms(2026, 11, 23, 0, 0));
    }

    #[test]
    fn previous_today_stops_at_same_time_yesterday() {
        let now = ms(2026, 11, 25, 15, 0);
        let previous = Period::Today.previous_interval(now, &Utc).unwrap();
        assert_eq!(previous, TimeRange { start_ms: ms(2026, 11, 24, 0, 0), end_ms: ms(2026, 11, 24, 15, 0) });
        assert!(Period::AllTime.previous_interval(now, &Utc).is_none());
        let week = Period::Week.interval(now, &Utc).unwrap();
        let previous_week = Period::Week.previous_interval(now, &Utc).unwrap();
        assert_eq!(week.start_ms - previous_week.start_ms, 7 * 86_400_000);
    }

    #[test]
    fn smaller_tier_what_if_is_cheaper() {
        let tokens = TokenCounts { input: 100, cache_read: 10_000, output: 1_000, ..Default::default() };
        let report = UsageReport::new(
            vec![record("a", ms(2026, 1, 1, 0, 0), Provider::ClaudeCode, "claude-opus-4-5", "/p", tokens)],
            EmissionsModel::default(),
            vec![],
        );
        let (actual, alternative) = report.what_if(ModelTier::Large, ModelTier::Medium, None);
        assert!(actual > 0.0);
        assert!((alternative / actual - 0.45).abs() < 1e-9);
        assert_eq!(report.what_if(ModelTier::Small, ModelTier::Medium, None).0, 0.0);
    }

    #[test]
    fn counterfactual_steps_get_worse() {
        let tokens = TokenCounts { cache_read: 100_000, ..Default::default() };
        let report = UsageReport::new(
            vec![record("a", 1_790_000_000_000, Provider::ClaudeCode, "some-new-large-model-pro", "/p", tokens)],
            EmissionsModel::default(),
            vec![],
        );
        let c = report.counterfactual(None);
        assert!(c.actual > 0.0);
        assert!(c.on_reference_models > c.actual);
        // Cache reads cost 0.1x an uncached input token, so turning caching off is 10x.
        assert!((c.without_caching / c.on_reference_models - 10.0).abs() < 1e-9);
    }
}
