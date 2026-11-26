# AGENTS.md

Guidance for coding agents (and humans) working on Superwarm, a macOS menu
bar app that estimates the carbon footprint of AI coding-agent usage from local
logs. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the human-oriented version.

## Layout

| Path | What lives there |
|---|---|
| `Sources/SuperwarmCore/` | All logic, no UI: log parsers, model catalog, emissions model, equivalents, scanner/cache, reports, year in review. Fully unit-tested. |
| `Sources/Superwarm/` | The SwiftUI menu bar app: popover, settings, methodology window, Year in Carbon, Sparkle updates, preview renderer, demo data. |
| `Sources/superwarm-cli/` | Terminal report built on SuperwarmCore. |
| `Tests/SuperwarmCoreTests/` | Swift Testing suites, one file per core component. |
| `scripts/` | Build, install, package, release and installer scripts. |
| `docs/METHODOLOGY.md` | The emissions model, every coefficient and its sources. |

## Commands

```sh
swift build                    # debug build
swift test                     # all tests (must pass before every commit)
scripts/install-app.sh         # build Superwarm.app and install to ~/Applications
swift run superwarm-cli month  # terminal report against real logs

# Visual checks without screen recording; writes PNGs:
.build/debug/Superwarm --render-preview /tmp/sw/pop [--demo]   # popover, light+dark, today+30 days
.build/debug/Superwarm --render-review  /tmp/sw/rv  [--demo]   # every Year in Carbon slide + share card
```

`--demo` uses the deterministic synthetic year in `DemoData.swift`. Always use
it for anything committed (README images), never real logs.

## Rules

### Commits

- **Atomic and bisectable.** One logical change per commit. Every commit
  builds and passes `swift test`. Tests ship in the same commit as the change
  they cover. Keep refactors, renames and dependency bumps separate from
  behaviour changes.
- **Messages explain why.** Imperative subject; the body gives the reason and
  anything a reviewer can't recover from the diff.
- Fold fix-ups into the commit they belong to before merging.

### The emissions model must stay evidence-backed

- Every coefficient or comparison factor needs a published source, added to
  `Citations.swift` **and** `docs/METHODOLOGY.md` in the same commit.
- Ranges are part of the model. A new coefficient needs a central value and a
  spread (`Coefficient(central, spread:)`), justified in the methodology.
- Prefer conservative assumptions. Don't overstate the efficiency of newer
  models; the app's credibility depends on it.
- Physics-derived equivalents (kettle, shower) state their assumptions in the
  `note` and in the methodology table.

### UI

- **Check UI changes visually** with `--render-preview` / `--render-review`
  and look at the PNGs before committing. Tests don't cover views.
- Keep the popover quiet: system font, native controls, few words. Detail
  belongs in tooltips, the methodology window or Year in Carbon.
- Chart series colours (`Theme.lake`, `Theme.ochreClay`) passed a colour-vision
  palette validator against the native popover surfaces. Don't change them,
  or add series, without re-validating. Text never uses series colours.
- Colour follows the entity: Claude Code is always lake blue, Codex clay.

### Privacy

- No network access except Sparkle's update check. No telemetry.
- Never put project names or paths in shareable output (the share card).

### Releases

Maintainers release with `scripts/release.sh X.Y.Z --push` after adding a
`## [X.Y.Z]` section to `CHANGELOG.md`. The tag triggers
`.github/workflows/release.yml`, which tests, packages, signs the archive for
Sparkle and publishes the GitHub release. Never commit signing keys. The Sparkle
private key lives only in the
`SPARKLE_PRIVATE_KEY` repository secret.
