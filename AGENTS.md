# AGENTS.md

Guidance for coding agents (and humans) working on Superwarm, which estimates
the carbon footprint of AI coding-agent usage from local logs. It has two parts:
a cross-platform **Rust engine and CLI** (`engine/`), and a **macOS menu bar app**
(Swift) that bundles the engine and renders its output. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for the human-oriented version.

## Layout

| Path | What lives there |
|---|---|
| `engine/` | The Rust crate: all estimation logic and the `superwarm` CLI. Log parsers, model catalog, emissions model, citations, equivalents, scanner/cache, reports, year in review, demo data and the `snapshot` JSON the app reads. Unit tests sit next to the code. |
| `Sources/SuperwarmKit/` | Swift: decodes the engine's snapshot JSON, runs the engine binary, formats numbers. |
| `Sources/Superwarm/` | The SwiftUI menu bar app: popover, settings, methodology window, Year in Carbon, Sparkle updates, preview renderer. No estimation logic. |
| `Tests/SuperwarmKitTests/` | The app/engine contract: decodes a committed fixture of real engine output. |
| `scripts/` | Build, install, package, release and installer scripts. |
| `docs/METHODOLOGY.md` | The emissions model, every coefficient and its sources. |

The app runs the bundled engine (`Superwarm.app/Contents/Helpers/superwarm snapshot`)
and draws whatever it returns, so the Mac app and the Linux CLI always agree.

## Commands

```sh
# Engine (run from engine/)
cargo test                     # must pass before every commit
cargo fmt && cargo clippy --all-targets -- -D warnings
cargo run --release -- report month   # terminal report against real logs
cargo run --release -- --demo year    # synthetic data

# macOS app (run from the repo root; uses engine/target/release/superwarm)
swift build && swift test
scripts/install-app.sh         # build Superwarm.app with the engine and install it

# Visual checks without screen recording; writes PNGs:
.build/debug/Superwarm --render-preview /tmp/sw/pop [--demo]   # popover, light+dark, today+30 days
.build/debug/Superwarm --render-review  /tmp/sw/rv  [--demo]   # every Year in Carbon slide + share card
```

`--demo` uses the deterministic synthetic year in `engine/src/demo.rs` (local
machine "laptop", remote "devbox"). Always use it for anything committed (README
images, fixtures), never real logs, host names or project names.

README terminal screenshots come from the real CLI output:

```sh
{ echo '$ superwarm report week'; COLUMNS=74 superwarm --demo report week --color always; } \
  | swift scripts/render-terminal.swift docs/images/cli-report.png "superwarm report week"
```

For tests and sandboxes, `SUPERWARM_CONFIG_DIR`, `SUPERWARM_DATA_DIR`,
`SUPERWARM_CACHE_DIR` and `SUPERWARM_SSH` redirect the engine's files and its
ssh binary (see `engine/tests/remote_sync.rs`).

## Rules

### Commits

- **Atomic and bisectable.** One logical change per commit. Every commit
  builds and passes `cargo test` and `swift test`. Tests ship in the same commit
  as the change they cover. Verify in a clean checkout (`git worktree add`), not
  just your working tree. Keep refactors, renames and dependency bumps separate from
  behaviour changes.
- **Messages explain why.** Imperative subject; the body gives the reason and
  anything a reviewer can't recover from the diff.
- Fold fix-ups into the commit they belong to before merging.

### The emissions model must stay evidence-backed

- Every coefficient or comparison factor needs a published source, added to
  `engine/src/citations.rs` **and** `docs/METHODOLOGY.md` in the same commit.
- Ranges are part of the model. A new coefficient needs a central value and a
  spread (`Coefficient::new(central, spread)`), justified in the methodology.
- Prefer conservative assumptions. Don't overstate the efficiency of newer
  models; the app's credibility depends on it.
- Physics-derived equivalents (kettle, shower) state their assumptions in the
  `note` and in the methodology table.

### Engine

- Bump `ScanCache::VERSION` whenever a parser changes what it emits (ids,
  fields, merging), or stale cached records will be reused silently.
- The snapshot JSON is a contract. Bump `snapshot::SCHEMA_VERSION` and
  `Snapshot.supportedSchemaVersion` together for breaking changes, and
  regenerate `Tests/SuperwarmKitTests/Fixtures/demo-snapshot.json`
  (`superwarm --demo snapshot`).
- Keep the CLI portable: no macOS-only APIs outside `#[cfg(target_os = "macos")]`.
- Remote sync (`engine/src/remote.rs`) only ever moves usage records: never
  prompts, code or full paths. Bump `EXPORT_VERSION` for incompatible export
  changes. Sync must stay non-interactive (`BatchMode`) and time-limited.

### UI

- **Check UI changes visually** with `--render-preview` / `--render-review`
  and look at the PNGs before committing. Tests don't cover views.
- Keep the popover quiet: system font, native controls, few words. Detail
  belongs in tooltips, the methodology window or Year in Carbon.
- Chart series colours (`Theme.lake`, `Theme.ochreClay`, `Theme.jade`) passed a colour-vision
  palette validator against the native popover surfaces. Don't change them,
  or add series, without re-validating. Text never uses series colours.
- Colour follows the entity: Claude Code is always lake blue, Codex clay,
  Antigravity jade. The terminal uses ANSI blue, yellow and cyan.

### Privacy

- No network access except Sparkle's update check. No telemetry.
- Never put project names or paths in shareable output (the share card).

### Releases

Maintainers release with `scripts/release.sh X.Y.Z --push` after adding a
`## [X.Y.Z]` section to `CHANGELOG.md` and setting `engine/Cargo.toml` to the
same version. The tag triggers
`.github/workflows/release.yml`, which tests, builds static Linux CLIs and the
universal macOS app and CLI, signs the app archive for Sparkle and publishes the
GitHub release. Never commit signing keys. The Sparkle
private key lives only in the
`SPARKLE_PRIVATE_KEY` repository secret.
