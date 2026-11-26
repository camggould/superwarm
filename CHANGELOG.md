# Changelog

All notable changes to Superwarm are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Linux and the command line.** Superwarm's engine is now a standalone, cross-platform `superwarm` CLI (Rust): `report`, `year`, `sources` and `snapshot`, with `--json` output for scripts. Static binaries for x86_64 and ARM64 Linux ship with each release, and the one-line installer installs the CLI on Linux.
- The macOS app bundles the same CLI at `Superwarm.app/Contents/Helpers/superwarm`.

### Changed

- The macOS app now renders everything from the bundled engine instead of its own Swift implementation, so the app and the CLI always agree.
- Scanning is much faster: a cold scan of ~1,700 logs (5.4 GB) takes about 3 seconds instead of 40.
- Compressed Codex logs no longer need `zstd` installed.
- Weekly chart buckets start on Monday everywhere, instead of following the system locale.

### Fixed

- Codex responses from forked and subagent sessions were sometimes merged with unrelated responses and not counted, because those rollouts reuse their parent's session id. Records are now keyed by rollout file. On one heavy user's logs this recovered about 1,000 responses.

## [0.1.0]

First public release.

### Added

- Menu bar app estimating the carbon footprint of Claude Code and Codex usage from their local logs, with today's CO₂e in the menu bar.
- Evidence-based emissions model: per-token energy by model size and generation, prompt-cache weighting, PUE and grid intensity, with a likely range on every figure.
- Everyday comparisons: your commute, a beef burger, your home's electricity.
- Comparisons against 2024-era models, the previous period, and smaller models.
- Charts by hour, day, week or month, split by tool, and a per-model breakdown.
- **Year in Carbon**: a December year-in-review slideshow ending in a shareable summary card.
- Methodology window listing every assumption and its source.
- `superwarm-cli` for terminal reports.
- Automatic, signed in-app updates.

[Unreleased]: https://github.com/camggould/superwarm/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/camggould/superwarm/releases/tag/v0.1.0
