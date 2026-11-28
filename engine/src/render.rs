//! Terminal rendering for `superwarm report` and `superwarm year`.
//!
//! Output is built as plain strings and styled only when writing to a colour
//! terminal, so the same layout works in pipes, logs and over SSH.

use crate::equivalents::{self, EquivalentSettings};
use crate::format;
use crate::report::{local_naive, Bucket, ProjectBreakdown, TimeRange, UsageReport};
use crate::review::YearInReview;
use crate::snapshot::PeriodSnapshot;
use crate::usage::Provider;
use chrono::{TimeZone, Timelike};
use std::fmt::Write;

/// How to draw: colour on or off, and the line width to fill.
#[derive(Clone, Copy, Debug)]
pub struct Ui {
    pub color: bool,
    pub width: usize,
}

impl Ui {
    pub fn plain(width: usize) -> Ui {
        Ui { color: false, width }
    }

    fn paint(&self, code: &str, text: &str) -> String {
        if self.color && !text.is_empty() {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }

    pub fn bold(&self, t: &str) -> String {
        self.paint("1", t)
    }
    pub fn dim(&self, t: &str) -> String {
        self.paint("2", t)
    }
    pub fn good(&self, t: &str) -> String {
        self.paint("32", t)
    }
    pub fn bad(&self, t: &str) -> String {
        self.paint("31", t)
    }
    pub fn accent(&self, t: &str) -> String {
        self.paint("1;33", t)
    }
    pub fn provider(&self, provider: Provider, t: &str) -> String {
        match provider {
            Provider::ClaudeCode => self.paint("34", t),
            Provider::Codex => self.paint("33", t),
            Provider::Antigravity => self.paint("36", t),
        }
    }

    fn rule(&self) -> String {
        self.dim(&"─".repeat(self.width.min(72)))
    }

    /// Width available for bars after a label column.
    fn bar_width(&self, used: usize) -> usize {
        self.width.min(72).saturating_sub(used).clamp(8, 40)
    }
}

/// Character count, which is the display width for the text Superwarm prints.
fn width_of(text: &str) -> usize {
    text.chars().count()
}

fn pad(text: &str, width: usize) -> String {
    format!("{text}{}", " ".repeat(width.saturating_sub(width_of(text))))
}

fn pad_left(text: &str, width: usize) -> String {
    format!("{}{text}", " ".repeat(width.saturating_sub(width_of(text))))
}

/// A horizontal bar in eighths of a cell.
pub fn bar(fraction: f64, width: usize) -> String {
    const PARTS: [&str; 8] = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];
    let eighths = (fraction.clamp(0.0, 1.0) * width as f64 * 8.0).round() as usize;
    let mut out = "█".repeat(eighths / 8);
    out.push_str(PARTS[eighths % 8]);
    if out.is_empty() && fraction > 0.0 {
        out.push('▏');
    }
    out
}

/// A one-line chart, one character per value.
pub fn sparkline(values: &[f64]) -> String {
    const LEVELS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let max = values.iter().cloned().fold(0.0, f64::max);
    values
        .iter()
        .map(|&v| if v <= 0.0 || max <= 0.0 { ' ' } else { LEVELS[((v / max) * 7.0).round().clamp(0.0, 7.0) as usize] })
        .collect()
}

/// Whole-number counts: "1 response", "616 responses", "17.0k responses".
fn responses(n: u64) -> String {
    let count = if n < 10_000 { nice(n as f64).trim_end_matches(".0").to_string() } else { format::count(n as f64) };
    format!("{count} response{}", if n == 1 { "" } else { "s" })
}

/// Counts for prose: "4.1", "37", "1,497", "12.3k".
fn nice(n: f64) -> String {
    if (1_000.0..10_000.0).contains(&n.abs()) {
        let whole = n.round() as i64;
        format!("{},{:03}", whole / 1000, (whole % 1000).abs())
    } else {
        format::count(n)
    }
}

fn percent(fraction: f64) -> String {
    format!("{}%", (fraction * 100.0).round() as i64)
}

/// "68% lower than on 2024 models", or "6.0× the 30 days before" for big increases.
fn relative(value: f64, reference: f64, phrase: &str) -> String {
    let change = (value - reference) / reference * 100.0;
    let bare = phrase.strip_prefix("than ").unwrap_or(phrase);
    let rounded = change.abs().round() as i64;
    if rounded == 0 {
        format!("same as {bare}")
    } else if change >= 100.0 {
        format!("{}× {bare}", format::count(value / reference))
    } else {
        format!("{rounded}% {} {phrase}", if change < 0.0 { "lower" } else { "higher" })
    }
}

fn signed(delta: f64) -> String {
    format!("{}{}", if delta <= 0.0 { "−" } else { "+" }, format::grams(delta.abs()))
}

fn bucket_label<Tz: TimeZone>(bucket: Bucket, start_ms: i64, tz: &Tz) -> String {
    let t = local_naive(tz, start_ms);
    match bucket {
        Bucket::Hour => format!("{:02}:00", t.hour()),
        Bucket::Day => t.format("%a %b %-d").to_string(),
        Bucket::Week => t.format("wk of %b %-d").to_string(),
        Bucket::Month => t.format("%b %Y").to_string(),
    }
}

/// Inputs for `superwarm report`.
pub struct ReportView<'a, Tz: TimeZone> {
    pub report: &'a UsageReport,
    pub period: &'a PeriodSnapshot,
    pub settings: &'a EquivalentSettings,
    pub projects: Vec<ProjectBreakdown>,
    /// (label, summary) per machine; the section shows when there's more than one.
    pub machines: Vec<(String, crate::report::Summary)>,
    pub first_record_ms: Option<i64>,
    pub now_ms: i64,
    pub tz: &'a Tz,
    /// "1,689 logs scanned in 0.1s" style footer.
    pub footer: String,
}

pub fn report<Tz: TimeZone>(ui: &Ui, v: &ReportView<Tz>) -> String {
    let mut out = String::new();
    let p = v.period;
    let fp = p.summary.footprint;
    let grams = fp.co2_grams.central;
    let span = match p.range {
        Some(TimeRange { start_ms, end_ms }) => {
            let start = local_naive(v.tz, start_ms).format("%b %-d").to_string();
            let end = local_naive(v.tz, end_ms - 1).format("%b %-d").to_string();
            if start == end {
                start
            } else {
                format!("{start} – {end}")
            }
        }
        None => "all time".to_string(),
    };

    let _ = writeln!(out);
    let title = format!(" Superwarm · {}", p.label.to_lowercase());
    let gap = ui.width.min(72).saturating_sub(width_of(&title) + width_of(&span) + 1);
    let _ = writeln!(out, "{}{}{}", ui.bold(&title), " ".repeat(gap.max(2)), ui.dim(&span));
    let _ = writeln!(out, " {}", ui.rule());

    if p.summary.responses == 0 {
        let _ = writeln!(out, "\n   No coding-agent usage in this period.\n");
        let _ = writeln!(out, " {}", ui.dim(&v.footer));
        return out;
    }

    // Headline
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "   {} {}   {}",
        ui.accent(&format::grams(grams)),
        ui.bold("CO₂e"),
        ui.dim(&format!(
            "likely {} – {} · {}",
            format::grams(fp.co2_grams.low),
            format::grams(fp.co2_grams.high),
            format::energy(fp.energy_wh.central)
        ))
    );
    let t = p.summary.tokens;
    let _ = writeln!(
        out,
        "   {}",
        ui.dim(&format!(
            "{} output · {} input · {} cached tokens · {}",
            format::tokens(t.output),
            format::tokens(t.input + t.cache_write),
            format::tokens(t.cache_read),
            responses(p.summary.responses)
        ))
    );

    // Everyday comparisons
    let _ = writeln!(out, "\n {}", ui.bold("That's about"));
    let picks = equivalents::headline(grams, &v.report.model.grid, v.settings);
    let cells: Vec<String> = picks
        .iter()
        .map(|e| {
            let n = e.units(grams);
            if e.id == "home-hour" && n < 1.0 {
                format!("{} min of home power", ((n * 60.0).round() as i64).max(1))
            } else if (0.005..1.0).contains(&n) {
                format!("{} of a {}", percent(n), short_name(e.id, true))
            } else {
                let name = short_name(e.id, (n - 1.0).abs() < 0.05);
                format!("{} {name}", format::count(n))
            }
        })
        .collect();
    let _ = writeln!(out, "   {}", cells.join(&ui.dim("  ·  ")));

    // Timeline
    timeline(ui, v, &mut out);

    // Comparisons
    let _ = writeln!(out, "\n {}", ui.bold("Compared with"));
    let baseline = fp.baseline_co2_grams;
    if baseline > 0.0 {
        let delta = grams - baseline;
        let line = relative(grams, baseline, "than on 2024 models");
        let _ = writeln!(out, "   {} {}  {}", ui.good("↓"), pad(&line, 42), ui.good(&signed(delta)));
    }
    if let Some(previous) = &p.previous {
        let delta = grams - previous.co2_grams;
        let line = relative(grams, previous.co2_grams, &format!("than {}", previous.label));
        let (arrow, value) = if delta <= 0.0 {
            (ui.good("↓"), ui.good(&signed(delta)))
        } else {
            (ui.bad("↑"), ui.bad(&signed(delta)))
        };
        let _ = writeln!(out, "   {arrow} {}  {value}", pad(&line, 42));
    }
    if let Some(tip) = &p.tier_tip {
        let line =
            if tip.all_opus { "Sonnet-size models instead of Opus" } else { "mid-size models instead of flagships" };
        let saving = format!("could save {}", format::grams(tip.actual - tip.alternative));
        let _ = writeln!(out, "   {} {}  {}", ui.dim("·"), pad(line, 42), ui.dim(&saving));
    }

    // Models
    let models: Vec<_> = p.models.iter().take(8).collect();
    if !models.is_empty() {
        let name_width = models.iter().map(|m| width_of(&m.display_name)).max().unwrap_or(10).clamp(10, 28);
        let bar_width = ui.bar_width(name_width + 30);
        let _ = writeln!(
            out,
            "\n {}{}",
            pad(&ui.bold("By model"), name_width + 4 + if ui.color { 8 } else { 0 }),
            ui.dim("     CO₂e  g/1k out")
        );
        for m in models {
            let share = if grams > 0.0 { m.summary.footprint.co2_grams.central / grams } else { 0.0 };
            let _ = writeln!(
                out,
                "   {} {}  {}  {}  {}",
                ui.provider(m.provider, "●"),
                pad(&m.display_name, name_width),
                pad_left(&format::grams(m.summary.footprint.co2_grams.central), 8),
                pad_left(&format!("{:.2}", m.grams_per_thousand_output), 8),
                ui.provider(m.provider, &bar(share, bar_width))
            );
        }
    }

    // Machines
    if v.machines.len() > 1 {
        let name_width = v.machines.iter().map(|(n, _)| width_of(n)).max().unwrap_or(10).clamp(10, 28);
        let bar_width = ui.bar_width(name_width + 20);
        let _ = writeln!(out, "\n {}", ui.bold("By machine"));
        for (name, summary) in &v.machines {
            let g = summary.footprint.co2_grams.central;
            let share = if grams > 0.0 { g / grams } else { 0.0 };
            let _ = writeln!(
                out,
                "     {}  {}  {}",
                pad(name, name_width),
                pad_left(&format::grams(g), 8),
                ui.dim(&bar(share, bar_width))
            );
        }
    }

    // Projects
    let projects: Vec<_> = v.projects.iter().take(5).collect();
    if !projects.is_empty() {
        let names: Vec<String> = projects
            .iter()
            .map(|pr| {
                std::path::Path::new(&pr.path).file_name().map_or(pr.path.clone(), |n| n.to_string_lossy().into_owned())
            })
            .collect();
        let name_width = names.iter().map(|n| width_of(n)).max().unwrap_or(10).clamp(10, 28);
        let bar_width = ui.bar_width(name_width + 20);
        let _ = writeln!(out, "\n {}", ui.bold("By project"));
        for (name, pr) in names.iter().zip(projects) {
            let g = pr.summary.footprint.co2_grams.central;
            let share = if grams > 0.0 { g / grams } else { 0.0 };
            let _ = writeln!(
                out,
                "     {}  {}  {}",
                pad(name, name_width),
                pad_left(&format::grams(g), 8),
                ui.dim(&bar(share, bar_width))
            );
        }
    }

    let _ = writeln!(out, "\n {}", ui.rule());
    let _ = writeln!(out, " {}", ui.dim(&v.footer));
    out
}

fn short_name(id: &str, one: bool) -> &'static str {
    match (id, one) {
        ("commute", true) => "commute",
        ("commute", false) => "commutes",
        ("burger", true) => "beef burger",
        ("burger", false) => "beef burgers",
        ("home-hour", true) => "hour of home power",
        ("home-hour", false) => "hours of home power",
        ("home-day", true) => "day of home power",
        ("home-day", false) => "days of home power",
        _ => "",
    }
}

fn timeline<Tz: TimeZone>(ui: &Ui, v: &ReportView<Tz>, out: &mut String) {
    let p = v.period;
    let from = p.range.map(|r| r.start_ms).or(v.first_record_ms);
    let Some(from) = from else { return };
    let to = p.range.map_or(v.now_ms, |r| r.end_ms.min(v.now_ms + 1));
    let starts = p.bucket.starts(from, to, v.tz);
    if starts.is_empty() {
        return;
    }
    // Grams per tool, in `Provider::ALL` order, for each bucket.
    let mut by_start: std::collections::HashMap<i64, [f64; Provider::ALL.len()]> = std::collections::HashMap::new();
    for point in &p.timeline {
        let slot = Provider::ALL.iter().position(|&q| q == point.provider).expect("every provider is in ALL");
        by_start.entry(point.start_ms).or_default()[slot] += point.co2_grams;
    }
    let totals: Vec<f64> = starts.iter().map(|s| by_start.get(s).map_or(0.0, |g| g.iter().sum())).collect();
    let max = totals.iter().cloned().fold(0.0, f64::max);
    if max <= 0.0 {
        return;
    }
    let unit = match p.bucket {
        Bucket::Hour => "hour",
        Bucket::Day => "day",
        Bucket::Week => "week",
        Bucket::Month => "month",
    };
    let _ = writeln!(out, "\n {}", ui.bold(&format!("By {unit}")));

    if starts.len() <= 14 {
        // One row per bucket, stacked by tool.
        let label_width = starts.iter().map(|s| width_of(&bucket_label(p.bucket, *s, v.tz))).max().unwrap_or(6);
        let bar_width = ui.bar_width(label_width + 18);
        for start in &starts {
            let grams = by_start.get(start).copied().unwrap_or_default();
            let total: f64 = grams.iter().sum();
            let cells = ((total / max) * bar_width as f64).round() as usize;
            let mut drawn = String::new();
            if total > 0.0 {
                // Round the running total, not each segment, so segments always add up to `cells`.
                let (mut sum, mut used) = (0.0, 0);
                for (provider, g) in Provider::ALL.into_iter().zip(grams) {
                    sum += g;
                    let end = ((sum / total) * cells as f64).round() as usize;
                    drawn.push_str(&ui.provider(provider, &"█".repeat(end - used)));
                    used = end;
                }
            }
            if cells == 0 && total > 0.0 {
                drawn = ui.dim("▏");
            }
            let value = if total > 0.0 { format::grams(total) } else { String::new() };
            let _ = writeln!(
                out,
                "   {}  {}{}  {}",
                ui.dim(&pad(&bucket_label(p.bucket, *start, v.tz), label_width)),
                drawn,
                " ".repeat(bar_width.saturating_sub(cells.max(usize::from(total > 0.0)))),
                pad_left(&value, 8)
            );
        }
        // Only the tools used in this period: most people run one or two.
        let legend: Vec<String> = Provider::ALL
            .into_iter()
            .filter(|&q| p.timeline.iter().any(|point| point.provider == q && point.co2_grams > 0.0))
            .map(|q| format!("{} {}", ui.provider(q, "█"), ui.dim(q.display_name())))
            .collect();
        let _ = writeln!(out, "   {}", legend.join("   "));
    } else {
        // Too many buckets for rows: a sparkline with its ends and peak labelled.
        let line = sparkline(&totals);
        let first = bucket_label(p.bucket, starts[0], v.tz);
        let last = bucket_label(p.bucket, *starts.last().expect("non-empty"), v.tz);
        let peak = totals.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).map_or(0, |(i, _)| i);
        let _ = writeln!(out, "   {}", ui.accent(&line));
        let gap = width_of(&line).saturating_sub(width_of(&first) + width_of(&last));
        let _ = writeln!(out, "   {}{}{}", ui.dim(&first), " ".repeat(gap.max(1)), ui.dim(&last));
        let _ = writeln!(
            out,
            "   {}",
            ui.dim(&format!("peak {} · {}", bucket_label(p.bucket, starts[peak], v.tz), format::grams(totals[peak])))
        );
    }
}

/// Inputs for `superwarm year`.
pub struct YearView<'a, Tz: TimeZone> {
    pub review: &'a YearInReview,
    pub report: &'a UsageReport,
    pub settings: &'a EquivalentSettings,
    pub tz: &'a Tz,
}

pub fn year<Tz: TimeZone>(ui: &Ui, v: &YearView<Tz>) -> String {
    let r = v.review;
    let mut out = String::new();
    let grid = &v.report.model.grid;
    let units = |id: &str, grams: f64| equivalents::named(id, grid, v.settings).map_or(0.0, |e| e.units(grams));

    let _ = writeln!(out);
    let _ = writeln!(out, " {}", ui.bold(&format!("Superwarm · your {} in carbon", r.year)));
    let _ = writeln!(out, " {}", ui.rule());
    if r.total_grams <= 0.0 {
        let _ = writeln!(out, "\n   No coding-agent usage found for {}.\n", r.year);
        return out;
    }
    let fp = r.summary.footprint;
    let _ = writeln!(out);
    let _ = writeln!(out, "   {} {}", ui.accent(&format::grams(r.total_grams)), ui.bold("CO₂e this year"));
    let _ = writeln!(
        out,
        "   {}",
        ui.dim(&format!(
            "likely {} – {} · {} · {}",
            format::grams(fp.co2_grams.low),
            format::grams(fp.co2_grams.high),
            format::energy(fp.energy_wh.central),
            responses(r.summary.responses)
        ))
    );

    let section = |out: &mut String, title: &str, rows: &[(String, String)]| {
        let _ = writeln!(out, "\n {}", ui.bold(title));
        let value_width = rows.iter().map(|(v, _)| width_of(v)).max().unwrap_or(4);
        for (value, label) in rows {
            let _ = writeln!(out, "   {}  {}", ui.accent(&pad_left(value, value_width)), label);
        }
    };

    let total = r.total_grams;
    let flight = units("flight-nyc-la", total);
    let led_years = units("led-year", total);
    section(
        &mut out,
        "That's the same as",
        &[
            (nice(units("home-day", total)), "days of an average US home's electricity".into()),
            (nice(units("commute", total)), "round-trip commutes".into()),
            if flight >= 1.0 {
                (nice(flight), "flights from New York to LA".into())
            } else {
                (percent(flight), "of a flight from New York to LA".into())
            },
            (nice(units("phone", total)), "phone charges".into()),
            (nice(units("shower", total)), "hot showers".into()),
            if led_years >= 1.0 {
                (nice(led_years), "years of an LED bulb left on".into())
            } else {
                (nice(led_years * 12.0), "months of an LED bulb left on".into())
            },
            (nice(units("burger", total)), "quarter-pound beef burgers".into()),
        ],
    );

    let c = r.counterfactual;
    if c.on_reference_models > c.actual {
        let saved = c.on_reference_models - c.actual;
        let _ = writeln!(out, "\n {}", ui.bold("How bad it could have been"));
        let top = c.without_caching.max(c.on_reference_models);
        let bar_width = ui.bar_width(40);
        for (label, grams, emphasis) in [
            ("What you emitted", c.actual, false),
            ("Same work on 2024 models", c.on_reference_models, true),
            ("…and no prompt caching", c.without_caching, true),
        ] {
            let drawn = bar(grams / top, bar_width);
            let drawn = if emphasis { ui.bad(&drawn) } else { ui.good(&drawn) };
            let _ = writeln!(out, "   {}  {}  {}", pad(label, 25), pad_left(&format::grams(grams), 8), drawn);
        }
        let _ = writeln!(
            out,
            "\n   {} {} {}",
            ui.good("Newer models kept"),
            ui.accent(&format::grams(saved)),
            ui.good(&format!("out of the air ({} less).", percent(saved / c.on_reference_models)))
        );
        let _ = writeln!(
            out,
            "   {}",
            ui.dim(&format!(
                "That's like skipping {} iPhone charges, {} hot showers and {} commutes.",
                nice(units("phone", saved)),
                nice(units("shower", saved)),
                nice(units("commute", saved))
            ))
        );
    }

    let mut habits: Vec<(String, String)> = vec![
        (format::tokens(r.tokens_read), "tokens read by your agents".into()),
        (format::count(r.novels_written), "novels' worth of tokens written".into()),
        (r.active_days.to_string(), format!("active days, longest streak {}", r.longest_streak)),
    ];
    if let Some(day) = &r.busiest_day {
        let date = local_naive(v.tz, day.date_ms).format("%B %-d").to_string();
        habits.push((format::grams(day.grams), format!("on your heaviest day, {date}")));
    }
    habits.push((percent(r.night_share), "of emissions between 10 pm and 6 am".into()));
    if let Some(model) = &r.top_model {
        habits.push((percent(model.fraction), format!("from your workhorse, {}", model.name)));
    }
    section(&mut out, "Your habits", &habits);

    if r.monthly.iter().any(|&g| g > 0.0) {
        let _ = writeln!(out, "\n {}", ui.bold("Month by month"));
        let _ = writeln!(out, "   {}", ui.accent(&sparkline(&r.monthly)));
        let _ = writeln!(out, "   {}", ui.dim("JFMAMJJASOND"));
        if let Some(month) = r.busiest_month {
            let name =
                chrono::NaiveDate::from_ymd_opt(r.year, month, 1).map_or(String::new(), |d| d.format("%B").to_string());
            let _ = writeln!(out, "   {}", ui.dim(&format!("busiest: {name}")));
        }
    }

    let trees = units("tree", r.total_grams).ceil().max(1.0);
    let _ = writeln!(out, "\n {}", ui.rule());
    let _ = writeln!(
        out,
        " {}",
        ui.dim(&format!(
            "To absorb it all: {trees} {} growing for a decade. Share it: superwarm year --card card.svg",
            if trees == 1.0 { "tree" } else { "trees" }
        ))
    );
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emissions::EmissionsModel;
    use crate::report::Period;
    use crate::usage::{TokenCounts, UsageRecord};
    use chrono::Utc;

    fn report_with_usage(now: i64) -> UsageReport {
        let records = (0..5)
            .map(|i| UsageRecord {
                id: format!("r{i}"),
                timestamp_ms: now - i * 86_400_000,
                provider: if i % 2 == 0 { Provider::ClaudeCode } else { Provider::Codex },
                model: if i % 2 == 0 { "claude-opus-4-5".into() } else { "gpt-5".into() },
                project: Some(format!("/code/app{}", i % 2)),
                tokens: TokenCounts { output: 1000, cache_read: 50_000, ..Default::default() },
                machine: if i < 2 { None } else { Some("devbox".into()) },
            })
            .collect();
        UsageReport::new(records, EmissionsModel::default(), vec![])
    }

    #[test]
    fn response_counts_are_whole_numbers() {
        assert_eq!(responses(1), "1 response");
        assert_eq!(responses(616), "616 responses");
        assert_eq!(responses(1_497), "1,497 responses");
        assert_eq!(responses(17_002), "17.0k responses");
    }

    #[test]
    fn nice_counts_group_thousands() {
        assert_eq!(nice(1497.2), "1,497");
        assert_eq!(nice(9999.6), "10,000");
        assert_eq!(nice(4.12), "4.1");
        assert_eq!(nice(12_345.0), "12.3k");
    }

    #[test]
    fn bars_and_sparklines() {
        assert_eq!(bar(1.0, 4), "████");
        assert_eq!(bar(0.5, 3), "█▌");
        assert_eq!(bar(0.001, 10), "▏");
        assert_eq!(sparkline(&[0.0, 1.0, 8.0]), " ▂█");
    }

    #[test]
    fn plain_report_has_every_section_and_no_escape_codes() {
        let now = Utc.with_ymd_and_hms(2026, 11, 25, 15, 0, 0).unwrap().timestamp_millis();
        let report = report_with_usage(now);
        let settings = EquivalentSettings::default();
        let period =
            crate::snapshot::period_snapshot(&report, Period::Week, report.first_record_ms(), &settings, now, &Utc);
        let view = ReportView {
            report: &report,
            period: &period,
            settings: &settings,
            projects: report.by_project(period.range),
            machines: report
                .by_machine(period.range)
                .into_iter()
                .map(|(m, s)| (m.unwrap_or_else(|| "laptop".into()), s))
                .collect(),
            first_record_ms: report.first_record_ms(),
            now_ms: now,
            tz: &Utc,
            footer: "test".into(),
        };
        let text = super::report(&Ui::plain(80), &view);
        for needle in [
            "Superwarm · 7 days",
            "CO₂e",
            "That's about",
            "By day",
            "Compared with",
            "By model",
            "By project",
            "claude-opus-4-5",
            "app0",
        ] {
            assert!(text.contains(needle), "missing {needle:?} in:\n{text}");
        }
        assert!(!text.contains('\x1b'));
    }

    #[test]
    fn colour_report_uses_escape_codes() {
        let now = Utc.with_ymd_and_hms(2026, 11, 25, 15, 0, 0).unwrap().timestamp_millis();
        let report = report_with_usage(now);
        let settings = EquivalentSettings::default();
        let review = YearInReview::new(&report, 2026, &Utc);
        let view = YearView { review: &review, report: &report, settings: &settings, tz: &Utc };
        let text = year(&Ui { color: true, width: 80 }, &view);
        assert!(text.contains('\x1b'));
        assert!(text.contains("How bad it could have been"));
        let plain = year(&Ui::plain(80), &view);
        assert!(plain.contains("Your habits") && !plain.contains('\x1b'));
    }
}
