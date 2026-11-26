//! The physical model: tokens -> energy -> CO2e, with uncertainty.
//! Every default is derived in docs/METHODOLOGY.md.

use crate::catalog::{ModelProfile, ModelTier};
use crate::usage::TokenCounts;
use serde::Serialize;
use std::ops::{Add, AddAssign, Mul};

/// A best estimate with an approximate 90% interval.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize)]
pub struct Interval {
    pub low: f64,
    pub central: f64,
    pub high: f64,
}

impl Add for Interval {
    type Output = Interval;
    /// Summed bound-by-bound: the same coefficients apply to every record, so
    /// errors are fully correlated and don't shrink as records add up.
    fn add(self, b: Interval) -> Interval {
        Interval { low: self.low + b.low, central: self.central + b.central, high: self.high + b.high }
    }
}

impl AddAssign for Interval {
    fn add_assign(&mut self, b: Interval) {
        *self = *self + b;
    }
}

impl Mul<f64> for Interval {
    type Output = Interval;
    fn mul(self, k: f64) -> Interval {
        Interval { low: self.low * k, central: self.central * k, high: self.high * k }
    }
}

/// A central value with a multiplicative 90% spread: `central / spread ..= central * spread`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Coefficient {
    pub central: f64,
    pub spread: f64,
}

impl Coefficient {
    pub const fn new(central: f64, spread: f64) -> Coefficient {
        Coefficient { central, spread }
    }

    fn log_spread(&self) -> f64 {
        self.spread.ln()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnergyCoefficients {
    /// IT energy (accelerators + host + idle capacity, before PUE) in Wh per
    /// 1,000 output tokens for a large model of the reference generation.
    pub base_wh_per_1k_output: Coefficient,
    pub tier_large: Coefficient,
    pub tier_medium: Coefficient,
    pub tier_small: Coefficient,
    pub tier_unknown: Coefficient,
    /// Uncached input (prefill) token relative to an output (decode) token.
    pub input_to_output_ratio: Coefficient,
    /// Prompt-cache read relative to an uncached input token.
    pub cache_read_to_input_ratio: Coefficient,
    /// Prompt-cache write relative to an uncached input token.
    pub cache_write_to_input_ratio: Coefficient,
    /// Change in energy per token per year of model generation (0.6 = 1.67x better a year).
    pub annual_efficiency_factor: Coefficient,
    /// The generation the baseline is calibrated against (mid-2024), ms since epoch.
    pub reference_generation_ms: i64,
    /// Trend extrapolation is clamped to this many years either side of the reference.
    pub max_trend_years: f64,
}

impl Default for EnergyCoefficients {
    fn default() -> Self {
        EnergyCoefficients {
            base_wh_per_1k_output: Coefficient::new(0.9, 2.8),
            tier_large: Coefficient::new(1.0, 1.0),
            tier_medium: Coefficient::new(0.45, 1.8),
            tier_small: Coefficient::new(0.12, 2.2),
            tier_unknown: Coefficient::new(0.45, 3.0),
            input_to_output_ratio: Coefficient::new(0.2, 2.0),
            cache_read_to_input_ratio: Coefficient::new(0.1, 2.5),
            cache_write_to_input_ratio: Coefficient::new(1.0, 1.3),
            annual_efficiency_factor: Coefficient::new(0.6, 1.6),
            reference_generation_ms: 1_719_792_000_000, // 2024-07-01
            max_trend_years: 4.0,
        }
    }
}

impl EnergyCoefficients {
    pub fn tier(&self, tier: ModelTier) -> Coefficient {
        match tier {
            ModelTier::Large => self.tier_large,
            ModelTier::Medium => self.tier_medium,
            ModelTier::Small => self.tier_small,
            ModelTier::Unknown => self.tier_unknown,
        }
    }
}

/// Where inference runs: user-adjustable.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GridSettings {
    /// Grams of CO2e per kWh drawn by the data centre.
    pub grams_co2_per_kwh: f64,
    /// Power Usage Effectiveness: facility energy / IT energy.
    pub pue: f64,
}

impl Default for GridSettings {
    fn default() -> Self {
        GridSettings { grams_co2_per_kwh: GRID_US_AVERAGE, pue: 1.15 }
    }
}

/// US average, EPA eGRID2022 (~823 lb/MWh).
pub const GRID_US_AVERAGE: f64 = 373.0;
/// World average, Ember 2025.
pub const GRID_WORLD_AVERAGE: f64 = 473.0;
/// Hydro/nuclear-heavy grids.
pub const GRID_LOW_CARBON: f64 = 50.0;

/// Energy and carbon for one record or an aggregate.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Footprint {
    /// Facility-level energy (Wh), including PUE.
    pub energy_wh: Interval,
    pub co2_grams: Interval,
    /// Central CO2 if the same tokens had run on a reference-generation (2024) model of the same tier.
    pub baseline_co2_grams: f64,
}

impl Footprint {
    /// CO2 avoided compared with running the same work on 2024-era models.
    pub fn efficiency_dividend_grams(&self) -> f64 {
        self.baseline_co2_grams - self.co2_grams.central
    }
}

impl Add for Footprint {
    type Output = Footprint;
    fn add(self, b: Footprint) -> Footprint {
        Footprint {
            energy_wh: self.energy_wh + b.energy_wh,
            co2_grams: self.co2_grams + b.co2_grams,
            baseline_co2_grams: self.baseline_co2_grams + b.baseline_co2_grams,
        }
    }
}

impl AddAssign for Footprint {
    fn add_assign(&mut self, b: Footprint) {
        *self = *self + b;
    }
}

pub const MS_PER_YEAR: f64 = 365.25 * 86_400.0 * 1000.0;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct EmissionsModel {
    pub coefficients: EnergyCoefficients,
    pub grid: GridSettings,
}

impl EmissionsModel {
    pub fn new(grid: GridSettings) -> EmissionsModel {
        EmissionsModel { coefficients: EnergyCoefficients::default(), grid }
    }

    pub fn years_from_reference(&self, generation_ms: i64) -> f64 {
        let years = (generation_ms - self.coefficients.reference_generation_ms) as f64 / MS_PER_YEAR;
        years.clamp(-self.coefficients.max_trend_years, self.coefficients.max_trend_years)
    }

    pub fn footprint(&self, tokens: &TokenCounts, profile: &ModelProfile) -> Footprint {
        let c = &self.coefficients;
        let tier = c.tier(profile.tier);

        // Convert everything to "output-token equivalents".
        let input_eq = c.input_to_output_ratio.central;
        let cache_read_eq = input_eq * c.cache_read_to_input_ratio.central;
        let cache_write_eq = input_eq * c.cache_write_to_input_ratio.central;
        let output = tokens.output as f64;
        let input = tokens.input as f64 * input_eq;
        let cache_read = tokens.cache_read as f64 * cache_read_eq;
        let cache_write = tokens.cache_write as f64 * cache_write_eq;
        let output_equivalents = output + input + cache_read + cache_write;
        if output_equivalents <= 0.0 {
            return Footprint::default();
        }

        let years = self.years_from_reference(profile.generation_ms);
        let trend = c.annual_efficiency_factor.central.powf(years);
        let per_token = c.base_wh_per_1k_output.central / 1000.0 * tier.central;
        let it_wh = output_equivalents * per_token * trend;
        let baseline_it_wh = output_equivalents * per_token;
        let facility_wh = it_wh * self.grid.pue;

        // Combine independent log-normal uncertainties; input-side ratios only
        // affect their share of the energy, so they're weighted by it.
        let input_share = (input + cache_read + cache_write) / output_equivalents;
        let cache_read_share = cache_read / output_equivalents;
        let cache_write_share = cache_write / output_equivalents;
        let variance = c.base_wh_per_1k_output.log_spread().powi(2)
            + tier.log_spread().powi(2)
            + (input_share * c.input_to_output_ratio.log_spread()).powi(2)
            + (cache_read_share * c.cache_read_to_input_ratio.log_spread()).powi(2)
            + (cache_write_share * c.cache_write_to_input_ratio.log_spread()).powi(2)
            + (years.abs() * c.annual_efficiency_factor.log_spread()).powi(2);
        let spread = variance.sqrt().exp();

        let energy = Interval { low: facility_wh / spread, central: facility_wh, high: facility_wh * spread };
        let grams_per_wh = self.grid.grams_co2_per_kwh / 1000.0;
        Footprint {
            energy_wh: energy,
            co2_grams: energy * grams_per_wh,
            baseline_co2_grams: baseline_it_wh * self.grid.pue * grams_per_wh,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::GenerationSource;

    fn profile(model: &EmissionsModel, tier: ModelTier, years: f64) -> ModelProfile {
        ModelProfile {
            id: "m".into(),
            display_name: "m".into(),
            tier,
            generation_ms: model.coefficients.reference_generation_ms + (years * MS_PER_YEAR) as i64,
            generation_source: GenerationSource::Catalog,
        }
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn baseline_output_matches_calibration() {
        let m = EmissionsModel::default();
        let fp = m.footprint(&TokenCounts { output: 1000, ..Default::default() }, &profile(&m, ModelTier::Large, 0.0));
        assert!(close(fp.energy_wh.central, 0.9 * 1.15));
        assert!(close(fp.co2_grams.central, 0.9 * 1.15 * 0.373));
        assert!(fp.co2_grams.low < fp.co2_grams.central && fp.co2_grams.central < fp.co2_grams.high);
        assert!(fp.efficiency_dividend_grams().abs() < 1e-9);
    }

    #[test]
    fn token_kinds_are_weighted() {
        let m = EmissionsModel::default();
        let p = profile(&m, ModelTier::Large, 0.0);
        let out = m.footprint(&TokenCounts { output: 1000, ..Default::default() }, &p).energy_wh.central;
        let input = m.footprint(&TokenCounts { input: 1000, ..Default::default() }, &p).energy_wh.central;
        let read = m.footprint(&TokenCounts { cache_read: 1000, ..Default::default() }, &p).energy_wh.central;
        assert!(close(input / out, 0.2));
        assert!(close(read / out, 0.02));
    }

    #[test]
    fn smaller_and_newer_models_emit_less() {
        let m = EmissionsModel::default();
        let tokens = TokenCounts { input: 100, cache_read: 50_000, output: 2_000, ..Default::default() };
        let large = m.footprint(&tokens, &profile(&m, ModelTier::Large, 0.0)).co2_grams.central;
        let small = m.footprint(&tokens, &profile(&m, ModelTier::Small, 0.0)).co2_grams.central;
        let newer = m.footprint(&tokens, &profile(&m, ModelTier::Large, 2.0));
        assert!(small < large);
        assert!((newer.co2_grams.central - large * 0.36).abs() < 1e-6);
        assert!(newer.efficiency_dividend_grams() > 0.0);
    }

    #[test]
    fn uncertainty_widens_with_extrapolation_and_trend_is_clamped() {
        let m = EmissionsModel::default();
        let t = TokenCounts { output: 1000, ..Default::default() };
        let now = m.footprint(&t, &profile(&m, ModelTier::Large, 0.0));
        let far = m.footprint(&t, &profile(&m, ModelTier::Large, 3.0));
        assert!(far.co2_grams.high / far.co2_grams.central > now.co2_grams.high / now.co2_grams.central);
        let four = m.footprint(&t, &profile(&m, ModelTier::Large, 4.0)).co2_grams.central;
        let nine = m.footprint(&t, &profile(&m, ModelTier::Large, 9.0)).co2_grams.central;
        assert!((four - nine).abs() < 1e-9);
    }

    #[test]
    fn grid_and_pue_scale_linearly() {
        let m = EmissionsModel::new(GridSettings { grams_co2_per_kwh: 50.0, pue: 1.1 });
        let g = m
            .footprint(&TokenCounts { output: 1000, ..Default::default() }, &profile(&m, ModelTier::Large, 0.0))
            .co2_grams
            .central;
        assert!(close(g, 0.9 * 1.1 * 0.05));
    }
}
