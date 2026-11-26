//! A deterministic, synthetic year of coding-agent usage for screenshots and
//! demos, so documentation never shows anyone's real logs.

use crate::report::local_ms;
use crate::usage::{Provider, TokenCounts, UsageRecord};
use chrono::{Datelike, Duration, NaiveDate, TimeZone, Weekday};

/// SplitMix64: tiny, seedable and identical on every platform.
struct Rng(u64);

impl Rng {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn range(&mut self, low: u64, high: u64) -> u64 {
        low + self.next_u64() % (high - low + 1)
    }
}

pub fn records<Tz: TimeZone>(now_ms: i64, tz: &Tz) -> Vec<UsageRecord> {
    let mut rng = Rng(2026);
    let projects = ["/home/demo/code/acme-web", "/home/demo/code/data-pipeline", "/home/demo/code/mobile-app", "/home/demo/code/dotfiles"];
    let today = crate::report::local_naive(tz, now_ms).date();
    let mut day = NaiveDate::from_ymd_opt(today.year(), 1, 1).expect("jan 1");
    let mut records = Vec::new();
    let mut serial = 0u64;

    while day <= today {
        let weekend = matches!(day.weekday(), Weekday::Sat | Weekday::Sun);
        // Usage ramps up through the year; weekends are quieter.
        let intensity = (0.35 + day.month() as f64 / 12.0) * if weekend { 0.3 } else { 1.0 };
        let sessions = (rng.unit() * 4.0 * intensity).round() as u64;

        for _ in 0..sessions {
            let hour = if rng.unit() < 0.2 { rng.range(20, 23) } else { rng.range(9, 17) };
            let mut time = local_ms(tz, day.and_hms_opt(hour as u32, 0, 0).expect("valid hour"));
            if time > now_ms {
                continue;
            }
            let project = projects[rng.range(0, projects.len() as u64 - 1) as usize];
            let roll = rng.unit();
            let (provider, model) = if roll < 0.22 {
                (Provider::Codex, if day.month() < 6 { "gpt-5-codex" } else { "gpt-5.1-codex" })
            } else if roll < 0.32 {
                (Provider::ClaudeCode, "claude-haiku-4-5-20251001")
            } else if roll < 0.55 {
                (Provider::ClaudeCode, "claude-sonnet-4-5-20250929")
            } else {
                (Provider::ClaudeCode, "claude-opus-4-5-20251101")
            };
            let mut context = rng.range(20_000, 40_000);
            for _ in 0..rng.range(15, 70) {
                serial += 1;
                let output = rng.range(150, 2_400);
                let written = rng.range(500, 6_000);
                records.push(UsageRecord {
                    id: format!("demo:{serial}"),
                    timestamp_ms: time,
                    provider,
                    model: model.to_string(),
                    project: Some(project.to_string()),
                    tokens: TokenCounts { input: rng.range(1, 40), cache_write: written, cache_read: context, output },
                });
                context = (context + written + output).min(180_000);
                time += rng.range(20_000, 140_000) as i64;
            }
        }
        day += Duration::days(1);
    }
    records
}
