import AppKit
import SwiftUI
import SuperwarmCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updates.self) private var updates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Electricity") {
                Picker("Grid", selection: $model.settings.gridPreset) {
                    ForEach(GridPreset.allCases) { Text($0.label).tag($0) }
                }
                if model.settings.gridPreset == .custom {
                    LabeledContent("g CO₂e per kWh") {
                        TextField("g/kWh", value: $model.settings.customGramsPerKWh, format: .number)
                            .frame(width: 80)
                    }
                }
                LabeledContent("PUE \(model.settings.pue, format: .number.precision(.fractionLength(2)))") {
                    Slider(value: $model.settings.pue, in: 1.05...1.8, step: 0.01)
                }
                Text("Location-based. Providers rarely say which region serves you, so the US grid is the default. PUE is facility energy ÷ IT energy: hyperscalers report ~1.1, typical data centres ~1.5.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Comparisons") {
                LabeledContent("One-way commute (miles)") {
                    TextField("miles", value: $model.settings.commuteMilesOneWay, format: .number)
                        .frame(width: 80)
                }
            }

            Section("Menu bar") {
                Picker("Show", selection: $model.settings.menuBarPeriod) {
                    ForEach(AppSettings.MenuBarPeriod.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Updates") {
                LabeledContent("Version", value: updates.currentVersion)
                if updates.isEnabled {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.automaticallyChecks = $0 }
                    ))
                    Toggle("Download and install updates automatically", isOn: Binding(
                        get: { updates.automaticallyDownloads },
                        set: { updates.automaticallyDownloads = $0 }
                    ))
                    .help("Updates install the next time Superwarm quits.")
                    Button("Check Now") { updates.checkForUpdates() }
                } else {
                    Text("Updates are available in release builds installed from GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Year in Carbon") {
                Text("A year-in-review slideshow appears in the menu from December 1 to January 15.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview now") { openWindow(id: "year-in-review") }
            }

            Section("Models") {
                Text("Correct the size tier or release month of models Superwarm doesn't know yet. Unknown models are dated by when they first appear in your logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Edit model overrides…") { openOverrides() }
                    Button("Apply") { Task { await model.rebuildReport() } }
                }
            }
        }
        .formStyle(.grouped)
        .tint(Theme.moss)
        .frame(width: 460)
        .padding(.vertical, 8)
    }

    private func openOverrides() {
        let url = ModelOverride.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            [
              { "prefix": "example-model-name", "tier": "large", "released": "2026-01" }
            ]

            """
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}
