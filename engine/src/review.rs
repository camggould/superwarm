//! The numbers behind the December "Year in Carbon" review.

use crate::report::{local_ms, local_naive, Counterfactual, Summary, TimeRange, UsageReport};
use chrono::{Datelike, Duration, NaiveDate, TimeZone, Timelike};
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Share {
    pub name: String,
    pub grams: f64,
    pub fraction: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Day {
    /// Local midnight, ms since epoch.
    pub date_ms: i64,
    pub grams: f64,
}

/// Rough tokens in a novel: ~90k words at ~1.33 tokens per English word.
pub const TOKENS_PER_NOVEL: f64 = 120_000.0;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct YearInReview {
    pub year: i32,
    pub summary: Summary,
    pub project_count: usize,
    pub active_days: usize,
    pub longest_streak: usize,
    pub busiest_day: Option<Day>,
    /// Central grams by local hour of day, 0..=23.
    pub hourly: Vec<f64>,
    /// Central grams by month, January first; always 12 entries.
    pub monthly: Vec<f64>,
    pub top_model: Option<Share>,
    /// Basename of the top project directory. Never put this on shareable output.
    pub top_project: Option<Share>,
    /// The same year without newer models, and also without prompt caching.
    pub counterfactual: Counterfactual,
    pub total_grams: f64,
    pub dividend_grams: f64,
    pub novels_written: f64,
    pub tokens_read: u64,
    pub peak_hour: Option<u32>,
    /// Share of emissions between 10 pm and 6 am.
    pub night_share: f64,
    /// 1-based month with the most emissions.
    pub busiest_month: Option<u32>,
}

impl YearInReview {
    pub fn new<Tz: TimeZone>(report: &UsageReport, year: i32, tz: &Tz) -> YearInReview {
        let jan1 = |y: i32| NaiveDate::from_ymd_opt(y, 1, 1).and_then(|d| d.and_hms_opt(0, 0, 0)).expect("valid date");
        let range = TimeRange { start_ms: local_ms(tz, jan1(year)), end_ms: local_ms(tz, jan1(year + 1)) };

        let mut summary = Summary::default();
        let mut hourly = vec![0.0; 24];
        let mut monthly = vec![0.0; 12];
        let mut by_day: BTreeMap<NaiveDate, f64> = BTreeMap::new();
        let mut by_model: HashMap<String, f64> = HashMap::new();
        let mut by_project: HashMap<String, f64> = HashMap::new();

        for entry in report.entries_in(Some(range)) {
            let grams = entry.footprint.co2_grams.central;
            let local = local_naive(tz, entry.record.timestamp_ms);
            summary.tokens += entry.record.tokens;
            summary.footprint += entry.footprint;
            summary.responses += 1;
            hourly[local.hour() as usize] += grams;
            monthly[local.month0() as usize] += grams;
            *by_day.entry(local.date()).or_default() += grams;
            *by_model.entry(entry.profile.id.clone()).or_default() += grams;
            if let Some(project) = &entry.record.project {
                let name = std::path::Path::new(project)
                    .file_name()
                    .map_or_else(|| project.clone(), |n| n.to_string_lossy().into_owned());
                *by_project.entry(name).or_default() += grams;
            }
        }

        let total = summary.footprint.co2_grams.central;
        let top = |buckets: &HashMap<String, f64>| -> Option<Share> {
            if total <= 0.0 {
                return None;
            }
            buckets
                .iter()
                .max_by(|a, b| a.1.total_cmp(b.1).then_with(|| b.0.cmp(a.0)))
                .map(|(name, grams)| Share { name: name.clone(), grams: *grams, fraction: grams / total })
        };

        let mut longest = 0;
        let mut run = 0;
        let mut previous: Option<NaiveDate> = None;
        for day in by_day.keys() {
            run = if previous.is_some_and(|p| p + Duration::days(1) == *day) { run + 1 } else { 1 };
            longest = longest.max(run);
            previous = Some(*day);
        }

        let busiest_day = by_day
            .iter()
            .max_by(|a, b| a.1.total_cmp(b.1))
            .map(|(date, grams)| Day { date_ms: local_ms(tz, date.and_hms_opt(0, 0, 0).expect("midnight")), grams: *grams });
        let argmax = |values: &[f64]| -> Option<usize> {
            (total > 0.0).then(|| values.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).map(|(i, _)| i)).flatten()
        };
        let night: f64 = (22..24).chain(0..6).map(|h| hourly[h]).sum();

        YearInReview {
            year,
            project_count: by_project.len(),
            active_days: by_day.len(),
            longest_streak: longest,
            busiest_day,
            top_model: top(&by_model),
            top_project: top(&by_project),
            counterfactual: report.counterfactual(Some(range)),
            total_grams: total,
            dividend_grams: summary.footprint.efficiency_dividend_grams(),
            novels_written: summary.tokens.output as f64 / TOKENS_PER_NOVEL,
            tokens_read: summary.tokens.input + summary.tokens.cache_write + summary.tokens.cache_read,
            peak_hour: argmax(&hourly).map(|h| h as u32),
            night_share: if total > 0.0 { night / total } else { 0.0 },
            busiest_month: argmax(&monthly).map(|m| m as u32 + 1),
            summary,
            hourly,
            monthly,
        }
    }
}

/// The review is offered from December 1 through January 15 (for the year just ended).
pub fn seasonal_year<Tz: TimeZone>(now_ms: i64, tz: &Tz) -> Option<i32> {
    let date = local_naive(tz, now_ms).date();
    match (date.month(), date.day()) {
        (12, _) => Some(date.year()),
        (1, d) if d <= 15 => Some(date.year() - 1),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emissions::EmissionsModel;
    use crate::usage::{Provider, TokenCounts, UsageRecord};
    use chrono::Utc;

    fn ms(y: i32, m: u32, d: u32, h: u32) -> i64 {
        Utc.with_ymd_and_hms(y, m, d, h, 0, 0).unwrap().timestamp_millis()
    }

    fn record(id: &str, t: i64, model: &str, project: &str, output: u64) -> UsageRecord {
        UsageRecord {
            id: id.into(),
            timestamp_ms: t,
            provider: Provider::ClaudeCode,
            model: model.into(),
            project: Some(project.into()),
            tokens: TokenCounts { output, ..Default::default() },
        }
    }

    #[test]
    fn summarises_the_year() {
        let records = vec![
            record("e", ms(2025, 12, 31, 10), "claude-opus-4-5", "/code/app", 1000), // previous year
            record("a", ms(2026, 3, 1, 23), "claude-opus-4-5", "/code/app", 1000),
            record("b", ms(2026, 3, 2, 23), "claude-opus-4-5", "/code/app", 3000),
            record("c", ms(2026, 3, 3, 10), "claude-haiku-4-5", "/code/site", 1000),
            record("d", ms(2026, 3, 10, 10), "claude-opus-4-5", "/code/app", 1000),
        ];
        let report = UsageReport::new(records, EmissionsModel::default(), vec![]);
        let r = YearInReview::new(&report, 2026, &Utc);
        assert_eq!(r.summary.responses, 4);
        assert_eq!(r.active_days, 4);
        assert_eq!(r.longest_streak, 3);
        assert_eq!(r.project_count, 2);
        assert_eq!(r.busiest_month, Some(3));
        assert_eq!(r.peak_hour, Some(23));
        assert!(r.night_share > 0.5);
        assert_eq!(r.busiest_day.as_ref().unwrap().date_ms, ms(2026, 3, 2, 0));
        assert_eq!(r.top_model.as_ref().unwrap().name, "claude-opus-4-5");
        assert_eq!(r.top_project.as_ref().unwrap().name, "app");
        assert!((r.monthly.iter().sum::<f64>() - r.total_grams).abs() < 1e-9);
    }

    #[test]
    fn empty_year() {
        let report = UsageReport::new(vec![], EmissionsModel::default(), vec![]);
        let r = YearInReview::new(&report, 2026, &Utc);
        assert_eq!(r.total_grams, 0.0);
        assert_eq!(r.peak_hour, None);
        assert!(r.top_model.is_none());
        assert_eq!(r.longest_streak, 0);
    }

    #[test]
    fn season_runs_december_to_mid_january() {
        assert_eq!(seasonal_year(ms(2026, 11, 30, 12), &Utc), None);
        assert_eq!(seasonal_year(ms(2026, 12, 1, 12), &Utc), Some(2026));
        assert_eq!(seasonal_year(ms(2027, 1, 15, 12), &Utc), Some(2026));
        assert_eq!(seasonal_year(ms(2027, 1, 16, 12), &Utc), None);
    }
}
