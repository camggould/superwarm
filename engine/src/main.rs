//! `superwarm`: the carbon footprint of your AI coding agents, in a terminal.

use anyhow::{bail, Context as _, Result};
use chrono::{Local, NaiveDate};
use clap::{Args, Parser, Subcommand, ValueEnum};
use std::io::{BufReader, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use superwarm::catalog::ModelOverride;
use superwarm::emissions::{EmissionsModel, GridSettings, GRID_US_AVERAGE};
use superwarm::equivalents::EquivalentSettings;
use superwarm::remote::{self, Remote, RemoteConfig, RemoteStore};
use superwarm::render::{self, ReportView, Ui, YearView};
use superwarm::report::{local_naive, Period, UsageReport};
use superwarm::review::{seasonal_year, YearInReview};
use superwarm::scanner::{ScanCache, ScanResult, Scanner};
use superwarm::snapshot::{self, RemoteStatus, ScanInfo};
use superwarm::usage::UsageRecord;
use superwarm::{citations, demo, paths};

#[derive(Parser)]
#[command(
    name = "superwarm",
    version,
    about = "Estimate the carbon footprint of your AI coding agents (Claude Code, Codex) from their local logs.",
    after_help = "Remote machines: run `superwarm remote add NAME user@host`, then `superwarm sync`.\nDocs: https://github.com/camggould/superwarm"
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
    /// Print this machine's usage records for another machine to import (JSON lines)
    Export {
        /// Only usage at or after this time: YYYY-MM-DD, an RFC 3339 timestamp, or epoch milliseconds
        #[arg(long)]
        since: Option<String>,
        /// Leave out project folder names
        #[arg(long)]
        no_projects: bool,
    },
    /// Add usage exported from another machine (`-` reads stdin)
    Import {
        file: PathBuf,
        /// Name to file it under (default: the exporting machine's host name)
        #[arg(long)]
        machine: Option<String>,
    },
    /// Manage remote machines to pull usage from over SSH
    #[command(subcommand)]
    Remote(RemoteCommand),
    /// Pull new usage from remote machines over SSH
    Sync {
        /// Only this remote
        name: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Everything the macOS app shows, as one JSON document
    Snapshot {
        /// Year for the year-in-review section
        #[arg(long)]
        year: Option<i32>,
        /// Sync remote machines first
        #[arg(long)]
        sync: bool,
    },
    /// The published sources behind every number
    Sources,
}

#[derive(Subcommand)]
enum RemoteCommand {
    /// Add a machine: `superwarm remote add devbox me@devbox.example.com`
    Add {
        name: String,
        /// Anything ssh accepts: host, user@host, or an alias from ~/.ssh/config
        ssh: String,
        /// Path to superwarm on the remote, if it isn't on PATH or in ~/.local/bin
        #[arg(long)]
        binary: Option<String>,
    },
    /// List remote machines and when they last synced
    List {
        #[arg(long)]
        json: bool,
    },
    /// Remove a machine and the usage synced from it
    Remove { name: String },
}

#[derive(Args, Clone)]
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
    /// Leave out usage synced from remote machines
    #[arg(long, global = true)]
    local_only: bool,
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

/// How long one remote may take to sync before it's abandoned.
const SYNC_TIMEOUT: Duration = Duration::from_secs(120);

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

/// Exit quietly when the reader goes away (`superwarm snapshot | head`), like
/// other Unix tools, instead of panicking on a broken pipe.
fn restore_default_sigpipe() {
    #[cfg(unix)]
    // SAFETY: called once at startup, before any threads or output.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
}

/// Machines whose synced usage is stored here: configured remotes plus any
/// imported by hand.
fn stored_machines(config: &RemoteConfig) -> Vec<String> {
    let mut names: Vec<String> = config.remotes.iter().map(|r| r.name.clone()).collect();
    if let Some(dir) = paths::data_dir().map(|d| d.join("remotes")) {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().is_some_and(|e| e == "bin") {
                    if let Some(stem) = path.file_stem().map(|s| s.to_string_lossy().into_owned()) {
                        if !names.contains(&stem) {
                            names.push(stem);
                        }
                    }
                }
            }
        }
    }
    names.sort();
    names
}

fn remote_statuses(config: &RemoteConfig) -> Vec<RemoteStatus> {
    stored_machines(config)
        .into_iter()
        .map(|name| {
            let store = RemoteStore::load(&name);
            RemoteStatus {
                ssh: config.remotes.iter().find(|r| r.name == name).map(|r| r.ssh.clone()),
                last_sync_ms: store.last_sync_ms,
                last_error: store.last_error,
                responses: store.records.len(),
                name,
            }
        })
        .collect()
}

struct Loaded {
    /// This machine's label next to remotes: its host name, or "laptop" for demo data
    /// (so committed demo output never carries a real host name).
    local_machine: String,
    report: UsageReport,
    scan: ScanResult,
    /// Local records only: what `export` sends.
    local: Vec<UsageRecord>,
    remotes: Vec<RemoteStatus>,
    seconds: f64,
}

fn load(options: &Options, now_ms: i64) -> Result<Loaded> {
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

    let mut records = scan.records.clone();
    let mut remotes = Vec::new();
    if !options.demo && !options.local_only {
        let config = RemoteConfig::load()?;
        for name in stored_machines(&config) {
            records.extend(RemoteStore::load(&name).records);
        }
        remotes = remote_statuses(&config);
    }

    let overrides = options
        .overrides
        .clone()
        .or_else(ModelOverride::default_path)
        .map(|path| ModelOverride::load(&path))
        .unwrap_or_default();
    let model = EmissionsModel::new(GridSettings { grams_co2_per_kwh: options.grid, pue: options.pue });
    records.sort_by_key(|r| r.timestamp_ms);
    let local = scan.records.clone();
    let report = UsageReport::new(records, model, overrides);
    let local_machine = if options.demo { "laptop".to_string() } else { paths::hostname() };
    Ok(Loaded { local_machine, report, scan, local, remotes, seconds: started.elapsed().as_secs_f64() })
}

/// Parses `--since`: epoch milliseconds, an RFC 3339 timestamp, or a local date.
fn parse_since(text: &str) -> Result<i64> {
    if let Ok(ms) = text.parse::<i64>() {
        return Ok(ms);
    }
    if let Some(ms) = superwarm::usage::parse_timestamp(text) {
        return Ok(ms);
    }
    if let Ok(date) = NaiveDate::parse_from_str(text, "%Y-%m-%d") {
        return Ok(superwarm::report::local_ms(&Local, date.and_hms_opt(0, 0, 0).expect("midnight")));
    }
    bail!("--since takes YYYY-MM-DD, an RFC 3339 timestamp or epoch milliseconds (got {text:?})")
}

fn ago(ms: i64, now_ms: i64) -> String {
    let minutes = (now_ms - ms) / 60_000;
    match minutes {
        m if m < 1 => "just now".into(),
        m if m < 60 => format!("{m} min ago"),
        m if m < 48 * 60 => format!("{} h ago", m / 60),
        m => format!("{} days ago", m / 1440),
    }
}

fn sync_all(only: Option<&str>, now_ms: i64) -> Result<Vec<remote::SyncOutcome>> {
    let config = RemoteConfig::load()?;
    let remotes: Vec<&Remote> = config.remotes.iter().filter(|r| only.is_none_or(|n| n == r.name)).collect();
    if let (Some(name), true) = (only, remotes.is_empty()) {
        bail!("no remote named {name:?}; see `superwarm remote list`");
    }
    // Machines sync in parallel: one slow box shouldn't hold up the rest.
    let outcomes = std::thread::scope(|scope| {
        let handles: Vec<_> =
            remotes.iter().map(|r| scope.spawn(move || remote::sync(r, now_ms, SYNC_TIMEOUT))).collect();
        handles.into_iter().map(|h| h.join().expect("sync thread")).collect()
    });
    Ok(outcomes)
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
            let loaded = load(options, now_ms)?;
            let period: Period = period.into();
            let first = loaded.report.first_record_ms();
            let mut section = snapshot::period_snapshot(&loaded.report, period, first, &settings, now_ms, &Local);
            if json {
                section.machines = machine_rows(&loaded.report, section.range, &loaded.local_machine);
                println!("{}", serde_json::to_string_pretty(&section)?);
            } else {
                let view = ReportView {
                    report: &loaded.report,
                    projects: loaded.report.by_project(section.range),
                    machines: machine_rows(&loaded.report, section.range, &loaded.local_machine)
                        .into_iter()
                        .map(|m| (m.name, m.summary))
                        .collect(),
                    period: &section,
                    settings: &settings,
                    first_record_ms: first,
                    now_ms,
                    tz: &Local,
                    footer: footer(&loaded, now_ms),
                };
                print!("{}", render::report(&ui(options.color), &view));
            }
        }
        Command::Year { year, json, card } => {
            let loaded = load(options, now_ms)?;
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
        Command::Export { since, no_projects } => {
            let since_ms = since.as_deref().map(parse_since).transpose()?;
            let loaded = load(&Options { local_only: true, ..options.clone() }, now_ms)?;
            let stdout = std::io::stdout();
            let mut out = std::io::BufWriter::new(stdout.lock());
            let count =
                remote::write_export(&loaded.local, since_ms, !no_projects, &loaded.local_machine, now_ms, &mut out)?;
            out.flush()?;
            eprintln!("Exported {count} responses.");
        }
        Command::Import { file, machine } => {
            if let Some(name) = &machine {
                remote::validate_name(name)?;
            }
            let (header, records) = if file.as_os_str() == "-" {
                remote::read_export(std::io::stdin().lock(), machine.as_deref())?
            } else {
                let reader =
                    BufReader::new(std::fs::File::open(&file).with_context(|| format!("opening {}", file.display()))?);
                remote::read_export(reader, machine.as_deref())?
            };
            let name = machine.unwrap_or(header.machine);
            remote::validate_name(&name)?;
            let mut store = RemoteStore::load(&name);
            let added = store.merge(records);
            store.last_sync_ms = Some(now_ms);
            store.last_error = None;
            store.save()?;
            println!("Imported {added} new responses from {name} ({} in total).", store.records.len());
        }
        Command::Remote(command) => remote_command(command, now_ms)?,
        Command::Sync { name, json } => {
            let outcomes = sync_all(name.as_deref(), now_ms)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&outcomes)?);
            } else if outcomes.is_empty() {
                println!("No remote machines yet. Add one with `superwarm remote add NAME user@host`.");
            } else {
                for o in &outcomes {
                    match &o.error {
                        None => println!("{}: {} new responses ({} in total)", o.name, o.added, o.total),
                        Some(error) => println!("{}: failed: {error}", o.name),
                    }
                }
            }
            if outcomes.iter().any(|o| o.error.is_some()) {
                std::process::exit(1);
            }
        }
        Command::Snapshot { year, sync } => {
            if sync && !options.demo && !options.local_only {
                // Failures are recorded per remote and reported in the snapshot.
                let _ = sync_all(None, now_ms);
            }
            let loaded = load(options, now_ms)?;
            let context =
                snapshot::Context { local_machine: loaded.local_machine.clone(), remotes: loaded.remotes.clone() };
            let snapshot =
                snapshot::build(&loaded.report, scan_info(&loaded.scan), settings, year, now_ms, &Local, context);
            println!("{}", serde_json::to_string(&snapshot)?);
        }
    }
    Ok(())
}

fn remote_command(command: RemoteCommand, now_ms: i64) -> Result<()> {
    let mut config = RemoteConfig::load()?;
    match command {
        RemoteCommand::Add { name, ssh, binary } => {
            remote::validate_name(&name)?;
            if config.remotes.iter().any(|r| r.name == name) {
                bail!("{name} already exists; remove it first to change it");
            }
            config.remotes.push(Remote { name: name.clone(), ssh: ssh.clone(), binary });
            config.save()?;
            println!("Added {name} ({ssh}). Pull its usage with `superwarm sync`.");
            println!(
                "It needs superwarm installed there, and SSH access without a password prompt (keys or an agent)."
            );
        }
        RemoteCommand::List { json } => {
            let statuses = remote_statuses(&config);
            if json {
                println!("{}", serde_json::to_string_pretty(&statuses)?);
            } else if statuses.is_empty() {
                println!("No remote machines. Add one with `superwarm remote add NAME user@host`.");
            } else {
                for s in statuses {
                    let via = s.ssh.as_deref().map_or("imported".to_string(), |h| format!("ssh {h}"));
                    let when = match (s.last_sync_ms, &s.last_error) {
                        (None, _) => "never synced".to_string(),
                        (Some(t), None) => format!("synced {}", ago(t, now_ms)),
                        (Some(t), Some(e)) => format!("last attempt {} failed: {e}", ago(t, now_ms)),
                    };
                    println!("{}  ({via}) · {} responses · {when}", s.name, s.responses);
                }
            }
        }
        RemoteCommand::Remove { name } => {
            let before = config.remotes.len();
            config.remotes.retain(|r| r.name != name);
            let had_data = RemoteStore::path(&name).is_some_and(|p| p.exists());
            if before == config.remotes.len() && !had_data {
                bail!("no remote named {name:?}");
            }
            config.save()?;
            RemoteStore::delete(&name);
            println!("Removed {name} and the usage synced from it.");
        }
    }
    Ok(())
}

fn machine_rows(
    report: &UsageReport,
    range: Option<superwarm::report::TimeRange>,
    local_machine: &str,
) -> Vec<snapshot::MachineRow> {
    report
        .by_machine(range)
        .into_iter()
        .map(|(name, summary)| snapshot::MachineRow {
            is_local: name.is_none(),
            name: name.unwrap_or_else(|| local_machine.to_string()),
            summary,
        })
        .collect()
}

fn scan_info(scan: &ScanResult) -> ScanInfo {
    ScanInfo {
        files_found: scan.files_found,
        files_parsed: scan.files_parsed,
        responses: scan.records.len(),
        issues: scan.issues.clone(),
    }
}

fn footer(loaded: &Loaded, now_ms: i64) -> String {
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
    let remotes = match loaded.remotes.iter().filter_map(|r| r.last_sync_ms).min() {
        Some(oldest) => format!(" · {} remote(s), synced {}", loaded.remotes.len(), ago(oldest, now_ms)),
        None => String::new(),
    };
    let issues = loaded.scan.issues.first().map(|i| format!(" · ! {i}")).unwrap_or_default();
    format!("Estimates with a ~90% range · {source}{remotes} · sources: superwarm sources{issues}")
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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn since_accepts_dates_timestamps_and_millis() {
        assert_eq!(parse_since("1700000000000").unwrap(), 1_700_000_000_000);
        assert_eq!(parse_since("2026-11-01T10:00:00Z").unwrap(), 1_793_527_200_000);
        let midnight = parse_since("2026-11-01").unwrap();
        assert_eq!(
            Local.timestamp_millis_opt(midnight).unwrap().format("%Y-%m-%d %H:%M").to_string(),
            "2026-11-01 00:00"
        );
        assert!(parse_since("yesterday").is_err());
    }
}
