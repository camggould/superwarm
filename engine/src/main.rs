//! `superwarm`: the carbon footprint of your AI coding agents, in a terminal.

use anyhow::Result;
use chrono::{Local, TimeZone};
use clap::{Args, Parser, Subcommand, ValueEnum};
use std::path::PathBuf;
use std::time::Instant;
use superwarm::catalog::{GenerationSource, ModelOverride};
use superwarm::emissions::{EmissionsModel, GridSettings, GRID_US_AVERAGE};
use superwarm::equivalents::{self, EquivalentSettings};
use superwarm::report::{local_naive, Period, UsageReport};
use superwarm::review::{seasonal_year, YearInReview};
use superwarm::scanner::{ScanCache, ScanResult, Scanner};
use superwarm::snapshot::{self, ScanInfo};
use superwarm::{citations, demo, format};

#[derive(Parser)]
#[command(name = "superwarm", version, about = "Estimate the carbon footprint of your AI coding agents (Claude Code, Codex) from their local logs.")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
    #[command(flatten)]
    options: Options,
}

#[derive(Subcommand)]
enum Command {
    /// Emissions, energy and comparisons for a period (default: month)
    Report {
        #[arg(value_enum, default_value = "month")]
        period: PeriodArg,
        /// Print JSON instead of text
        #[arg(long)]
        json: bool,
    },
    /// Your year in carbon (default: the current year, or the year just ended in early January)
    Year {
        year: Option<i32>,
        #[arg(long)]
        json: bool,
    },
    /// Everything the macOS app shows, as one JSON document
    Snapshot {
        /// Year for the year-in-review section
        #[arg(long)]
        year: Option<i32>,
    },
    /// The published sources behind every number
    Sources,
}

#[derive(Args)]
struct Options {
    /// Grid carbon intensity in g CO2e per kWh (default: US average, 373)
    #[arg(long, global = true, default_value_t = GRID_US_AVERAGE)]
    grid: f64,
    /// Data-centre Power Usage Effectiveness
    #[arg(long, global = true, default_value_t = 1.15)]
    pue: f64,
    /// One-way commute in miles, for the commute comparison
    #[arg(long, global = true, default_value_t = 11.7)]
    commute: f64,
    /// Model overrides file (default: platform config dir/superwarm/models.json)
    #[arg(long, global = true)]
    overrides: Option<PathBuf>,
    /// Ignore and rebuild the parse cache
    #[arg(long, global = true)]
    no_cache: bool,
    /// Use a synthetic demo year instead of your logs
    #[arg(long, global = true)]
    demo: bool,
}

#[derive(Clone, Copy, ValueEnum)]
enum PeriodArg {
    Today,
    Week,
    Month,
    Year,
    All,
}

impl From<PeriodArg> for Period {
    fn from(p: PeriodArg) -> Period {
        match p {
            PeriodArg::Today => Period::Today,
            PeriodArg::Week => Period::Week,
            PeriodArg::Month => Period::Month,
            PeriodArg::Year => Period::Year,
            PeriodArg::All => Period::AllTime,
        }
    }
}

struct Loaded {
    report: UsageReport,
    scan: ScanResult,
    seconds: f64,
}

fn load(options: &Options, now_ms: i64) -> Loaded {
    let started = Instant::now();
    let scan = if options.demo {
        let records = demo::records(now_ms, &Local);
        ScanResult { files_found: 0, files_parsed: 0, issues: vec![], records }
    } else {
        let cache_path = ScanCache::default_path();
        let mut cache = match (&cache_path, options.no_cache) {
            (Some(path), false) => ScanCache::load(path),
            _ => ScanCache::default(),
        };
        let result = Scanner::default().scan(&mut cache);
        if let Some(path) = &cache_path {
            if result.files_parsed > 0 || !path.exists() {
                if let Err(error) = cache.save(path) {
                    eprintln!("warning: couldn't save cache: {error:#}");
                }
            }
        }
        result
    };
    let overrides = options
        .overrides
        .clone()
        .or_else(ModelOverride::default_path)
        .map(|path| ModelOverride::load(&path))
        .unwrap_or_default();
    let model = EmissionsModel::new(GridSettings { grams_co2_per_kwh: options.grid, pue: options.pue });
    let report = UsageReport::new(scan.records.clone(), model, overrides);
    Loaded { report, scan, seconds: started.elapsed().as_secs_f64() }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let now_ms = Local::now().timestamp_millis();
    let options = &cli.options;
    let settings = EquivalentSettings { commute_miles_one_way: options.commute };
    match cli.command.unwrap_or(Command::Report { period: PeriodArg::Month, json: false }) {
        Command::Sources => {
            for c in citations::ALL {
                println!("{} ({}, {})\n  {}\n  {}\n", c.title, c.publisher, c.year, c.url, c.used_for);
            }
        }
        Command::Report { period, json } => {
            let loaded = load(options, now_ms);
            let period: Period = period.into();
            if json {
                let snapshot = snapshot::build(&loaded.report, scan_info(&loaded.scan), settings, None, now_ms, &Local);
                let section = snapshot.periods.into_iter().find(|p| p.period == period.id());
                println!("{}", serde_json::to_string_pretty(&section)?);
            } else {
                print_report(&loaded, period, &settings, now_ms);
            }
        }
        Command::Year { year, json } => {
            let loaded = load(options, now_ms);
            let year = year
                .or_else(|| seasonal_year(now_ms, &Local))
                .unwrap_or_else(|| chrono::Datelike::year(&local_naive(&Local, now_ms)));
            let review = YearInReview::new(&loaded.report, year, &Local);
            if json {
                println!("{}", serde_json::to_string_pretty(&review)?);
            } else {
                print_year(&review, &loaded.report, &settings);
            }
        }
        Command::Snapshot { year } => {
            let loaded = load(options, now_ms);
            let snapshot = snapshot::build(&loaded.report, scan_info(&loaded.scan), settings, year, now_ms, &Local);
            println!("{}", serde_json::to_string(&snapshot)?);
        }
    }
    Ok(())
}

fn scan_info(scan: &ScanResult) -> ScanInfo {
    ScanInfo {
        files_found: scan.files_found,
        files_parsed: scan.files_parsed,
        responses: scan.records.len(),
        issues: scan.issues.clone(),
    }
}

fn pad(text: &str, width: usize) -> String {
    format!("{text:<width$}")
}

fn print_report(loaded: &Loaded, period: Period, settings: &EquivalentSettings, now_ms: i64) {
    let report = &loaded.report;
    let range = period.interval(now_ms, &Local);
    let summary = report.summary(range);
    let fp = summary.footprint;
    let t = summary.tokens;

    println!("Superwarm — {}", period.label());
    println!(
        "Scanned {} files ({} re-parsed) in {:.1}s, {} responses total",
        loaded.scan.files_found,
        loaded.scan.files_parsed,
        loaded.seconds,
        loaded.scan.records.len()
    );
    for issue in loaded.scan.issues.iter().take(5) {
        println!("  ! {issue}");
    }
    println!();
    println!(
        "CO2e    {}  (90% range {} – {})",
        format::grams(fp.co2_grams.central),
        format::grams(fp.co2_grams.low),
        format::grams(fp.co2_grams.high)
    );
    println!("Energy  {}", format::energy(fp.energy_wh.central));
    println!(
        "Tokens  out {} · in {} · cache write {} · cache read {}",
        format::tokens(t.output),
        format::tokens(t.input),
        format::tokens(t.cache_write),
        format::tokens(t.cache_read)
    );
    println!(
        "Efficiency dividend vs 2024-era models: {} avoided (baseline {})",
        format::grams(fp.efficiency_dividend_grams()),
        format::grams(fp.baseline_co2_grams)
    );
    println!();
    println!("That's about:");
    for e in equivalents::highlights(fp.co2_grams.central, &report.model.grid, settings, 6) {
        println!("  • {}", e.phrase(fp.co2_grams.central));
    }
    println!();
    println!("{}{}{}{}g/1k out", pad("Model", 34), pad("Tier", 9), pad("Gen", 12), pad("CO2e", 11));
    for m in report.by_model(range).iter().take(12) {
        let generation = Local.timestamp_millis_opt(m.profile.generation_ms).single().map_or_else(String::new, |d| d.format("%Y-%m").to_string());
        let marker = match m.profile.generation_source {
            GenerationSource::FirstSeen => "*",
            GenerationSource::Override => "†",
            GenerationSource::Catalog => "",
        };
        println!(
            "{}{}{}{}{:.3}",
            pad(&m.profile.display_name, 34),
            pad(m.profile.tier.display_name(), 9),
            pad(&format!("{generation}{marker}"), 12),
            pad(&format::grams(m.summary.footprint.co2_grams.central), 11),
            m.grams_per_thousand_output()
        );
    }
    println!("* generation inferred from first appearance in your logs  † from models.json override");
}

fn print_year(r: &YearInReview, report: &UsageReport, settings: &EquivalentSettings) {
    let grid = &report.model.grid;
    let units = |id: &str, grams: f64| equivalents::named(id, grid, settings).map_or(0.0, |e| e.units(grams));
    println!("Superwarm — your {} in carbon\n", r.year);
    if r.total_grams <= 0.0 {
        println!("No coding-agent usage found for {}.", r.year);
        return;
    }
    let fp = r.summary.footprint;
    println!(
        "  {} CO2e  (likely {} – {}) from {} responses",
        format::grams(r.total_grams),
        format::grams(fp.co2_grams.low),
        format::grams(fp.co2_grams.high),
        format::count(r.summary.responses as f64)
    );
    println!("  {} of electricity\n", format::energy(fp.energy_wh.central));
    println!("  That's the same as:");
    for (id, label) in [
        ("home-day", "days of an average US home's electricity"),
        ("commute", "round-trip commutes"),
        ("flight-nyc-la", "flights from New York to LA"),
        ("phone", "phone charges"),
        ("shower", "hot showers"),
        ("led-year", "years of an LED bulb left on"),
    ] {
        println!("    {:>8}  {label}", format::count(units(id, r.total_grams)));
    }
    let c = r.counterfactual;
    if c.on_reference_models > c.actual {
        println!(
            "\n  On 2024's models it would have been {} ({:.1}x). Without prompt caching too, {}.",
            format::grams(c.on_reference_models),
            c.on_reference_models / c.actual,
            format::grams(c.without_caching)
        );
        let saved = c.on_reference_models - c.actual;
        println!(
            "  Newer models kept {} out of the air: {} iPhone charges, {} hot showers.",
            format::grams(saved),
            format::count(units("phone", saved)),
            format::count(units("shower", saved))
        );
    }
    println!();
    println!("  Tokens read      {}", format::tokens(r.tokens_read));
    println!("  Novels' worth    {}", format::count(r.novels_written));
    println!("  Active days      {} (longest streak {})", r.active_days, r.longest_streak);
    if let Some(day) = &r.busiest_day {
        let date = Local.timestamp_millis_opt(day.date_ms).single().map_or_else(String::new, |d| d.format("%B %-d").to_string());
        println!("  Heaviest day     {date} ({})", format::grams(day.grams));
    }
    println!("  Night owl        {:.0}% between 10 pm and 6 am", r.night_share * 100.0);
    if let Some(model) = &r.top_model {
        println!("  Top model        {} ({:.0}%)", model.name, model.fraction * 100.0);
    }
    println!("\n  To absorb it all: {} trees growing for a decade.", units("tree", r.total_grams).ceil().max(1.0));
}
