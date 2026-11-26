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

You need macOS 14+ and Xcode 16 or later. For compressed Codex logs, also
`brew install zstd`.

```sh
git clone https://github.com/camggould/superwarm.git
cd superwarm
swift build
swift test
scripts/install-app.sh   # builds Superwarm.app, installs to ~/Applications, launches it
```

The logic lives in `SuperwarmCore` and is unit-tested. The SwiftUI app is in
`Sources/Superwarm`. `superwarm-cli` (`swift run superwarm-cli month`) is the
quickest way to see the model against your own logs.

### Checking UI changes

Menu bar popovers are awkward to screenshot, so the app can render itself to PNGs:

```sh
swift build
.build/debug/Superwarm --render-preview /tmp/sw/pop --demo   # popover, light and dark
.build/debug/Superwarm --render-review  /tmp/sw/rv  --demo   # Year in Carbon slides
```

Please include before/after renders in pull requests that change the UI.
`--demo` uses synthetic data; drop it to render from your own logs (but don't
commit those images).

## Making changes

### Adding a model

Add its public release month to `ModelCatalog.entries`, with a test in
`ModelCatalogTests` if the name is unusual. Size tiers are inferred from the
name (Opus/flagship, Sonnet, Haiku/mini). Users can also override both in
`~/Library/Application Support/Superwarm/models.json`.

### Adding an everyday comparison

Add an `Equivalent` in `Equivalents.swift` with its source in
`Citations.swift`, a row in the methodology table, and a test that pins its
size. Electricity-based comparisons should scale with the user's grid setting.

### Changing a coefficient

Update `EnergyCoefficients`, the methodology document and its sources together
in one commit, and explain the evidence in the commit message.

## Commits and pull requests

- Keep each commit to **one logical change** that builds and passes
  `swift test` on its own. Bug fixes ship with their regression test.
- Write imperative commit subjects, with a body explaining *why*.
- Squash "fix typo" / "address review" commits into the commits they belong to
  before merge.
- CI runs the tests and builds the app on every pull request.

## Releasing (maintainers)

1. Add a `## [X.Y.Z]` section to `CHANGELOG.md` and merge it to `main`.
2. Run `scripts/release.sh X.Y.Z --push`. It checks the tree, runs the tests,
   tags `vX.Y.Z` and pushes the tag.
3. The release workflow builds a universal app, signs the archive with the
   Sparkle EdDSA key, and publishes the zip, `SHA256SUMS` and `appcast.xml`.
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
