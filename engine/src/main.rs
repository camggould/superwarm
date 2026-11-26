//! `superwarm`: the carbon footprint of your AI coding agents, in a terminal.

use anyhow::Result;
use chrono::Local;
use clap::{Args, Parser, Subcommand, ValueEnum};
use std::path::PathBuf;
use std::time::Instant;
use superwarm::catalog::ModelOverride;
use superwarm::emissions::{EmissionsModel, GridSettings, GRID_US_AVERAGE};
use superwarm::equivalents::EquivalentSettings;
use superwarm::render::{self, ReportView, Ui, YearView};
use superwarm::report::{local_naive, Period, UsageReport};
use superwarm::review::{seasonal_year, YearInReview};
use superwarm::scanner::{ScanCache, ScanResult, Scanner};
use superwarm::snapshot::{self, ScanInfo};
use superwarm::{citations, demo};

#[derive(Parser)]
#[command(
    name = "superwarm",
    version,
    about = "Estimate the carbon footprint of your AI coding agents (Claude Code, Codex) from their local logs."
)]
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
        /// Also write a shareable summary card as SVG (`-` for stdout). Leaves out project names.
        #[arg(long, value_name = "FILE.svg")]
        card: Option<PathBuf>,
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
    /// Colour output: auto (terminals only, honours NO_COLOR), always or never
    #[arg(long, global = true, value_enum, default_value = "auto")]
    color: ColorChoice,
}

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum ColorChoice {
    Auto,
    Always,
    Never,
}

fn ui(choice: ColorChoice) -> Ui {
    use std::io::IsTerminal;
    let tty = std::io::stdout().is_terminal();
    let color = match choice {
        ColorChoice::Always => true,
        ColorChoice::Never => false,
        ColorChoice::Auto => tty && std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty()),
    };
    Ui { color, width: terminal_width().unwrap_or(80) }
}

fn terminal_width() -> Option<usize> {
    if let Some(columns) = std::env::var("COLUMNS").ok().and_then(|c| c.parse().ok()) {
        return Some(columns);
    }
    #[cfg(unix)]
    {
        // SAFETY: TIOCGWINSZ only writes into the winsize struct we pass.
        let mut size: libc::winsize = unsafe { std::mem::zeroed() };
        if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0 && size.ws_col > 0 {
            return Some(size.ws_col as usize);
        }
    }
    None
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

/// Exit quietly when the reader goes away (`superwarm snapshot | head`), like
/// other Unix tools, instead of panicking on a broken pipe.
fn restore_default_sigpipe() {
    #[cfg(unix)]
    // SAFETY: called once at startup, before any threads or output.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
}

fn main() -> Result<()> {
    restore_default_sigpipe();
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
                let section = snapshot::period_snapshot(
                    &loaded.report,
                    period,
                    loaded.report.first_record_ms(),
                    &settings,
                    now_ms,
                    &Local,
                );
                let view = ReportView {
                    report: &loaded.report,
                    projects: loaded.report.by_project(section.range),
                    period: &section,
                    settings: &settings,
                    first_record_ms: loaded.report.first_record_ms(),
                    now_ms,
                    tz: &Local,
                    footer: footer(&loaded),
                };
                print!("{}", render::report(&ui(options.color), &view));
            }
        }
        Command::Year { year, json, card } => {
            let loaded = load(options, now_ms);
            let year = year
                .or_else(|| seasonal_year(now_ms, &Local))
                .unwrap_or_else(|| chrono::Datelike::year(&local_naive(&Local, now_ms)));
            let review = YearInReview::new(&loaded.report, year, &Local);
            if let Some(path) = card {
                let svg = superwarm::card::svg(&review, &loaded.report.model.grid, &settings);
                if path.as_os_str() == "-" {
                    print!("{svg}");
                    return Ok(());
                }
                std::fs::write(&path, svg)?;
                eprintln!(
                    "Wrote {}: open it in a browser, or convert it with `rsvg-convert -o card.png {}`.",
                    path.display(),
                    path.display()
                );
            }
            if json {
                println!("{}", serde_json::to_string_pretty(&review)?);
            } else {
                let view = YearView { review: &review, report: &loaded.report, settings: &settings, tz: &Local };
                print!("{}", render::year(&ui(options.color), &view));
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

fn footer(loaded: &Loaded) -> String {
    let source = if loaded.scan.files_found == 0 && !loaded.scan.records.is_empty() {
        "synthetic demo data".to_string()
    } else {
        format!(
            "{} logs scanned in {:.1}s ({} re-parsed)",
            format_thousands(loaded.scan.files_found),
            loaded.seconds,
            loaded.scan.files_parsed
        )
    };
    let issues = loaded.scan.issues.first().map(|i| format!(" · ! {i}")).unwrap_or_default();
    format!("Estimates with a ~90% range · {source} · sources: superwarm sources{issues}")
}

fn format_thousands(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}
