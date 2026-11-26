//! The shareable year summary as a standalone SVG: the same card as the macOS
//! app's share sheet, for machines without a screen (remote boxes, servers).
//!
//! Project names are deliberately left out: the card is meant to be posted.

use crate::equivalents::{self, EquivalentSettings};
use crate::format;
use crate::review::YearInReview;
use std::fmt::Write;

const LOGO_PNG: &[u8] = include_bytes!("../assets/logo-512.png");

const SOIL: &str = "#2B2621";
const SAND: &str = "#E0D4BA";
const MOSS: &str = "#405A2E";
const CLAY: &str = "#E0855C";
const FONT: &str = "-apple-system, 'SF Pro Display', 'Segoe UI', Inter, Roboto, Helvetica, Arial, sans-serif";

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn base64(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(TABLE[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn friendly(n: f64) -> String {
    if (1_000.0..10_000.0).contains(&n) {
        let whole = n.round() as i64;
        format!("{},{:03}", whole / 1000, whole % 1000)
    } else {
        format::count(n)
    }
}

/// Renders a 1080×1350 (4:5) SVG summary card for `review`.
pub fn svg(review: &YearInReview, grid: &crate::emissions::GridSettings, settings: &EquivalentSettings) -> String {
    let r = review;
    let units = |id: &str| equivalents::named(id, grid, settings).map_or(0.0, |e| e.units(r.total_grams));
    let c = r.counterfactual;
    let saved = (c.on_reference_models - c.actual).max(0.0);
    let flight = units("flight-nyc-la");
    let stats = [
        (friendly(units("home-day")), "days of home power".to_string()),
        if flight >= 1.0 {
            (friendly(flight), "flights NYC → LA".to_string())
        } else {
            (format!("{}%", (flight * 100.0).round().max(1.0) as i64), "of a flight NYC → LA".to_string())
        },
        (friendly(units("phone")), "iPhone charges".to_string()),
        (format::tokens(r.tokens_read), "tokens read".to_string()),
        (friendly(r.novels_written), "novels' worth written".to_string()),
        (r.longest_streak.to_string(), "day longest streak".to_string()),
    ];

    let mut s = String::new();
    let _ = write!(
        s,
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1350" viewBox="0 0 1080 1350" font-family="{FONT}">
<defs><mask id="logo"><image href="data:image/png;base64,{logo}" x="68" y="64" width="48" height="48"/></mask></defs>
<rect width="1080" height="1350" fill="{SOIL}"/>
<rect x="68" y="64" width="48" height="48" fill="{CLAY}" mask="url(#logo)"/>
<text x="130" y="101" font-size="34" font-weight="600" fill="{SAND}">Superwarm</text>
<text x="1012" y="101" font-size="34" font-weight="600" fill="{SAND}" fill-opacity="0.7" text-anchor="end">{year}</text>
<text x="68" y="275" font-size="36" font-weight="500" fill="{SAND}" fill-opacity="0.75">My year of AI coding emitted</text>
<text x="68" y="405" font-size="128" font-weight="700" fill="{SAND}">{total}<tspan dx="30" font-size="96">CO</tspan><tspan font-size="58" dy="20">2</tspan><tspan font-size="96" dy="-20">e</tspan></text>
<text x="68" y="460" font-size="28" fill="{SAND}" fill-opacity="0.65">across {responses} responses, likely {low}–{high}</text>
"#,
        logo = base64(LOGO_PNG),
        year = r.year,
        total = escape(&format::grams(r.total_grams)),
        responses = format::count(r.summary.responses as f64),
        low = format::grams(r.summary.footprint.co2_grams.low),
        high = format::grams(r.summary.footprint.co2_grams.high),
    );

    if saved > 0.0 {
        let _ = write!(
            s,
            r#"<rect x="68" y="512" width="944" height="128" rx="28" fill="{MOSS}"/>
<text x="104" y="568" font-size="32" font-weight="700" fill="{SAND}">Newer models kept {saved} out of the air</text>
<text x="104" y="610" font-size="26" fill="{SAND}" fill-opacity="0.85">{pct}% less than the same work on 2024's models</text>
"#,
            saved = escape(&format::grams(saved)),
            pct = (saved / c.on_reference_models * 100.0).round() as i64,
        );
    }

    let _ = writeln!(
        s,
        r#"<text x="68" y="740" font-size="28" font-weight="500" fill="{SAND}" fill-opacity="0.6">That's about</text>"#
    );
    for (i, (value, label)) in stats.iter().enumerate() {
        let x = 68 + (i % 3) * 324;
        let y = 830 + (i / 3) * 170;
        let _ = writeln!(
            s,
            r#"<text x="{x}" y="{y}" font-size="56" font-weight="700" fill="{SAND}">{}</text><text x="{x}" y="{}" font-size="26" fill="{SAND}" fill-opacity="0.7">{}</text>"#,
            escape(value),
            y + 44,
            escape(label)
        );
    }
    let _ = writeln!(
        s,
        r#"<text x="68" y="1262" font-size="21" fill="{SAND}" fill-opacity="0.5">Estimates from local coding-agent logs. Sources: Epoch AI, Google, EPA, EIA, Our World in Data.</text>
</svg>"#
    );
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emissions::{EmissionsModel, GridSettings};
    use crate::report::UsageReport;
    use crate::usage::{Provider, TokenCounts, UsageRecord};
    use chrono::Utc;

    #[test]
    fn base64_matches_known_vectors() {
        assert_eq!(base64(b"Man"), "TWFu");
        assert_eq!(base64(b"Ma"), "TWE=");
        assert_eq!(base64(b"M"), "TQ==");
    }

    #[test]
    fn card_shows_the_year_without_project_names() {
        let records = vec![UsageRecord {
            id: "a".into(),
            timestamp_ms: 1_783_000_000_000, // 2026
            provider: Provider::ClaudeCode,
            model: "claude-opus-4-5".into(),
            project: Some("/home/me/secret-client-project".into()),
            tokens: TokenCounts { output: 50_000, cache_read: 2_000_000, ..Default::default() },
            machine: None,
        }];
        let report = UsageReport::new(records, EmissionsModel::default(), vec![]);
        let review = YearInReview::new(&report, 2026, &Utc);
        let svg = svg(&review, &GridSettings::default(), &EquivalentSettings::default());
        assert!(svg.starts_with("<svg") && svg.trim_end().ends_with("</svg>"));
        assert!(svg.contains(">2026<"));
        assert!(svg.contains(">CO</tspan>"));
        assert!(svg.contains("out of the air"));
        assert!(!svg.contains("secret-client-project"));
    }

    #[test]
    fn escapes_markup() {
        assert_eq!(escape("<a & b>"), "&lt;a &amp; b&gt;");
    }
}
