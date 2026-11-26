//! Everyday activities to compare an emissions total against.

use crate::emissions::GridSettings;
use crate::format;
use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Equivalent {
    pub id: &'static str,
    /// SF Symbol name, used by the macOS app.
    pub symbol: &'static str,
    pub singular: &'static str,
    pub plural: &'static str,
    pub grams_per_unit: f64,
    pub citation_id: &'static str,
    pub note: String,
}

impl Equivalent {
    /// How many of this activity `grams` of CO2e is equal to.
    pub fn units(&self, grams: f64) -> f64 {
        grams / self.grams_per_unit
    }

    pub fn phrase(&self, grams: f64) -> String {
        let n = self.units(grams);
        let noun = if (n - 1.0).abs() < 0.05 { self.singular } else { self.plural };
        format!("{} {noun}", format::count(n))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EquivalentSettings {
    /// One-way commute distance in miles (US average, FHWA NHTS 2017).
    pub commute_miles_one_way: f64,
}

impl Default for EquivalentSettings {
    fn default() -> Self {
        EquivalentSettings { commute_miles_one_way: 11.7 }
    }
}

pub const GRAMS_PER_CAR_MILE: f64 = 400.0;
pub const GRAMS_PER_GALLON_GASOLINE: f64 = 8_887.0;
/// Average US home electricity use, EIA (2022): 10,791 kWh / year.
pub const HOME_KWH_PER_DAY: f64 = 10_791.0 / 365.25;

/// Equivalents whose size depends on the grid and commute settings.
pub fn all(grid: &GridSettings, settings: &EquivalentSettings) -> Vec<Equivalent> {
    let g_per_wh = grid.grams_co2_per_kwh / 1000.0;
    let commute_grams = settings.commute_miles_one_way * 2.0 * GRAMS_PER_CAR_MILE;
    let e = |id, symbol, singular, plural, grams_per_unit, citation_id, note: &str| Equivalent {
        id,
        symbol,
        singular,
        plural,
        grams_per_unit,
        citation_id,
        note: note.to_string(),
    };
    vec![
        e("car-mile", "car.fill", "mile driven", "miles driven", GRAMS_PER_CAR_MILE, "epa-vehicle",
          "Average US gasoline passenger car."),
        e("commute", "car.2.fill", "round-trip commute", "round-trip commutes", commute_grams, "nhts-2017",
          &format!("{} mi each way by car at 400 g/mi.", format::count(settings.commute_miles_one_way))),
        e("kettle", "cup.and.saucer.fill", "kettle boil", "kettle boils", 100.0 * g_per_wh, "egrid-2022",
          "1 L heated by 80 °C ≈ 0.1 kWh, on your selected grid."),
        e("home-hour", "house.fill", "hour of home electricity", "hours of home electricity",
          HOME_KWH_PER_DAY / 24.0 * grid.grams_co2_per_kwh, "eia-home",
          "Average US home, ~1.2 kWh per hour, on your selected grid."),
        e("home-day", "house.fill", "day of home electricity", "days of home electricity",
          HOME_KWH_PER_DAY * grid.grams_co2_per_kwh, "eia-home",
          "Average US home, ~29.6 kWh per day, on your selected grid."),
        e("phone", "iphone.gen3", "phone charge", "phone charges", 20.0 * g_per_wh, "egrid-2022",
          "~15 Wh battery at ~75% charger efficiency ≈ 20 Wh, on your selected grid."),
        e("streaming", "play.tv.fill", "hour of video streaming", "hours of video streaming", 36.0, "iea-streaming",
          "Device, network and data centre, 2019 global average."),
        e("flight-km", "airplane", "km flown (short-haul)", "km flown (short-haul)", 151.0, "owid-transport",
          "Per passenger, including non-CO2 warming effects."),
        e("flight-nyc-la", "airplane.departure", "flight from New York to LA", "flights from New York to LA",
          3_980.0 * 151.0, "owid-transport",
          "One passenger, ~3,980 km at ~151 g CO2e/km including non-CO2 warming."),
        e("train-km", "tram.fill", "km by train", "km by train", 35.0, "owid-transport",
          "Per passenger, UK national rail average."),
        e("shower", "shower.fill", "hot shower", "hot showers", 2_300.0 * g_per_wh, "epa-watersense",
          "10 minutes at 2.0 gpm, water heated by 25 °C electrically (~2.3 kWh), on your selected grid."),
        e("macbook", "laptopcomputer", "MacBook charge", "MacBook charges", 60.0 * g_per_wh, "apple-mba",
          "52.6 Wh battery, ~60 Wh from the wall, on your selected grid."),
        e("led-year", "lightbulb.fill", "year of an LED bulb left on", "years of an LED bulb left on",
          10.0 * 8_766.0 * g_per_wh, "doe-led",
          "A 10 W LED burning day and night for a year (~88 kWh), on your selected grid."),
        e("gasoline", "fuelpump.fill", "gallon of gasoline", "gallons of gasoline", GRAMS_PER_GALLON_GASOLINE,
          "epa-vehicle", "CO2 from burning one US gallon."),
        e("burger", "fork.knife", "quarter-pound beef burger", "quarter-pound beef burgers", 0.1134 * 99_500.0,
          "owid-food", "113 g of beef-herd beef at ~99.5 kg CO2e/kg."),
        e("us-day", "person.fill", "day of an average American's emissions", "days of an average American's emissions",
          14_300_000.0 / 365.25, "owid-co2", "~14.3 t fossil CO2 per person per year."),
        e("tree", "tree.fill", "tree-decade of absorption", "tree-decades of absorption", 60_000.0,
          "epa-equivalencies", "CO2 one urban tree seedling takes up over 10 years."),
        e("gemini-prompt", "sparkles", "median Gemini prompt", "median Gemini prompts", 0.03, "google-2025",
          "Google's measured median text prompt, May 2025. A short chat prompt, not an agentic coding turn."),
    ]
}

pub fn named(id: &str, grid: &GridSettings, settings: &EquivalentSettings) -> Option<Equivalent> {
    all(grid, settings).into_iter().find(|e| e.id == id)
}

/// The three headline comparisons, one per domain so they don't repeat each
/// other: getting around (commute), food (burger) and home energy (hours or
/// days of home electricity, whichever reads better).
pub fn headline(grams: f64, grid: &GridSettings, settings: &EquivalentSettings) -> Vec<Equivalent> {
    let all = all(grid, settings);
    let pick = |id: &str| all.iter().find(|e| e.id == id).cloned().expect("known equivalent");
    let day = pick("home-day");
    let home = if day.units(grams) >= 1.0 { day } else { pick("home-hour") };
    vec![pick("commute"), pick("burger"), home]
}

/// Comparisons that read most naturally for an amount (unit counts near 10),
/// always leading with the commute.
pub fn highlights(grams: f64, grid: &GridSettings, settings: &EquivalentSettings, limit: usize) -> Vec<Equivalent> {
    let candidates = all(grid, settings);
    if grams <= 0.0 {
        return candidates.into_iter().take(limit).collect();
    }
    let score = |e: &Equivalent| {
        let n = e.units(grams);
        if (0.5..=500.0).contains(&n) { (n.log10() - 1.0).abs() } else { 10.0 + n.max(1e-9).log10().abs() }
    };
    let commute = candidates.iter().find(|e| e.id == "commute").cloned().expect("commute");
    let mut rest: Vec<Equivalent> = candidates.into_iter().filter(|e| e.id != "commute").collect();
    rest.sort_by(|a, b| score(a).total_cmp(&score(b)));
    std::iter::once(commute).chain(rest.into_iter().take(limit.saturating_sub(1))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::citations;

    fn grid() -> GridSettings {
        GridSettings::default()
    }

    #[test]
    fn every_equivalent_cites_a_known_source() {
        for e in all(&grid(), &EquivalentSettings::default()) {
            assert!(citations::by_id(e.citation_id).is_some(), "{} cites unknown {}", e.id, e.citation_id);
        }
    }

    #[test]
    fn commute_scales_with_distance() {
        let e = named("commute", &grid(), &EquivalentSettings { commute_miles_one_way: 10.0 }).unwrap();
        assert_eq!(e.grams_per_unit, 8_000.0);
        assert_eq!(e.units(16_000.0), 2.0);
    }

    #[test]
    fn grid_dependent_equivalents_follow_grid() {
        let g = GridSettings { grams_co2_per_kwh: 400.0, pue: 1.15 };
        let kettle = named("kettle", &g, &EquivalentSettings::default()).unwrap();
        assert!((kettle.grams_per_unit - 40.0).abs() < 1e-9);
    }

    #[test]
    fn highlights_lead_with_commute_and_prefer_readable_counts() {
        let picks = highlights(4_000.0, &grid(), &EquivalentSettings::default(), 4);
        assert_eq!(picks[0].id, "commute");
        assert_eq!(picks.len(), 4);
        for pick in &picks[1..] {
            let n = pick.units(4_000.0);
            assert!((0.5..=500.0).contains(&n), "{} -> {n}", pick.id);
        }
    }

    #[test]
    fn headline_covers_three_domains_and_scales_home_unit() {
        let small = headline(250.0, &grid(), &EquivalentSettings::default());
        assert_eq!(small.iter().map(|e| e.id).collect::<Vec<_>>(), ["commute", "burger", "home-hour"]);
        let large = headline(45_000.0, &grid(), &EquivalentSettings::default());
        assert_eq!(large.iter().map(|e| e.id).collect::<Vec<_>>(), ["commute", "burger", "home-day"]);
        let days = large[2].units(45_000.0);
        assert!(days > 4.0 && days < 4.2);
    }

    #[test]
    fn recap_equivalents_have_sensible_sizes() {
        let s = EquivalentSettings::default();
        let grams = |id| named(id, &grid(), &s).unwrap().grams_per_unit;
        assert!((grams("flight-nyc-la") - 600_980.0).abs() < 1.0);
        assert!((grams("shower") - 857.9).abs() < 0.1);
        assert!((grams("macbook") - 22.38).abs() < 0.01);
        assert!((grams("led-year") - 32_697.0).abs() < 1.0);
        assert!(grams("train-km") < grams("flight-km"));
    }
}
