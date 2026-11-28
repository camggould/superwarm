//! Saved estimate settings, shared by the CLI and the macOS app.
//!
//! `settings.json` in the config directory (`~/Library/Application Support/Superwarm`
//! on macOS, `~/.config/superwarm` on Linux) holds the defaults for `--grid`,
//! `--pue` and `--commute`. Flags still win for a single run. Every field is
//! optional: a missing one uses the built-in default, and unknown keys are kept
//! as they are, so the app can store its own preferences alongside.

use crate::emissions::GridSettings;
use crate::equivalents::EquivalentSettings;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grid_grams_per_kwh: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pue: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commute_miles_one_way: Option<f64>,
    /// Keys this build doesn't use (the app's own preferences), preserved on save.
    #[serde(flatten)]
    pub other: serde_json::Map<String, serde_json::Value>,
}

/// The values an estimate actually uses, after flags, the file and defaults.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Effective {
    pub grid_grams_per_kwh: f64,
    pub pue: f64,
    pub commute_miles_one_way: f64,
}

impl Settings {
    pub fn default_path() -> Option<PathBuf> {
        crate::paths::config_dir().map(|d| d.join("settings.json"))
    }

    /// A missing file is empty settings; an unreadable one is an error.
    pub fn load(path: &Path) -> Result<Settings> {
        match std::fs::read(path) {
            Ok(data) => {
                let settings: Settings = serde_json::from_slice(&data)
                    .with_context(|| format!("{} isn't valid settings", path.display()))?;
                settings.validate().with_context(|| format!("in {}", path.display()))?;
                Ok(settings)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
            Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        let tmp = path.with_extension("json.tmp");
        let mut text = serde_json::to_string_pretty(self)?;
        text.push('\n');
        std::fs::write(&tmp, text).with_context(|| format!("writing {}", tmp.display()))?;
        std::fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
        Ok(())
    }

    pub fn validate(&self) -> Result<()> {
        if let Some(grid) = self.grid_grams_per_kwh {
            if !(grid.is_finite() && (0.0..=2000.0).contains(&grid)) {
                bail!("grid intensity must be between 0 and 2000 g CO2e/kWh (got {grid})");
            }
        }
        if let Some(pue) = self.pue {
            if !(pue.is_finite() && (1.0..=3.0).contains(&pue)) {
                bail!("PUE must be between 1.0 and 3.0 (got {pue})");
            }
        }
        if let Some(miles) = self.commute_miles_one_way {
            if !(miles.is_finite() && miles > 0.0 && miles <= 500.0) {
                bail!("commute must be between 0 and 500 miles (got {miles})");
            }
        }
        Ok(())
    }

    /// `overrides` (from flags) win over the file, which wins over the
    /// built-in defaults (US grid, PUE 1.15, the US average commute).
    pub fn resolve(&self, overrides: &Settings) -> Effective {
        let grid = GridSettings::default();
        let equivalents = EquivalentSettings::default();
        Effective {
            grid_grams_per_kwh: overrides
                .grid_grams_per_kwh
                .or(self.grid_grams_per_kwh)
                .unwrap_or(grid.grams_co2_per_kwh),
            pue: overrides.pue.or(self.pue).unwrap_or(grid.pue),
            commute_miles_one_way: overrides
                .commute_miles_one_way
                .or(self.commute_miles_one_way)
                .unwrap_or(equivalents.commute_miles_one_way),
        }
    }

    /// Copies the values set in `changes` into these settings.
    pub fn apply(&mut self, changes: &Settings) {
        if changes.grid_grams_per_kwh.is_some() {
            self.grid_grams_per_kwh = changes.grid_grams_per_kwh;
        }
        if changes.pue.is_some() {
            self.pue = changes.pue;
        }
        if changes.commute_miles_one_way.is_some() {
            self.commute_miles_one_way = changes.commute_miles_one_way;
        }
    }

    pub fn is_empty(&self) -> bool {
        self.grid_grams_per_kwh.is_none() && self.pue.is_none() && self.commute_miles_one_way.is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_beat_the_file_which_beats_defaults() {
        let file = Settings { pue: Some(1.1), commute_miles_one_way: Some(16.4), ..Default::default() };
        let flags = Settings { commute_miles_one_way: Some(5.0), ..Default::default() };
        let effective = file.resolve(&flags);
        assert_eq!(effective.grid_grams_per_kwh, crate::emissions::GRID_US_AVERAGE);
        assert_eq!(effective.pue, 1.1);
        assert_eq!(effective.commute_miles_one_way, 5.0);
    }

    #[test]
    fn missing_file_is_empty_and_saving_keeps_other_keys() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/settings.json");
        assert!(Settings::load(&path).unwrap().is_empty());

        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, r#"{"pue": 1.2, "menuBarPeriod": "week"}"#).unwrap();
        let mut settings = Settings::load(&path).unwrap();
        settings.apply(&Settings { commute_miles_one_way: Some(16.4), ..Default::default() });
        settings.save(&path).unwrap();

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"menuBarPeriod\": \"week\""), "{text}");
        let reloaded = Settings::load(&path).unwrap();
        assert_eq!((reloaded.pue, reloaded.commute_miles_one_way), (Some(1.2), Some(16.4)));
    }

    #[test]
    fn rejects_nonsense() {
        assert!(Settings { pue: Some(0.5), ..Default::default() }.validate().is_err());
        assert!(Settings { grid_grams_per_kwh: Some(-1.0), ..Default::default() }.validate().is_err());
        assert!(Settings { commute_miles_one_way: Some(0.0), ..Default::default() }.validate().is_err());
        assert!(Settings { grid_grams_per_kwh: Some(0.0), ..Default::default() }.validate().is_ok());
    }

    #[test]
    fn a_broken_file_is_an_error_not_silence() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, "{ not json").unwrap();
        assert!(Settings::load(&path).is_err());
        std::fs::write(&path, r#"{"pue": 0.2}"#).unwrap();
        assert!(Settings::load(&path).is_err());
    }
}
