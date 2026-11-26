# Contributing to Superwarm

Thanks for helping. Superwarm is most useful when its numbers are trustworthy,
so the most valuable contributions are often **better sources**, not code.

## Ways to help

- **Improve the model.** Found a measurement of inference energy, a better
  per-token figure, or a flaw in an assumption? Open an issue with a link to
  the source and what you think should change. See
  [docs/METHODOLOGY.md](docs/METHODOLOGY.md) for the current model.
- **Support another coding agent.** Open an issue with a (redacted) sample of
  its local log format.
- **Fix bugs or improve the app.** Issues labelled `good first issue` are a good start.

## Development setup

Superwarm has a Rust engine with a CLI (`engine/`, any platform) and a macOS app
(Swift, macOS 14+ with Xcode 16 or later) that bundles the engine.

```sh
git clone https://github.com/camggould/superwarm.git
cd superwarm/engine
cargo test
cargo run --release -- report month   # your own logs
cargo run --release -- --demo year    # synthetic data
```

For the app, build the engine once, then:

```sh
cd ..                    # repo root
swift build && swift test
scripts/install-app.sh   # builds Superwarm.app with the engine, installs to ~/Applications, launches it
```

All estimation logic lives in the engine and is unit-tested there. The app only
decodes and draws the engine's `superwarm snapshot` JSON.

### Checking UI changes

Menu bar popovers are awkward to screenshot, so the app can render itself to PNGs:

```sh
swift build
.build/debug/Superwarm --render-preview /tmp/sw/pop --demo   # popover, light and dark
.build/debug/Superwarm --render-review  /tmp/sw/rv  --demo   # Year in Carbon slides
```

Please include before/after renders in pull requests that change the UI. For
CLI output, `scripts/render-terminal.swift` turns real terminal output into the
README's screenshots (see AGENTS.md).
`--demo` uses synthetic data; drop it to render from your own logs (but don't
commit those images).

## Making changes

### Adding a model

Add its public release month to `ENTRIES` in `engine/src/catalog.rs`, with a
test if the name is unusual. Size tiers are inferred from the
name (Opus/flagship, Sonnet, Haiku/mini). Users can also override both in
`~/Library/Application Support/Superwarm/models.json`.

### Adding an everyday comparison

Add an `Equivalent` in `engine/src/equivalents.rs` with its source in
`engine/src/citations.rs`, a row in the methodology table, and a test that pins
its size. Electricity-based comparisons should scale with the user's grid setting.

### Changing a coefficient

Update `EnergyCoefficients` in `engine/src/emissions.rs`, the methodology
document and its sources together in one commit, and explain the evidence in the
commit message.

## Commits and pull requests

- Keep each commit to **one logical change** that builds and passes
  `cargo test` and `swift test` on its own. Bug fixes ship with their regression test.
- Write imperative commit subjects, with a body explaining *why*.
- Squash "fix typo" / "address review" commits into the commits they belong to
  before merge.
- CI runs the tests and builds the app on every pull request.

## Releasing (maintainers)

1. Add a `## [X.Y.Z]` section to `CHANGELOG.md`, set `version = "X.Y.Z"` in
   `engine/Cargo.toml`, and merge to `main`.
2. Run `scripts/release.sh X.Y.Z --push`. It checks the tree, runs the tests,
   tags `vX.Y.Z` and pushes the tag.
3. The release workflow builds static Linux CLIs (x86_64, ARM), the universal
   macOS app and CLI, signs the app archive with the Sparkle EdDSA key, and
   publishes everything with `SHA256SUMS` and `appcast.xml`.
   Installed copies pick it up within a day.

Repository secrets:

| Secret | Required | Purpose |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | yes | Signs update archives. Export with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account superwarm -x <new-file>`. |
| `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | no | Base64 Developer ID Application certificate, to sign the app |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | no | Notarize with `notarytool` (app-specific password) |

Keep an offline backup of the Sparkle key. If it's lost, existing installs
can't verify future updates.

## Code of conduct

Be kind and assume good faith. Disagreements about the model are welcome when
they come with evidence.
