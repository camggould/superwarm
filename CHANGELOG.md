# Changelog

All notable changes to Superwarm are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
