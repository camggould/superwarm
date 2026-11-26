//! The JSON document the macOS app renders: every period, comparison and
//! the year in review, computed in one pass over the logs.

use crate::catalog::{GenerationSource, ModelTier};
use crate::citations::{self, Citation};
use crate::emissions::{EnergyCoefficients, GridSettings};
use crate::equivalents::{self, Equivalent, EquivalentSettings};
use crate::report::{Bucket, Period, Summary, TimeRange, TimelinePoint, UsageReport};
use crate::review::{seasonal_year, YearInReview};
use crate::usage::Provider;
use chrono::{Datelike, TimeZone};
use serde::Serialize;

/// Bumped whenever the shape changes incompatibly; the app checks it.
pub const SCHEMA_VERSION: u32 = 1;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub schema_version: u32,
    pub engine_version: &'static str,
    pub generated_at_ms: i64,
    pub scan: ScanInfo,
    pub grid: GridSettings,
    pub equivalent_settings: EquivalentSettings,
    pub first_record_ms: Option<i64>,
    pub periods: Vec<PeriodSnapshot>,
    pub equivalents: Vec<Equivalent>,
    pub citations: &'static [Citation],
    pub coefficients: EnergyCoefficients,
    /// Set from December 1 to January 15: the year the review covers.
    pub seasonal_year: Option<i32>,
    pub review: YearInReview,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ScanInfo {
    pub files_found: usize,
    pub files_parsed: usize,
    pub responses: usize,
    pub issues: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeriodSnapshot {
    pub period: &'static str,
    pub label: &'static str,
    pub range: Option<TimeRange>,
    pub bucket: Bucket,
    pub summary: Summary,
    pub timeline: Vec<TimelinePoint>,
    pub models: Vec<ModelRow>,
    /// The same stretch of the previous period, when the logs cover it.
    pub previous: Option<PreviousPeriod>,
    /// What the large-model work would emit on mid-size models.
    pub tier_tip: Option<TierTip>,
    /// Ids of the three headline equivalents for this period's total.
    pub headline: Vec<&'static str>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelRow {
    pub id: String,
    pub display_name: String,
    pub provider: Provider,
    pub tier: ModelTier,
    pub generation_ms: i64,
    pub generation_source: GenerationSource,
    pub summary: Summary,
    pub grams_per_thousand_output: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviousPeriod {
    pub label: &'static str,
    pub co2_grams: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TierTip {
    pub actual: f64,
    pub alternative: f64,
    /// All large-model work was Claude Opus, so the tip can say "Sonnet instead of Opus".
    pub all_opus: bool,
}

pub fn build<Tz: TimeZone>(
    report: &UsageReport,
    scan: ScanInfo,
    equivalent_settings: EquivalentSettings,
    review_year: Option<i32>,
    now_ms: i64,
    tz: &Tz,
) -> Snapshot {
    let grid = report.model.grid;
    let first_record_ms = report.first_record_ms();
    let periods = Period::ALL
        .iter()
        .map(|&period| period_snapshot(report, period, first_record_ms, &equivalent_settings, now_ms, tz))
        .collect();
    let seasonal = seasonal_year(now_ms, tz);
    let year = review_year.or(seasonal).unwrap_or_else(|| crate::report::local_naive(tz, now_ms).year());
    Snapshot {
        schema_version: SCHEMA_VERSION,
        engine_version: env!("CARGO_PKG_VERSION"),
        generated_at_ms: now_ms,
        scan,
        grid,
        equivalent_settings,
        first_record_ms,
        periods,
        equivalents: equivalents::all(&grid, &equivalent_settings),
        citations: citations::ALL,
        coefficients: report.model.coefficients.clone(),
        seasonal_year: seasonal,
        review: YearInReview::new(report, year, tz),
    }
}

fn period_snapshot<Tz: TimeZone>(
    report: &UsageReport,
    period: Period,
    first_record_ms: Option<i64>,
    equivalent_settings: &EquivalentSettings,
    now_ms: i64,
    tz: &Tz,
) -> PeriodSnapshot {
    let range = period.interval(now_ms, tz);
    let summary = report.summary(range);
    let models: Vec<ModelRow> = report
        .by_model(range)
        .into_iter()
        .map(|m| ModelRow {
            grams_per_thousand_output: m.grams_per_thousand_output(),
            id: m.profile.id,
            display_name: m.profile.display_name,
            provider: m.provider,
            tier: m.profile.tier,
            generation_ms: m.profile.generation_ms,
            generation_source: m.profile.generation_source,
            summary: m.summary,
        })
        .collect();

    let previous = match (period.previous_label(), period.previous_interval(now_ms, tz), first_record_ms) {
        (Some(label), Some(previous_range), Some(first)) if first <= previous_range.start_ms => {
            let co2_grams = report.summary(Some(previous_range)).footprint.co2_grams.central;
            (co2_grams > 0.0).then_some(PreviousPeriod { label, co2_grams })
        }
        _ => None,
    };

    let (actual, alternative) = report.what_if(ModelTier::Large, ModelTier::Medium, range);
    let tier_tip = (actual > 0.0).then(|| TierTip {
        actual,
        alternative,
        all_opus: models.iter().filter(|m| m.tier == ModelTier::Large).all(|m| m.id.contains("opus")),
    });

    let headline = equivalents::headline(summary.footprint.co2_grams.central, &report.model.grid, equivalent_settings)
        .into_iter()
        .map(|e| e.id)
        .collect();

    PeriodSnapshot {
        period: period.id(),
        label: period.label(),
        range,
        bucket: period.bucket(),
        timeline: report.timeline(range, period.bucket(), tz),
        summary,
        models,
        previous,
        tier_tip,
        headline,
    }
}
